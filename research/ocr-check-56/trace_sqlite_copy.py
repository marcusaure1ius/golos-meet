#!/usr/bin/env python3
"""Temporary-copy observation only: associate synthetic roots, test names and DB lifetime."""
from pathlib import Path
import argparse,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--copy',type=Path,required=True);a=p.parse_args()
helper='''import Foundation
nonisolated enum SQLiteDiag56 {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var roots: [UUID: URL] = [:]
    nonisolated(unsafe) private static var tests: [String: String] = [:]
    private static var folder: String? { ProcessInfo.processInfo.environment["GOLOS_SQLITE_DIAGNOSTICS_56"] }
    private static func allowed(_ root: URL) -> Bool { root.lastPathComponent.hasPrefix("memory-update-") || root.lastPathComponent.hasPrefix("index-hooks-") }
    private static func write(_ fields: [String: Any]) {
        guard let folder else { return }
        var value = fields; value["wall"] = Date().timeIntervalSince1970; value["uptime"] = ProcessInfo.processInfo.systemUptime
        do {
            let root = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file=root.appendingPathComponent("lifecycle.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
            let handle=try FileHandle(forWritingTo:file); try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject:value,options:.sortedKeys)+Data([10])); try handle.close()
        } catch { fatalError("Synthetic SQLite trace write failed") }
    }
    static func fixture(_ root: URL, test: String) {
        guard folder != nil, allowed(root) else { return }
        lock.lock(); defer { lock.unlock() }
        tests[root.lastPathComponent]=test; write(["stage":"fixture-created","root":root.lastPathComponent,"test":test])
    }
    static func created(_ connection: UUID, _ url: URL) {
        let root=url.deletingLastPathComponent(); guard folder != nil, allowed(root) else { return }
        lock.lock(); defer { lock.unlock() }; roots[connection]=root
        write(["stage":"connection-created","connection":connection.uuidString,"root":root.lastPathComponent,"test":tests[root.lastPathComponent] ?? "unknown"])
    }
    static func removed(_ root: URL) {
        guard folder != nil, allowed(root) else { return }; lock.lock(); defer { lock.unlock() }
        write(["stage":"fixture-removed","root":root.lastPathComponent,"exists":FileManager.default.fileExists(atPath:root.path),"test":tests[root.lastPathComponent] ?? "unknown"])
    }
    static func closed(_ connection: UUID) {
        guard folder != nil else { return }; lock.lock(); defer { lock.unlock() }
        guard let root=roots.removeValue(forKey:connection) else { return }
        write(["stage":"connection-close","connection":connection.uuidString,"root":root.lastPathComponent,"exists":FileManager.default.fileExists(atPath:root.path)])
    }
    static func failure(_ connection: UUID, operation: String, result: Int32, extended: Int32) {
        guard folder != nil else { return }; lock.lock(); defer { lock.unlock() }
        guard let root=roots[connection] else { return }
        write(["stage":"sqlite-failure","connection":connection.uuidString,"root":root.lastPathComponent,"exists":FileManager.default.fileExists(atPath:root.path),"operation":operation,"result":result,"extended":extended,"test":tests[root.lastPathComponent] ?? "unknown"])
    }
}
'''
changes=[]
def patch(rel,old,new):
 path=a.copy/rel;s=path.read_text();assert s.count(old)==1,(rel,old,s.count(old))
 changes.append({'path':rel,'before_sha256':hashlib.sha256(s.encode()).hexdigest(),'old':old,'new':new})
 path.write_text(s.replace(old,new))
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        handle = db\n','        handle = db\n        SQLiteDiag56.created(connection, url)\n')
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        sqlite3_close(handle)\n','        SQLiteDiag56.closed(connection)\n        sqlite3_close(handle)\n')
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        let message = diagnostic.message','        SQLiteDiag56.failure(connection, operation: operation.rawValue, result: result, extended: extended)\n        let message = diagnostic.message')
patch('golos-meetTests/ProjectMemoryUpdateTests.swift','        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','        SQLiteDiag56.fixture(root, test: Test.current?.name ?? "unknown")\n        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
patch('golos-meetTests/ProjectMemoryUpdateTests.swift','    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root) }','    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root); SQLiteDiag56.removed(root) }')
patch('golos-meetTests/IndexingProductionHooksTests.swift','        return root\n','        SQLiteDiag56.fixture(root, test: Test.current?.name ?? "unknown")\n        return root\n')
(a.copy/'golos-meet/Util/SQLiteDiagnostics56.swift').write_text(helper)
(a.copy/'sqlite-diagnostic-copy.json').write_text(json.dumps({'changes':changes,'helper_sha256':hashlib.sha256(helper.encode()).hexdigest(),'branch_production_modified':False},indent=2)+'\n')
