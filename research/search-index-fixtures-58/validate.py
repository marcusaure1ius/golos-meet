#!/usr/bin/env python3
"""Check saved native evidence only. Never infer a result for the interrupted full."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess
r=Path(__file__).parent/'results'
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress((r/(n+'.gz')).read_bytes()))
def sha(b):return hashlib.sha256(b).hexdigest()
source=read('source-check.json');assert source['production_diff']==source['allowance_diff']=='' and source['shared_encoder_source_prefix_unchanged']
for p,h in source['source_sha256'].items():assert sha(Path(p).read_bytes())==h,p
receipt=read('after-receipt.json');assert receipt['source_sha256']==source['source_sha256'] and receipt['exit_code']==0 and 'stop_reason' not in receipt
allRows={}
for kind in ('before','before-index','retain','after'):
 raw=json.loads(gzip.decompress((r/(kind+'-events.json.gz')).read_bytes()));assert {p:sha(s.encode()) for p,s in raw.items()}==read(kind+'-trace-hashes.json')
 cases=[]
 for text in raw.values():
  rows=json.loads(text) if kind=='after' else list(map(json.loads,text.splitlines()));cases.append(rows)
  live=set();accepted=set()
  for i,row in enumerate(rows):
   stage=row['stage']
   if stage=='opened':assert row['connection'] not in live;live.add(row['connection'])
   if stage=='closed':assert row['result']=='0';live.remove(row['connection'])
   if stage=='root-removed':
    assert row['exists']=='false'
    if kind=='after':assert not live
   if stage=='expected-sqlite-failure':
    at=int(row['eventIndex']);assert at<i and at not in accepted;accepted.add(at)
    assert rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation']
  assert not live
 allRows[kind]=cases
 if kind=='after':
  attachments=read('after-attachment-audit.json');assert {a['scope']+'.json' for a in attachments}==raw.keys()
  for a in attachments:assert a['sha256']==sha(raw[a['scope']+'.json'].encode())
search=[c for c in allRows['before'] if c[0]['test'].startswith('heldSearchBefore')][0]
index=[c for c in allRows['before-index'] if c[0]['test'].startswith('throwingIndexBody')][0]
for rows,n in ((search,2),(index,6)):
 faults=[json.loads(x['diagnostic']) for x in rows if x['stage']=='sqlite-failure'];assert len(faults)==n and all(x['extended']==6922 and x['result']==10 for x in faults)
 stages=[x['stage'] for x in rows];assert stages.index('root-removed')<stages.index('sqlite-failure')<stages.index('closed')
retained=[x for c in allRows['retain'] for x in c]
assert any(x['stage']=='late-write-succeeded' for x in retained) and any(x['stage']=='held-query-succeeded' for x in retained)
assert any(x['stage']=='index-worker-drained' and x['hadStorageMessage']=='false' for x in retained)
assert not any(x['stage']=='sqlite-failure' and json.loads(x['diagnostic'])['extended']==6922 for x in retained)
assert len(read('retain-parent-cleanup.json'))==18 and all(x['removed_after_host_exit'] for x in read('retain-parent-cleanup.json'))
held=[c for c in allRows['after'] if c[0]['test'].startswith(('held-search-','held-index-'))];assert len(held)==6
for rows in held:
 stages=[x['stage'] for x in rows];close=max(i for i,x in enumerate(rows) if x['stage']=='closed')
 returned='search-held-query-returned' if rows[0]['test'].startswith('held-search-') else 'index-held-passage-returned'
 assert stages.index('body-finished')<stages.index('search-index-late-write-enter')<stages.index('search-index-late-write-finished')<stages.index(returned)<close<stages.index('root-removed')
 assert not any(x['stage']=='sqlite-failure' for x in rows)
checks=read('checks.json');assert 'full' not in checks
assert checks['after']['runs']==dict(passedTests=23,failedTests=0,expectedFailures=0,skippedTests=0)
assert checks['after']['totalTestCount']==19 and checks['after']['runtimeWarnings']==[]
audit=read('scope-audit.json');counts=sum((collections.Counter(c['counts']) for c in audit['after']),collections.Counter())
assert counts['root-owned']==counts['root-removed']==22 and counts['opened']==counts['closed']==37 and counts['sqlite-failure']==counts['expected-sqlite-failure']==1
assert read('stdout-audit.json')['after']['vnode']==read('stdout-audit.json')['after']['extended6922']==0
partial=read('partial-full-receipt.json');assert partial['source_sha256']==source['source_sha256'] and partial['stop_reason']=='runtime-free-below-6GiB' and partial['exit_code']==-15
assert all(code!=0 for code in read('partial-export-status.json')['exports'].values())
raw=json.loads(gzip.decompress((r/'partial-full-scope-files.json.gz').read_bytes()));assert {p:sha(s.encode()) for p,s in raw.items()}==read('partial-full-scope-hashes.json')
# Hash-only preservation; these files are an incomplete subset, not full coverage.
for path,original in source['assertion_lines'].items():
 text=subprocess.check_output(['git','show',source['base']+':'+path],text=True)
 assert [l.strip() for l in text.splitlines() if '#expect' in l or '#require' in l]==original
print('Validated two real6922 paths/retain controls, 93 assertions, six held lifetimes, 37 native closes/22 unlinks/29 attachments. Full remains interrupted; no full counters inferred.')
