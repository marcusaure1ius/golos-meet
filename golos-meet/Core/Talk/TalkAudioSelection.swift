import AppKit
import Foundation

nonisolated struct TalkAudioProcess: Hashable, Sendable {
    let processID: Int32
    let bundleIdentifier: String
}

nonisolated enum TalkAudioSelection {
    /// Confirmed from the installed native client's app/helper Info.plists.
    /// Do not broaden this to a prefix or browser based on a window title.
    static let nativeBundleIDs: Set<String> = [
        "kontur.talk", "kontur.talk.helper", "kontur.talk.helper.Renderer",
        "kontur.talk.helper.GPU", "kontur.talk.helper.Plugin",
    ]

    static func select(_ candidates: [TalkAudioProcess]) throws -> [TalkAudioProcess] {
        let selected = candidates.filter { nativeBundleIDs.contains($0.bundleIdentifier) }
        guard selected.contains(where: { $0.bundleIdentifier == "kontur.talk" }) else {
            throw TalkAudioCaptureError.nativeClientNotFound
        }
        guard selected.allSatisfy({ $0.processID > 0 }) else { throw TalkAudioCaptureError.invalidProcesses }
        let byPID = Dictionary(grouping: candidates, by: \.processID)
        for target in selected {
            guard byPID[target.processID]?.allSatisfy({ $0.bundleIdentifier == target.bundleIdentifier }) == true else {
                throw TalkAudioCaptureError.invalidProcesses
            }
        }
        return Set(selected).sorted { $0.processID < $1.processID }
    }
}

/// A fixed session allowlist: disappearance fails the session, never expands it.
/// The retained NSRunningApplication objects refer to the original instances,
/// so a later process reusing the same PID cannot revive an old selection.
@MainActor
final class TalkAudioProcessGuard {
    private let targets: [TalkAudioProcess]
    private let inspect: (TalkAudioProcess) throws -> Bool
    private var timer: Timer?
    private var onFailure: ((TalkAudioCaptureError) -> Void)?

    init(targets: [TalkAudioProcess], inspect: ((TalkAudioProcess) throws -> Bool)? = nil) {
        self.targets = targets
        if let inspect { self.inspect = inspect }
        else {
            let apps = Dictionary(uniqueKeysWithValues: Set(targets).compactMap { target in
                NSRunningApplication(processIdentifier: target.processID).map { (target, $0) }
            })
            self.inspect = { target in
                guard let app = apps[target] else { throw TalkAudioCaptureError.sourceUnavailable }
                guard !app.isTerminated else { return false }
                return app.bundleIdentifier == target.bundleIdentifier
            }
        }
    }

    func validate() throws {
        _ = try TalkAudioSelection.select(targets)
        do {
            for target in targets {
                guard try inspect(target) else { throw TalkAudioCaptureError.processDisappeared }
            }
        } catch let error as TalkAudioCaptureError { throw error }
        catch { throw TalkAudioCaptureError.sourceUnavailable }
    }

    func start(onFailure: @escaping (TalkAudioCaptureError) -> Void) throws {
        stop()
        try validate()
        self.onFailure = onFailure
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        guard let onFailure else { return }
        do { try validate() }
        catch {
            stop()
            onFailure((error as? TalkAudioCaptureError) ?? .sourceUnavailable)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFailure = nil
    }
}
