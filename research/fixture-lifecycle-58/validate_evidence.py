#!/usr/bin/env python3
"""Check actual close-before-unlink, counts, receipts and published source hashes."""
import collections,hashlib,json
from pathlib import Path
r=Path(__file__).parent/'results'
def read(name):return json.loads((r/name).read_text())
checks=read('checks.json');final=checks['combined-final']
assert (final['passed_tests'],final['passed_runs'],final['failed_tests'],final['skipped_tests'])==(434,608,0,0)
assert not final['runtime_warnings']
roots=set();opens=0
for p in (r/'after').glob('*.json'):
 rows=json.loads(p.read_text());live={};closed={};owned={}
 assert not any(x['stage'] in ['sqlite-failure','teardown-timeout'] for x in rows),p
 for e in rows:
  t=float(e['uptime']);stage=e['stage']
  if stage=='root-owned':owned[e['root']]=None
  elif stage=='opened':
   assert e['connection'] not in live
   live[e['connection']]=(e['root'],t);opens+=1
  elif stage=='closed':
   assert e['result']=='0'
   root,opened=live.pop(e['connection']);assert t>=opened
   closed.setdefault(root,[]).append(t)
  elif stage=='root-removed':
   assert e['root'] in owned and e['exists']=='false'
   assert not any(root==e['root'] for root,_ in live.values())
   assert all(t>=c for c in closed.get(e['root'],[]))
   owned[e['root']]=t;roots.add(e['root'])
 assert not live and all(v is not None for v in owned.values()),p
assert len(roots)==94 and opens==153
before=read('before-events.json')['events'];retained=read('retain-events.json')['events']
errors=collections.Counter(e['extended'] for e in before if e['stage']=='sqlite-failure')
assert errors=={'6922':14,'1':2},errors
assert not any(e['stage']=='sqlite-failure' for e in retained)
cleanup=read('retain-parent-cleanup.json');assert len(cleanup)==78 and all(not x['exists_after_cleanup'] for x in cleanup)
for kind in ['before','retain']:
 receipt=read(kind+'-receipt.json')
 assert receipt['ref']=='24b75f63bad8429aec00331c4968d6963a09bc09'
 assert hashlib.sha256((r/(kind+'-observer.swift.txt')).read_bytes()).hexdigest()==receipt['helper_sha256']
for name,expected in read('source-hashes.json').items():assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==expected,name
assert read('attachment-audit.json')['verified']==94
stdout=read('stdout-audit.json');assert stdout['extended6922_lines']==0
assert stdout['vnode_unlinked_lines']==83 # explicitly retained limitation, not silence
for line in read('combined-final-sqlite-stdout.json'):
 assert not any(root in line for root in roots),line
native=read('native-unlink.json');assert native[0]['write_extended']==1032 and native[1]['rows_before_cleanup']==2
assert all(x['close']==0 and not x['root_exists'] for x in native)
print('94 roots removed after153 successful native closes; before14x6922+2rollback vs retain0; exported94 attachments verified.')
print('Full434/608 passed,0 runtime warnings/extended6922. Remaining83 vnode diagnostics belong to other fixtures and are preserved.')
