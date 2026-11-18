#!/usr/bin/env python3
"""Offline audit of saved full result, exact archives and unchanged source."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess,tarfile
r=Path(__file__).parent/'results'
def sha(b):return hashlib.sha256(b).hexdigest()
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()))
for p,h in read('artifact-sha256.json').items():assert sha((r/p).read_bytes())==h,p
proof=read('accepted-provenance.json');run=read('run-receipt.json');checks=read('checks.json');summary=read('summary.json')
assert proof['base']==run['base']==checks['base']=='e9990685bdcf334039cbce7edbfb245750b0154a'
assert run['tree']==proof['expected_combined_tree']=='4284d8f240fd40d2abdd2efbd4968973a0d12df0'
assert proof['source_sha256']==run['source_sha256']
for p,h in proof['source_sha256'].items():assert sha(Path(p).read_bytes())==h,p
assert not subprocess.check_output(['git','diff',proof['base'],'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile'])
assert run['exit_code']==0 and 'stop_reason' not in run and checks['status']==summary['result']=='Passed'
assert summary['totalTestCount']==summary['passedTests']+summary['expectedFailures']+summary['failedTests']+summary['skippedTests']
assert checks['failedTests']==checks['skippedTests']==0 and checks['runtimeWarnings']==checks['testFailures']==[]
assert checks['runs']=={k:sum(d[k] for d in summary['devicesAndConfigurations']) for k in ('passedTests','failedTests','expectedFailures','skippedTests')}
assert all(c==0 for c in read('export-status.json').values())
telemetry=[json.loads(l) for l in (r/'telemetry.jsonl').read_text().splitlines()]
assert min(x['free_bytes'] for x in telemetry)>=run['reserve_bytes']==6*1024**3
assert run['preflight_free_bytes']>=run['reserve_bytes']+run['forecast_bytes'] and run['forecast_bytes']==3*1024**3
archives={}
for label,members in read('archive-members.json').items():
 with tarfile.open(r/(label+'.tar.gz')) as saved:
  data={m.name:saved.extractfile(m).read() for m in saved.getmembers()}
 assert data.keys()==members.keys()
 for p,b in data.items():assert sha(b)==members[p]['sha256'] and len(b)==members[p]['bytes']
 archives[label]=data
attachments=read('attachment-audit.json');assert attachments['mismatches']==attachments['missing']==[]
for a in attachments['matches']:
 b=archives[a['kind']][a['file']];assert b==archives['attachments'][a['exported']] and sha(b)==a['sha256'] and a['exact']
assert len(attachments['matches'])==len(archives['scopes'])+len(archives['bridge'])
total=collections.Counter()
for b in archives['scopes'].values():
 rows=json.loads(b);live={};roots=[];removed=[];accepted=set()
 for i,row in enumerate(rows):
  stage=row['stage'];total[stage]+=1
  if stage=='opened':assert row['connection'] not in live;live[row['connection']]=row['root']
  if stage=='closed':assert row['connection'] in live and row['result']=='0';del live[row['connection']]
  if stage=='root-owned':roots.append(row['root'])
  if stage=='root-removed':assert not live and row['exists']=='false';removed.append(row['root'])
  assert stage!='teardown-timeout'
  if stage=='expected-sqlite-failure':
   at=int(row['eventIndex']);assert 0<=at<i and at not in accepted and rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation'];accepted.add(at)
 assert not live and collections.Counter(roots)==collections.Counter(removed)
assert dict(total)==read('native-audit.json')['counts'] and read('native-audit.json')['violations']==[]
assert total['opened']==total['closed'] and total['root-owned']==total['root-removed']
for p in [root for component in proof['components'] for root in component['roots']]:assert read('family-ledger.json')[p]['root-owned']>0
stdout=gzip.decompress((r/'stdout.txt.gz').read_bytes());s=read('stdout-audit.json');assert sha(stdout)==s['combined_sha256']
assert s['vnode_lines']==s['extended6922']==0
mapping=read('stdout-line-map.json');lines=stdout.decode(errors='replace').splitlines()
assert mapping['counts']['sqlite']==s['sqlite_failure_lines'] and mapping['counts']['e5rt']==s['e5rt_lines']
for entry in mapping['sqlite_lines']+mapping['e5rt_lines']:assert lines[entry['line']-1]==entry['raw']
assert mapping['counts']['exact_scoped']==total['sqlite-failure'] and mapping['counts']['scoped_rollback']==0
for entry in mapping['sqlite_lines']:
 for match in entry['scope_matches']:
  rows=json.loads(archives['scopes'][match['file']]);assert rows[0].get('test')==match['test'] and json.loads(rows[match['event_index']]['diagnostic'])==entry['diagnostic']
ocr=read('ocr-audit.json');assert not ocr['errors']
for c in ocr['invocations']:
 b=archives['attachments'][c['input']];assert c['valid'] and sha(b)==c['input_sha256']==c['result']['inputSHA256'] and len(b)==c['result']['inputBytes']
 assert json.loads(c['result_raw'])==c['result'] and sha(c['result_raw'].encode())==c['result_sha256']
required=read('required-path-tests.json');assert all(t['result']=='Passed' for t in required)
for suite in ('E5NativeTests','KnowledgeSearchNativeTests','EmbeddingIndexNativeTests','LocalIndexingNativeTests','TalkConnectionRenderTests','MenuBarRenderTests','MemoryBridgeDiagnosticsTests','MemoryBridgeOverflowTests'):
 assert any(t['nodeIdentifier'].startswith(suite+'/') for t in required),suite
assert any('concreteMetadataBridge' in t['nodeIdentifier'] for t in required)
model=read('model-preflight.json');assert len(model['assets'])==5 and model['totalBytes']==487352505 and not model['download'] and not model['inference']
assert read('criteria-mapping.json')[4]['status']=='components accepted; new audit PR/review pending'
print(f"Offline validation Passed: {summary['totalTestCount']} tests, {sum(checks['runs'].values())} runs; {total['closed']} close0 before {total['root-removed']} unlinks; {len(attachments['matches'])} exact trace attachments; no new tests/model calls.")
