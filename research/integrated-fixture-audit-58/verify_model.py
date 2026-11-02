#!/usr/bin/env python3
"""Hash only the same five approved assets; never download or infer."""
from pathlib import Path
import hashlib,json,re,datetime
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
model=next(m for m in json.loads(Path('research/model-comparison-28/models.json').read_text())['models'] if m['id']=='e5-small')
assert model['revision']=='fd1525a9fd15316a2d503bf26ab031a61d056e98' and model['repository']=='intfloat/multilingual-e5-small'
swift=Path('golos-meet/Core/Knowledge/EmbeddingModelManifest.swift').read_text();entries=re.findall(r'\.init\(path: "([^"]+)", bytes: (\d+), sha256: "([0-9a-f]{64})"\)',swift)
expected=[dict(path=a['path'],bytes=a['bytes'],sha256=a['sha256']) for a in model['files'] if a['required_for_inference']]
assert len(expected)==len(entries)==5
assert {(p,int(n),h) for p,n,h in entries}=={(a['path'],a['bytes'],a['sha256']) for a in expected}
coordinator=Path('/Users/alfa/Development/golos-meet/.build/coordination-evidence/e5-approved-kit-restoration.json');receipt=json.loads(coordinator.read_text());assert receipt['files']==expected and receipt['revision']==model['revision']
folder=Path('/private/tmp/golos-embedding-native/e5-small');actual=[]
for a in expected:
 p=folder/a['path'];assert p.is_file() and p.stat().st_size==a['bytes'],a['path']
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 assert h.hexdigest()==a['sha256'],a['path'];actual.append(a)
result=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),folder=str(folder),repository=model['repository'],revision=model['revision'],assets=actual,totalBytes=sum(a['bytes'] for a in actual),coordinator_receipt_sha256=hashlib.sha256(coordinator.read_bytes()).hexdigest(),inference=False,download=False)
(r/'model-preflight.json').write_text(json.dumps(result,indent=2)+'\n');print('5/5 approved model hashes verified;487352505 bytes; no download/inference')
