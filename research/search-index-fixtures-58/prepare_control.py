#!/usr/bin/env python3
"""Instrument only the two accepted families, preserving intentional file removals."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,tarfile
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--retain-roots',action='store_true');a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists();a.output.mkdir()
ref='ec77fea89c480eb1d0db7a5cbc2a1ff452d5bc46'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as ar:ar.extractall(a.output,filter='data')
helper=Path('research/question-history-fixtures-58/results/before-observer.swift.txt').read_text().replace('QuestionHistoryObservation','SearchIndexObservation').replace('GOLOS_QH58_CONTROL','GOLOS_SEARCH_INDEX58_CONTROL')
(a.output/'golos-meetTests/SearchIndexObservation.swift').write_text(helper)
patches=[]
def patch(rel,old,new,count=1):
 q=a.output/rel;s=q.read_text();assert s.count(old)==count,(rel,old,s.count(old));patches.append(dict(path=rel,before_sha256=hashlib.sha256(s.encode()).hexdigest(),old=old,new=new));q.write_text(s.replace(old,new))
search='golos-meetTests/KnowledgeSearchTests.swift';index='golos-meetTests/LocalIndexingServiceTests.swift'
for rel,suite in ((search,'KnowledgeSearchTests'),(index,'LocalIndexingServiceTests')):patch(rel,'@MainActor @Suite struct '+suite,'@MainActor @Suite(SearchIndexObservationTrait()) struct '+suite)
patch(search,'            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))','            SearchIndexObservation.current?.note("root-created", ["root":root.lastPathComponent])\n            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))')
new='''        func cleanup() async {
            SearchIndexObservation.current?.note("index-stop-enter")
            await indexer.stop()
            SearchIndexObservation.current?.note("index-stop-returned")
            try? FileManager.default.removeItem(at: root)
            SearchIndexObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))])
        }'''
if a.retain_roots:new=new.replace('try? FileManager.default.removeItem(at: root)','SearchIndexObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
patch(search,'        func cleanup() async { await indexer.stop(); try? FileManager.default.removeItem(at: root) }',new)
patch(index,'        return root\n','        SearchIndexObservation.current?.note("root-created", ["root":root.lastPathComponent])\n        return root\n')
old='defer { try? FileManager.default.removeItem(at: root) }'
new='defer { try? FileManager.default.removeItem(at: root); SearchIndexObservation.current?.note("root-removed", ["root":root.lastPathComponent,"exists":String(FileManager.default.fileExists(atPath:root.path))]) }'
if a.retain_roots:new=new.replace('try? FileManager.default.removeItem(at: root)','SearchIndexObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
patch(index,old,new,count=6)
# Keep original raw sqlite3 APIs/FK behaviour and assertions, adding actual-close observation.
patch(search,'\n        defer { sqlite3_close(db) }','''\n        let connection = UUID(), observer = SearchIndexObservation.current
        observer?.observe(.opened(connection, url))
        defer { let code = sqlite3_close(db); observer?.observe(.closed(connection, code)) }''')
patch(search,'            defer { sqlite3_close(db) }','''            let connection = UUID(), observer = SearchIndexObservation.current
            if db != nil { observer?.observe(.opened(connection, url)) }
            defer { let code = sqlite3_close(db); if db != nil { observer?.observe(.closed(connection, code)) } }''')
probe=(Path(__file__).parent/'HeldBeforeProbe.swift.txt').read_text();q=a.output/search;q.write_text(q.read_text()+probe)
(a.output/'control-receipt.json').write_text(json.dumps(dict(ref=ref,retain_roots_control=a.retain_roots,patches=patches,probe_sha256=hashlib.sha256(probe.encode()).hexdigest(),observer_sha256=hashlib.sha256(helper.encode()).hexdigest()),indent=2)+'\n')
