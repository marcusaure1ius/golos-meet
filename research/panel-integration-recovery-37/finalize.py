#!/usr/bin/env python3
"""Summarize and hash existing evidence only; never run tests or UI."""
from pathlib import Path
import gzip,hashlib,json,shutil,struct
r=Path(__file__).parent/'results'
def read(p):return json.loads(p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()))
for kind in ('targeted','full'):
 folder=r/kind;tree=read(folder/'tests.json');nodes=[]
 def walk(n):
  if n.get('nodeType')=='Test Case':nodes.append(n)
  for c in n.get('children',[]):walk(c)
 for n in tree['testNodes']:walk(n)
 selected=[n for n in nodes if n.get('nodeIdentifier','').split('/')[0] in ['ProjectMemoryPanelTests','ProjectMemoryQueueTests','MemoryBridgeDiagnosticsTests','MemoryBridgeOverflowTests','TestHostIsolationTests','E5NativeTests','KnowledgeSearchNativeTests','EmbeddingIndexNativeTests','LocalIndexingNativeTests','TalkConnectionRenderTests','MenuBarRenderTests']]
 (folder/'required-path-tests.json').write_text(json.dumps(selected,ensure_ascii=False,indent=2)+'\n')
full=r/'full';preview=full/'previews';preview.mkdir(exist_ok=True)
for name in ['partial-consent-light.png','conflicts-claims-dark.png']:
 shutil.copy2(Path('/private/tmp/golos37recovery-full-renders')/name,preview/name)
render_manifest=[]
for p in sorted(Path('/private/tmp/golos37recovery-full-renders').glob('*.png')):
 b=p.read_bytes();assert b.startswith(b'\x89PNG\r\n\x1a\n');w,h=struct.unpack('>II',b[16:24]);render_manifest.append(dict(file=p.name,width=w,height=h,bytes=len(b),sha256=hashlib.sha256(b).hexdigest()))
(full/'render-file-audit.json').write_text(json.dumps(render_manifest,indent=2)+'\n')
a=read(r/'targeted/run-receipt.json');b=read(r/'full/run-receipt.json')
delta=[p for p in sorted(a['source_sha256'].keys()|b['source_sha256'].keys()) if a['source_sha256'].get(p)!=b['source_sha256'].get(p)]
(r/'source-after-targeted.json').write_text(json.dumps(dict(targeted_head=a['head'],full_head=b['head'],changed_paths=delta,explanation='Only UI entry/factory/navigation extraction after targeted; final full and final safeDI host compile/interaction cover it. No worker/service/test changes after targeted.'),indent=2)+'\n')
for p in sorted(r.rglob('*.json')):
 if p.name=='artifact-sha256.json':continue
 if p.stat().st_size>16384:Path(str(p)+'.gz').write_bytes(gzip.compress(p.read_bytes(),mtime=0));p.unlink()
(r/'artifact-sha256.json').write_text(json.dumps({str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(r.rglob('*')) if p.is_file() and p.name!='artifact-sha256.json'},indent=2)+'\n')
print('Finalized receipts/raw archives/44PNG hashes; no runtime calls')
