import AppKit
import ApplicationServices
import Foundation

nonisolated enum TalkNativeSnapshot: Equatable, Sendable {
    case documents([String]), notRunning, unknown(Issue)
    enum Issue: Equatable, Sendable { case permissionRequired, unavailable, limitReached }
}

/// Traverses window wrappers only. Never enters a web document: links, chat,
/// names, form fields and history inside AXWebArea are not read.
nonisolated struct TalkDocumentScanner<Node> {
    let role: (Node) throws -> String?
    let url: (Node) throws -> String?
    let children: (Node) throws -> [Node]
    let now: () -> TimeInterval
    var nodeLimit = 2_000
    var depthLimit = 16
    var secondsLimit: TimeInterval = 2

    func scan(_ windows: [Node]) throws -> [String] {
        let began = now()
        var urls: [String] = []
        var visited = 0
        guard windows.count <= 16 else { throw ScanError.limit }
        for window in windows {
            var stack = [(window, 0)], foundDocument = false
            while let (node, depth) = stack.popLast() {
                visited += 1
                guard visited <= nodeLimit, depth <= depthLimit, now() - began < secondsLimit else { throw ScanError.limit }
                if try role(node) == "AXWebArea" {
                    guard let value = try url(node), !value.isEmpty else { throw ScanError.unavailable }
                    urls.append(value); foundDocument = true
                    continue
                }
                let values = try children(node)
                guard values.count <= nodeLimit - visited else { throw ScanError.limit }
                stack.append(contentsOf: values.map { ($0, depth + 1) })
            }
            // A readable home window cannot hide another inaccessible call
            // window. No partial window set may prove absence.
            guard foundDocument else { throw ScanError.unavailable }
        }
        guard !urls.isEmpty, now() - began < secondsLimit else { throw ScanError.unavailable }
        return urls
    }
    enum ScanError: Error { case limit, unavailable }
}

nonisolated struct TalkNativeRoomSource: Sendable {
    func read() async -> TalkNativeSnapshot {
        // Before process enumeration, AX permission checks or any OS access.
        guard !AppRuntime.isTestHost else { return .unknown(.unavailable) }
        let pids = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: "kontur.talk").map(\.processIdentifier)
        }
        guard !pids.isEmpty else { return .notRunning }
        return await Task.detached(priority: .utility) { Self.capture(pids) }.value
    }

    private static func capture(_ pids: [pid_t]) -> TalkNativeSnapshot {
        guard AXIsProcessTrusted() else { return .unknown(.permissionRequired) }
        guard pids.count <= 4 else { return .unknown(.limitReached) }
        return autoreleasepool {
            do {
                let began = ProcessInfo.processInfo.systemUptime
                var windows: [AXUIElement] = []
                for pid in pids {
                    let app = AXUIElementCreateApplication(pid)
                    guard let values = try attribute(app, kAXWindowsAttribute) as? [AXUIElement], !values.isEmpty else {
                        return .unknown(.unavailable)
                    }
                    guard windows.count + values.count <= 16 else { return .unknown(.limitReached) }
                    windows += values
                }
                let scanner = TalkDocumentScanner<AXUIElement>(
                    role: { try attribute($0, kAXRoleAttribute) as? String },
                    url: {
                        let value = try attribute($0, kAXURLAttribute)
                        return (value as? URL)?.absoluteString ?? value as? String
                    },
                    children: { try attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
                    now: { ProcessInfo.processInfo.systemUptime })
                let urls = try scanner.scan(windows)
                guard ProcessInfo.processInfo.systemUptime - began < 2.5 else { return .unknown(.limitReached) }
                return .documents(urls)
            } catch TalkDocumentScanner<AXUIElement>.ScanError.limit { return .unknown(.limitReached) }
            catch { return .unknown(.unavailable) }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        // Timeout is per AX object, not inherited by its descendants.
        guard AXUIElementSetMessagingTimeout(element, 0.15) == .success else {
            throw TalkDocumentScanner<AXUIElement>.ScanError.unavailable
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: throw TalkDocumentScanner<AXUIElement>.ScanError.unavailable
        }
    }
}

nonisolated enum TalkDiscoveredRoom {
    private static let reserved: Set<String> = ["login", "logout", "auth", "settings", "profile", "calendar", "content", "recordings", "boards", "contacts", "messenger", "api"]

    static func isNonMeetingPage(_ document: String, origin: URL) -> Bool {
        let text = document.contains("://") ? document : "https://" + document
        guard var parts = URLComponents(string: text), parts.percentEncodedPath == parts.path else { return false }
        let path = parts.path
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let server = parts.url, (try? TalkAPIClient.normalizedServer(server)) == origin else { return false }
        return path.isEmpty || path == "/" || path.split(separator: "/").first.map { reserved.contains(String($0)) } == true
    }
    /// Query/fragment data never leaves this parser. Only the validated room ID
    /// is used to construct a fresh authenticated request to the saved origin.
    static func parse(_ document: String, origin: URL) -> String? {
        let text = document.contains("://") ? document : "https://" + document
        guard var parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.percentEncodedPath == parts.path else { return nil }
        let path = parts.path
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let url = parts.url, (try? TalkAPIClient.normalizedServer(url)) == origin else { return nil }
        guard let room = try? TalkRoomConfiguration.room(origin.absoluteString + path, origin: origin),
              !reserved.contains(room) else { return nil }
        return room
    }
}
