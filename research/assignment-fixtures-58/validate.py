#!/usr/bin/env python3
"""Validate preserved evidence without tests, OCR, network or model loading."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess
r=Path(__file__).parent/'results'
def read(n):return json.loads((r/n).read_text())
def sha(b):return hashlib.sha256(b).hexdigest()
source=read('source-check.json');assert source['production_diff']==''
for p,digest in source['source_sha256'].items():assert sha(Path(p).read_bytes())==digest,p
receipt=read('full-receipt.json');assert receipt['source_sha256']==source['source_sha256'];assert receipt['exit_code']==2
for kind in ('before','retain','after','final-targeted','full'):
 raw=json.loads(gzip.decompress((r/(kind+'-events.json.gz')).read_bytes()));assert {p:sha(s.encode()) for p,s in raw.items()}==read(kind+'-trace-hashes.json')
 for filename,text in raw.items():
  rows=list(map(json.loads,text.splitlines())) if kind in ('before','retain') else json.loads(text)
  opened=set();accepted=set()
  for index,row in enumerate(rows):
   stage=row['stage']
   if stage=='opened':assert row['connection'] not in opened;opened.add(row['connection'])
   if stage=='closed':assert row['result']=='0';opened.remove(row['connection'])
   if stage=='root-removed':
    assert row['exists']=='false'
    if kind not in ('before','retain'):assert not opened
   if stage=='expected-sqlite-failure':
    at=int(row['eventIndex']);assert at<index and at not in accepted;accepted.add(at)
    assert rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation']
  assert not opened
  if rows[0].get('test')=='assignment-interrupted-body':
   stages=[x['stage'] for x in rows];lastClose=max(i for i,x in enumerate(rows) if x['stage']=='closed')
   assert stages.index('body-finished')<stages.index('assignment-indexer-stop-requested')<stages.index('assignment-indexer-stopped')<lastClose<stages.index('root-removed')
 if kind not in ('before','retain'):
  attachments=read(kind+'-attachment-audit.json');assert {x['scope']+'.json' for x in attachments}==raw.keys()
  for a in attachments:assert a['sha256']==sha(raw[a['scope']+'.json'].encode())
checks=read('checks.json');assert checks['before']['runs']['passedTests']==checks['retain']['runs']['passedTests']==23
assert checks['final-targeted']['runs']==dict(passedTests=93,failedTests=0,expectedFailures=12,skippedTests=0)
assert checks['full']['runs']==dict(passedTests=623,failedTests=1,expectedFailures=12,skippedTests=0)
assert len(checks['full']['testFailures'])==1 and 'metadata bridge ready-source coverage' in checks['full']['testFailures'][0]['failureText']
a=read('scope-audit.json');beforeNames={x['test'] for x in a['before']};originalAfter=[x for x in a['final-targeted'] if x['test'] in beforeNames]
assert len(originalAfter)==23
stats=sum((collections.Counter(x['counts']) for x in originalAfter),collections.Counter())
assert stats['opened']==stats['closed']==40 and stats['root-removed']==23 and stats['expected-sqlite-failure']==1
assert all(len(x['unlink'])==1 and len(x['unlink'][0]['open_connections'])==1 for x in a['before'])
assert len(read('retain-parent-cleanup.json'))==23 and all(x['removed_after_host_exit'] for x in read('retain-parent-cleanup.json'))
assert read('stdout-audit.json')['full']['families']=={'knowledge-search':5,'index-service':2,'questions-ui':15}
telemetry=[json.loads(l) for l in (r/'full-telemetry.jsonl').read_text().splitlines()];assert len(telemetry)==20 and min(x['free_bytes'] for x in telemetry)==7415693312
ocr=read('full-ocr-audit.json');assert len(ocr)==41
for call in ocr:
 data=(r/'ocr-assets'/call['input']).read_bytes();assert sha(data)==call['result']['inputSHA256'] and len(data)==call['result']['inputBytes']
assert collections.Counter(x['result']['stage'] for x in ocr)=={'extract-returned':40,'extract-threw':1}
base=subprocess.check_output(['git','show',source['base']+':golos-meetTests/MeetingAssignmentTests.swift'],text=True)
def assertions(s):return [l.strip().replace('f.reopenedStore()','ProjectStore(url: f.url)') for l in s.splitlines() if '#expect' in l or '#require' in l]
assert assertions(base)==source['assertion_lines']
for p in r.rglob('*'):
 if p.is_file():assert p.suffix not in {'.pyc','.onnx','.safetensors','.wav','.bin'}
print('Validated original assertions, source SHA, actual close-before-unlink, single-use faults, exact attachments/OCR and FAILED full with disk telemetry.')
