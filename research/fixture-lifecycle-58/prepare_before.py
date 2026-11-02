#!/usr/bin/env python3
"""Observe accepted code in a fresh /private/tmp copy; never patch an author checkout."""
import argparse,hashlib,io,json,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--retain-roots',action='store_true');a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists()
a.output.mkdir()
ref='24b75f63bad8429aec00331c4968d6963a09bc09'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as archive: archive.extractall(a.output,filter='data')
changes=[]
def patch(rel,old,new,count=1):
 path=a.output/rel;s=path.read_text();assert s.count(old)==count,(rel,old,s.count(old))
 changes.append(dict(path=rel,before_sha256=hashlib.sha256(s.encode()).hexdigest(),old=old,new=new))
 path.write_text(s.replace(old,new))
helper='''import Foundation
nonisolated enum FixtureBefore58 {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var owners: [ObjectIdentifier: URL] = [:]
    nonisolated(unsafe) private static var connections: [UUID: URL] = [:]
    nonisolated(unsafe) private static var tests: [String: String] = [:]
    private static func allowed(_ root: URL) -> Bool { root.lastPathComponent.hasPrefix("memory-update-") || root.lastPathComponent.hasPrefix("index-hooks-") }
    private static func write(_ stage: String, root: URL, fields: [String:String] = [:]) {
        guard allowed(root), let folder=ProcessInfo.processInfo.environment["GOLOS_FIXTURE_BEFORE"] else { return }
        var row=fields; row["stage"]=stage; row["root"]=root.lastPathComponent; row["test"]=tests[root.lastPathComponent] ?? "unknown"; row["uptime"]=String(ProcessInfo.processInfo.systemUptime)
        row["rootExists"]=String(FileManager.default.fileExists(atPath:root.path))
        do {
            let output=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let file=output.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath:file.path) {try Data().write(to:file)}
            let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:.sortedKeys)+Data([10]));try handle.close()
        } catch { fatalError("Synthetic trace failed") }
    }
    static func fixture(_ root: URL, test: String) {lock.lock();defer{lock.unlock()};tests[root.lastPathComponent]=test;write("fixture-created",root:root)}
    static func owner(_ object: AnyObject, url: URL) {lock.lock();defer{lock.unlock()};owners[ObjectIdentifier(object)]=url;write("owner-created",root:url,fields:["owner":String(describing:ObjectIdentifier(object))])}
    static func child(_ object: AnyObject, of parent: AnyObject) {lock.lock();defer{lock.unlock()};if let root=owners[ObjectIdentifier(parent)] {owners[ObjectIdentifier(object)]=root}}
    static func mark(_ stage: String, _ object: AnyObject) {lock.lock();defer{lock.unlock()};if let root=owners[ObjectIdentifier(object)] {write(stage,root:root,fields:["owner":String(describing:ObjectIdentifier(object))])}}
    static func connection(_ id: UUID, _ url: URL) {lock.lock();defer{lock.unlock()};connections[id]=url.deletingLastPathComponent();write("opened",root:url.deletingLastPathComponent(),fields:["connection":id.uuidString])}
    static func close(_ id: UUID, result: Int32) {lock.lock();defer{lock.unlock()};if let root=connections[id] {write("closed",root:root,fields:["connection":id.uuidString,"result":String(result)])}}
    static func failure(_ id: UUID, result: Int32, extended: Int32, operation: String) {lock.lock();defer{lock.unlock()};if let root=connections[id] {write("sqlite-failure",root:root,fields:["connection":id.uuidString,"result":String(result),"extended":String(extended),"operation":operation])}}
    static func removed(_ root: URL) {lock.lock();defer{lock.unlock()};write("root-removed",root:root)}
}
'''
(a.output/'golos-meet/Util/FixtureBefore58.swift').write_text(helper)
patch('golos-meet/Core/Knowledge/ProjectStore.swift','init(url: URL) { self.url = url }','init(url: URL) { self.url = url; FixtureBefore58.owner(self, url: url.deletingLastPathComponent()) }')
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        handle = db\n','        handle = db\n        FixtureBefore58.connection(connection, url)\n')
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        sqlite3_close(handle)\n','        let closeResult = sqlite3_close(handle)\n        FixtureBefore58.close(connection, result: closeResult)\n')
patch('golos-meet/Core/Knowledge/ProjectStore.swift','        let message = diagnostic.message','        FixtureBefore58.failure(connection, result: result, extended: extended, operation: operation.rawValue)\n        let message = diagnostic.message')
patch('golos-meet/Core/Knowledge/ProjectMemoryQueueWorker.swift','        history = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)','        history = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)\n        FixtureBefore58.child(self, of: store)')
patch('golos-meet/Core/Knowledge/ProjectMemoryQueueWorker.swift','    func stop() async {','    func stop() async {\n        FixtureBefore58.mark("memory-worker-stop-enter", self)\n        defer { FixtureBefore58.mark("memory-worker-stop-exit", self) }')
patch('golos-meet/Core/Knowledge/LocalIndexingService.swift','        self.inspect = inspect','        self.inspect = inspect\n        FixtureBefore58.child(self, of: store)')
patch('golos-meet/Core/Knowledge/LocalIndexingService.swift','    func stop() async {','    func stop() async {\n        FixtureBefore58.mark("index-service-stop-enter", self)\n        defer { FixtureBefore58.mark("index-service-stop-exit", self) }')
patch('golos-meet/UI/Projects/KnowledgeMemoryQueue.swift','        let worker = worker; Task { @MainActor in await worker.stop() }','        let worker = worker; Task { @MainActor in FixtureBefore58.mark("memory-bridge-deinit-task", worker); await worker.stop() }')
patch('golos-meet/UI/Projects/KnowledgeMemoryQueue.swift','guard !Task.isCancelled else { return }; await worker.stop()','guard !Task.isCancelled else { return }; FixtureBefore58.mark("memory-bridge-stop-task", worker); await worker.stop()')
patch('golos-meet/UI/Projects/KnowledgeIndexing.swift','        Task { await service.stop() }','        Task { FixtureBefore58.mark("index-controller-stop-task", service); await service.stop() }',count=2)
patch('golos-meetTests/ProjectMemoryUpdateTests.swift','        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','        FixtureBefore58.fixture(root, test: Test.current?.name ?? "unknown")\n        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
patch('golos-meetTests/ProjectMemoryUpdateTests.swift','    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root) }','    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root); FixtureBefore58.removed(root) }')
patch('golos-meetTests/IndexingProductionHooksTests.swift','        return root\n','        FixtureBefore58.fixture(root, test: Test.current?.name ?? "unknown")\n        return root\n')
patch('golos-meetTests/IndexingProductionHooksTests.swift','defer { try? FileManager.default.removeItem(at: root) }','defer { try? FileManager.default.removeItem(at: root); FixtureBefore58.removed(root) }',count=3)
if a.retain_roots:
 for rel,count in [('golos-meetTests/ProjectMemoryUpdateTests.swift',1),('golos-meetTests/IndexingProductionHooksTests.swift',3)]:
  patch(rel, 'try? FileManager.default.removeItem(at: root); FixtureBefore58.removed(root)', 'FixtureBefore58.retained(root)', count=count)
 helper_path=a.output/'golos-meet/Util/FixtureBefore58.swift'
 h=helper_path.read_text().replace('    static func removed(_ root: URL)', '    static func retained(_ root: URL) {lock.lock();defer{lock.unlock()};write("control-root-retained",root:root)}\n    static func removed(_ root: URL)')
 helper_path.write_text(h)
(a.output/'before-receipt.json').write_text(json.dumps(dict(ref=ref,retain_roots_control=a.retain_roots,patches=changes,helper_sha256=hashlib.sha256((a.output/'golos-meet/Util/FixtureBefore58.swift').read_bytes()).hexdigest()),indent=2)+'\n')
