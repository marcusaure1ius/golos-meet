#!/usr/bin/env python3
"""Validate existing evidence without tests, OCR, network or model loading."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess
r=Path(__file__).parent/'results'
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress((r/(n+'.gz')).read_bytes()))
def sha(b):return hashlib.sha256(b).hexdigest()
source=read('source-check.json');assert source['production_diff']==source['allowance_diff']==''
for p,h in source['source_sha256'].items():assert sha(Path(p).read_bytes())==h
receipt=read('full-receipt.json');assert receipt['source_sha256']==source['source_sha256'] and receipt['exit_code']==2 and 'stop_reason' not in receipt
allRows={}
for kind in ('before','before-probe','retain','after','full'):
 raw=json.loads(gzip.decompress((r/(kind+'-events.json.gz')).read_bytes()));assert {p:sha(s.encode()) for p,s in raw.items()}==read(kind+'-trace-hashes.json')
 before=kind in ('before','before-probe','retain');cases=[]
 for filename,text in raw.items():
  rows=list(map(json.loads,text.splitlines())) if before else json.loads(text);cases.append(rows)
  live=set();accepted=set()
  for i,row in enumerate(rows):
   stage=row['stage']
   if stage=='opened':assert row['connection'] not in live;live.add(row['connection'])
   if stage=='closed':assert row['result']=='0';live.remove(row['connection'])
   if stage=='root-removed':
    assert row['exists']=='false'
    if not before:assert not live
   if stage=='expected-sqlite-failure':
    at=int(row['eventIndex']);assert at<i and at not in accepted;accepted.add(at)
    assert rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation']
  assert not live
  if rows[0].get('test','').startswith('question-ui-held-'):
   stages=[x['stage'] for x in rows];close=max(i for i,x in enumerate(rows) if x['stage']=='closed')
   assert stages.index('body-finished')<stages.index('question-ui-late-write-enter')<stages.index('question-ui-late-write-finished')<close<stages.index('root-removed')
   assert not any(x['stage']=='sqlite-failure' for x in rows)
 if not before:
  attach=read(kind+'-attachment-audit.json');assert {a['scope']+'.json' for a in attach}==raw.keys()
  for a in attach:assert a['sha256']==sha(raw[a['scope']+'.json'].encode())
 allRows[kind]=cases
probe=allRows['before-probe'][0];d=[json.loads(x['diagnostic']) for x in probe if x['stage']=='sqlite-failure'];assert len(d)==1
assert {k:d[0][k] for k in ('phase','operation','result','extended')}==dict(phase='step',operation='beginImmediate',result=10,extended=6922)
stages=[x['stage'] for x in probe];assert stages.index('root-removed')<stages.index('late-write-enter')<stages.index('sqlite-failure')<stages.index('closed')
retained=[x for c in allRows['retain'] for x in c];assert any(x['stage']=='late-write-succeeded' for x in retained) and not any(x['stage']=='sqlite-failure' for x in retained)
assert len(read('retain-parent-cleanup.json'))==16 and all(x['removed_after_host_exit'] for x in read('retain-parent-cleanup.json'))
checks=read('checks.json');assert checks['after']['runs']==dict(passedTests=22,failedTests=0,expectedFailures=0,skippedTests=0)
assert checks['full']['runs']==dict(passedTests=630,failedTests=1,expectedFailures=12,skippedTests=0)
assert len(checks['full']['testFailures'])==1 and 'metadata bridge ready-source coverage' in checks['full']['testFailures'][0]['failureText']
a=read('scope-audit.json');assert all(len(x['unlink'])==1 and len(x['unlink'][0]['open_connections'])==1 for x in a['before'])
baseNames={x['test'] for x in a['before']};originalAfter=[x for x in a['after'] if x['test'] in baseNames];assert len(originalAfter)==15
counts=sum((collections.Counter(x['counts']) for x in originalAfter),collections.Counter());assert counts['opened']==counts['closed']==16 and counts['root-removed']==15
for kind in ('after','full'):
 held=[c for c in allRows[kind] if c[0].get('test','').startswith('question-ui-held-')];assert len(held)==6
assert read('stdout-audit.json')['full']['families']=={'index-service':1,'knowledge-search':1}
t=[json.loads(l) for l in (r/'full-telemetry.jsonl').read_text().splitlines()];assert len(t)==19 and min(x['free_bytes'] for x in t)==6504001536
ocr=read('full-ocr-audit.json');assert len(ocr)==41
for c in ocr:
 b=(r/'ocr-assets'/c['input']).read_bytes();assert sha(b)==c['result']['inputSHA256'] and len(b)==c['result']['inputBytes']
 assert json.loads(c['result_raw'])==c['result'] and sha(c['result_raw'].encode())==c['result_sha256']
assert collections.Counter(c['result']['stage'] for c in ocr)=={'extract-returned':40,'extract-threw':1}
base=subprocess.check_output(['git','show',source['base']+':golos-meetTests/KnowledgeQuestionModelTests.swift'],text=True)
assert [l.strip() for l in base.splitlines() if '#expect' in l or '#require' in l]==source['assertion_lines']
for p in r.rglob('*'):
 if p.is_file():assert p.suffix not in {'.pyc','.onnx','.safetensors','.wav','.bin'}
print('Validated original assertions, source SHA, actual6922/retain control, six held lifetimes, native close-before-unlink, exact attachments/OCR and FAILED full.')
