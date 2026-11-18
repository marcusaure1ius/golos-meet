#!/usr/bin/env python3
"""Make a fresh accepted-copy observer, optionally retaining roots as a causal control."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,tarfile
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--retain-roots',action='store_true');a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists()
a.output.mkdir();ref='fc2a92956fd50bd791e4926d5b388c8fe39f84d4'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as ar:ar.extractall(a.output,filter='data')
# The earlier observer records actual DEBUG native events without altering cleanup.
helper=(Path('research/question-history-fixtures-58/results/before-observer.swift.txt').read_text().replace('QuestionHistoryObservation','AssignmentObservation').replace('GOLOS_QH58_CONTROL','GOLOS_ASSIGNMENT58_CONTROL'))
(a.output/'golos-meetTests/AssignmentObservation.swift').write_text(helper)
patches=[]
def patch(path,old,new):
 q=a.output/path;s=q.read_text();assert s.count(old)==1,(path,old,s.count(old));patches.append(dict(path=path,before_sha256=hashlib.sha256(s.encode()).hexdigest(),old=old,new=new));q.write_text(s.replace(old,new))
rel='golos-meetTests/MeetingAssignmentTests.swift'
patch(rel,'@MainActor @Suite struct MeetingAssignmentTests','@MainActor @Suite(AssignmentObservationTrait()) struct MeetingAssignmentTests')
patch(rel,'            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','            AssignmentObservation.current?.note("root-created", ["root":root.lastPathComponent])\n            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
old='        func cleanup() async { await indexer.stop(); try? FileManager.default.removeItem(at: root) }'
new='''        func cleanup() async {
            AssignmentObservation.current?.note("indexer-stop-enter")
            await indexer.stop()
            AssignmentObservation.current?.note("indexer-stop-returned")
            try? FileManager.default.removeItem(at: root)
            AssignmentObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))])
        }'''
if a.retain_roots:new=new.replace('try? FileManager.default.removeItem(at: root)','AssignmentObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
patch(rel,old,new)
(a.output/'control-receipt.json').write_text(json.dumps(dict(ref=ref,retain_roots_control=a.retain_roots,patches=patches,observer_sha256=hashlib.sha256(helper.encode()).hexdigest()),indent=2)+'\n')
