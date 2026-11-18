#!/usr/bin/env python3
"""Instrument only accepted question/history fixtures in a fresh temporary copy."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,tarfile
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--retain-roots',action='store_true');a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists()
a.output.mkdir();ref='9dfdf8feecf83e94782c0e78acfdd0b2d920a37e'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as archive:archive.extractall(a.output,filter='data')
helper='''import Foundation
import Testing
@testable import golos_meet
nonisolated final class QuestionHistoryObservation: @unchecked Sendable {
    @TaskLocal static var current: QuestionHistoryObservation?
    let id=UUID().uuidString
    private let lock=NSLock()
    private func write(_ stage:String,_ fields:[String:String]=[:]) {
        guard let folder=ProcessInfo.processInfo.environment["GOLOS_QH58_CONTROL"] else {return}
        var row=fields;row["stage"]=stage;row["uptime"]=String(ProcessInfo.processInfo.systemUptime)
        do {
            let root=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let file=root.appendingPathComponent(id+".jsonl")
            if !FileManager.default.fileExists(atPath:file.path) {try Data().write(to:file)}
            let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:.sortedKeys)+Data([10]));try handle.close()
        } catch {fatalError("Synthetic control trace failed")}
    }
    func note(_ stage:String,_ fields:[String:String]=[:]) {lock.lock();defer{lock.unlock()};write(stage,fields)}
    func observe(_ event:ProjectDatabase.LifecycleEvent) {
        lock.lock();defer{lock.unlock()}
        switch event {
        case .opened(let id,let url):write("opened",["connection":id.uuidString,"root":url.deletingLastPathComponent().lastPathComponent])
        case .closed(let id,let code):write("closed",["connection":id.uuidString,"result":String(code)])
        case .failure(let d):write("sqlite-failure",["diagnostic":d.message])
        }
    }
}
nonisolated struct QuestionHistoryObservationTrait: TestTrait,SuiteTrait,TestScoping {
    var isRecursive:Bool {true}
    func scopeProvider(for test:Test,testCase:Test.Case?)->Self? {testCase==nil ? nil:self}
    func provideScope(for test:Test,testCase:Test.Case?,performing body:@concurrent @Sendable () async throws->Void) async throws {
        let observer=QuestionHistoryObservation();observer.note("case-start",["test":test.name])
        defer {observer.note("case-returned")}
        try await QuestionHistoryObservation.$current.withValue(observer) {
            try await ProjectDatabase.$lifecycleObserver.withValue({observer.observe($0)}) {try await body()}
        }
    }
}
'''
(a.output/'golos-meetTests/QuestionHistoryObservation.swift').write_text(helper)
patches=[]
def patch(path,old,new,count=1):
 q=a.output/path;s=q.read_text();assert s.count(old)==count,(path,old,s.count(old));patches.append(dict(path=path,before_sha256=hashlib.sha256(s.encode()).hexdigest(),old=old,new=new));q.write_text(s.replace(old,new))
for name,suite in [('KnowledgeQuestionServiceTests.swift','KnowledgeQuestionServiceTests'),('ProjectMemoryHistoryTests.swift','ProjectMemoryHistoryTests')]:
 rel='golos-meetTests/'+name
 patch(rel,'@MainActor @Suite struct '+suite,'@MainActor @Suite(QuestionHistoryObservationTrait()) struct '+suite)
 patch(rel,'        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','        QuestionHistoryObservation.current?.note("root-created", ["root":root.lastPathComponent])\n        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
 if name=='KnowledgeQuestionServiceTests.swift':
  old='    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root) }'
  new='''    func cleanup() { service.cancel(); QuestionHistoryObservation.current?.note("question-cancel-requested")
        try? FileManager.default.removeItem(at: root)
        QuestionHistoryObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))])
    }'''
  # The original raw sqlite3 helper already closes synchronously in defer.
  patch(rel,'        defer { sqlite3_close(db) }','''        let connection=UUID();QuestionHistoryObservation.current?.observe(.opened(connection,root.appendingPathComponent("knowledge.sqlite")))
        defer {let code=sqlite3_close(db);QuestionHistoryObservation.current?.observe(.closed(connection,code))}''')
 else:
  old='    func cleanup() { try? FileManager.default.removeItem(at: root) }'
  new='''    func cleanup() { try? FileManager.default.removeItem(at: root)
        QuestionHistoryObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))])
    }'''
 if a.retain_roots:new=new.replace('try? FileManager.default.removeItem(at: root)','QuestionHistoryObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
 patch(rel,old,new)
(a.output/'control-receipt.json').write_text(json.dumps(dict(ref=ref,retain_roots_control=a.retain_roots,patches=patches,observer_sha256=hashlib.sha256(helper.encode()).hexdigest()),indent=2)+'\n')
