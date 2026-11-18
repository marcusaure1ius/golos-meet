import Foundation
import CoreServices

/// FSEvents watches descendants with one stream, not one FD per meeting.
nonisolated final class KnowledgeFileMonitor: @unchecked Sendable {
    private nonisolated final class Callback: @unchecked Sendable {
        let receive: @Sendable ([String]) -> Void
        init(_ receive: @escaping @Sendable ([String]) -> Void) { self.receive = receive }
    }
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(roots: [URL], receive: @escaping @Sendable ([String]) -> Void) throws {
        let callback = Callback(receive)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer!).retain().toOpaque()) },
            release: { pointer in Unmanaged<Callback>.fromOpaque(pointer!).release() }, copyDescription: nil)
        let paths = roots.map { $0.resolvingSymlinksInPath().path } as CFArray
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, paths, _, _ in
            guard let info else { return }
            let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            callback.receive(values.compactMap { $0 as? String })
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
            throw CocoaError(.fileReadUnknown)
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "golos.knowledge-files", qos: .utility))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            throw CocoaError(.fileReadUnknown)
        }
        stream = created
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    deinit { stop() }
}
