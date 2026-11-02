#!/usr/bin/env python3
"""Validate P2 single-use acknowledgements without running app/tests/OCR."""
from pathlib import Path
import gzip,hashlib,json,subprocess
r=Path(__file__).parent/'results'
def read(name):return json.loads((r/name).read_text())
def traces(kind):
 raw=json.loads(gzip.decompress((r/(kind+'-events.json.gz')).read_bytes()))
 for name,text in raw.items():assert hashlib.sha256(text.encode()).hexdigest()==read(kind+'-trace-hashes.json')[name]
 return [json.loads(text) for text in raw.values()]
c=read('checks.json')
assert (c['before']['failed_tests'],c['before']['failed_runs'])==(2,3)
assert c['targeted']['total_tests']==31 and c['targeted']['passed_runs']==65 and c['targeted']['expected_runs']==7 and c['targeted']['failed_runs']==0
assert (c['full']['total_tests'],c['full']['passed_tests'],c['full']['failed_tests'],c['full']['expected_tests'])==(443,436,5,2)
assert (c['full']['passed_runs'],c['full']['failed_runs'],c['full']['expected_runs'])==(610,8,7)
assert all(not x['warnings'] and x['skipped_tests']==0 for x in c.values())
failures=c['full']['failures'];assert sum('metadata bridge ready-source coverage' in x['failureText'] for x in failures)==1
assert all('LocalDocumentExtractorTests/' in x['testIdentifierString'] or 'DocumentFormatImportTests/' in x['testIdentifierString'] or 'ProjectMemoryQueueTests/concreteMetadataBridge' in x['testIdentifierString'] for x in failures)
for kind,roots_expected,opens_expected in [('targeted',83,141),('full',177,294)]:
 roots=opens=accepted_count=rejected_count=0
 for rows in traces(kind):
  live={};owned={};closed={};markers={};checks={};indexes=set()
  for index,e in enumerate(rows):
   stage=e['stage'];t=float(e['uptime'])
   if stage=='root-owned':owned[e['root']]=False
   elif stage=='opened':assert e['connection'] not in live;live[e['connection']]=(e['root'],t);opens+=1
   elif stage=='closed':
    assert e['result']=='0';root,start=live.pop(e['connection']);assert t>=start;closed.setdefault(root,[]).append(t)
   elif stage=='root-removed':
    assert e['exists']=='false' and e['root'] in owned and not any(root==e['root'] for root,_ in live.values())
    assert all(t>=x for x in closed.get(e['root'],[]));owned[e['root']]=True;roots+=1
   elif stage=='expected-sqlite-failure':
    event_index=int(e['eventIndex']);assert event_index not in indexes and event_index<index;indexes.add(event_index)
    raw=rows[event_index];assert raw['stage']=='sqlite-failure' and raw['expected']=='true' and raw['acceptedBy']==e['expectation'] and raw['diagnostic']==e['diagnostic']
    assert e['expectation'] not in markers;markers[e['expectation']]=e
   elif stage=='fault-expectation-checked':assert e['expectation'] not in checks;checks[e['expectation']]=e
  assert not live and all(owned.values())
  for key,e in checks.items():
   if e['accepted']=='true':assert key in markers and e['matchingUnconsumed']=='1';accepted_count+=1
   else:assert key not in markers and e['matchingUnconsumed'] in ['0','2'];rejected_count+=1
  assert markers.keys()<=checks.keys()
  if rows[0]['test']=='p2-nested-missing-outer':
   assert len(markers)==1 and len(checks)==2
   assert sorted(e['accepted'] for e in checks.values())==['false','true']
  assert not any(e['stage']=='teardown-timeout' for e in rows)
 assert (roots,opens,accepted_count,rejected_count)==(roots_expected,opens_expected,23,7),(kind,roots,opens,accepted_count,rejected_count)
# Same test source ran against the old helper; no before mutation hidden in app code.
receipt=read('before-receipt.json');assert receipt['ref']=='5446d7dfaff87f8cd97256340960b20dc293a874'
assert receipt['test_source_sha256']==hashlib.sha256(Path('golos-meetTests/SQLiteFaultExpectationTests.swift').read_bytes()).hexdigest()
old_helper=subprocess.check_output(['git','show','5446d7dfaff87f8cd97256340960b20dc293a874:golos-meetTests/SQLiteFixtureScope.swift'])
assert receipt['helper_sha256']==hashlib.sha256(old_helper).hexdigest()
a=read('attachment-audit.json');assert (a['scope_count'],a['ocr_attachment_count'],a['ocr_invocations'])==(177,82,41)
for data in a['ocr'].values():
 b=(r/'ocr-assets'/data['input']['asset']).read_bytes();assert hashlib.sha256(b).hexdigest()==data['input']['sha256']==data['result']['inputSHA256']
 assert len(b)==data['result']['inputBytes']
for path,digest in read('source-hashes.json').items():assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,path
assert not subprocess.check_output(['git','diff','--name-only','9dfdf8feecf83e94782c0e78acfdd0b2d920a37e','--','golos-meet','asr']).strip()
print('Matched pre-fix native suite fails2 tests/3runs; fixed targeted65passed+7expected,0failed. Each native event accepted at most once.')
print('Completed full RED:443tests=436passed+5failed+2expected;625runs=610passed+8failed+7expected. No rerun to green.')
print('177roots/294nativeclose0/177unlink;177scope attachments and82OCR attachments/41exact inputs preserved. Disk-pressure caveat retained.')
