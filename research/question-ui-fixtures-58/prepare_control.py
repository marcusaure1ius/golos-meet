#!/usr/bin/env python3
"""Observe only accepted QuestionUIFixture in a fresh temporary copy."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,tarfile
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--retain-roots',action='store_true');a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists()
a.output.mkdir();ref='7be254c4a1eceb28755ad60d718a4ed72cb21179'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as ar:ar.extractall(a.output,filter='data')
helper=Path('research/question-history-fixtures-58/results/before-observer.swift.txt').read_text().replace('QuestionHistoryObservation','QuestionUIObservation').replace('GOLOS_QH58_CONTROL','GOLOS_QUESTION_UI58_CONTROL')
(a.output/'golos-meetTests/QuestionUIObservation.swift').write_text(helper)
patches=[]
def patch(old,new):
 q=a.output/'golos-meetTests/KnowledgeQuestionModelTests.swift';s=q.read_text();assert s.count(old)==1,(old,s.count(old));patches.append(dict(before_sha256=hashlib.sha256(s.encode()).hexdigest(),old=old,new=new));q.write_text(s.replace(old,new))
patch('@MainActor @Suite struct KnowledgeQuestionModelTests','@MainActor @Suite(QuestionUIObservationTrait()) struct KnowledgeQuestionModelTests')
patch('        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','        QuestionUIObservation.current?.note("root-created", ["root":root.lastPathComponent])\n        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
patch('''    private func dispatch(_ messages: [ChatMessage]) async throws -> String {
''','''    private func dispatch(_ messages: [ChatMessage]) async throws -> String {
        let observer = QuestionUIObservation.current
        observer?.note("transport-enter")
        defer { observer?.note("transport-returned") }
''')
patch('queryEmbedding: query)','''queryEmbedding: { text in
            let observer = QuestionUIObservation.current
            observer?.note("retrieval-enter")
            defer { observer?.note("retrieval-returned") }
            return try await query(text)
        })''')
old='    func cleanup() { model.cancel(); try? FileManager.default.removeItem(at: root) }'
new='''    func cleanup() {
        QuestionUIObservation.current?.note("model-cancel-requested")
        model.cancel()
        QuestionUIObservation.current?.note("model-cancel-returned")
        try? FileManager.default.removeItem(at: root)
        QuestionUIObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))])
    }'''
if a.retain_roots:new=new.replace('try? FileManager.default.removeItem(at: root)','QuestionUIObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
patch(old,new)
(a.output/'control-receipt.json').write_text(json.dumps(dict(ref=ref,retain_roots_control=a.retain_roots,patches=patches,observer_sha256=hashlib.sha256(helper.encode()).hexdigest()),indent=2)+'\n')
