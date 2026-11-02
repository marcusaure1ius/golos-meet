#!/usr/bin/env python3
"""Offline source/byte/ledger audit; UI observations remain author observations."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess,tarfile
r=Path(__file__).parent/'results'
def sha(b):return hashlib.sha256(b).hexdigest()
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()))
for p,h in read('artifact-sha256.json').items():assert sha((r/p).read_bytes())==h,p
for kind in ('targeted','full'):
 prefix=kind+'/';receipt=read(prefix+'run-receipt.json');checks=read(prefix+'checks.json');summary=read(prefix+'summary.json')
 assert summary['result']==checks['status']=='Passed' and receipt['exit_code']==0 and 'stop_reason' not in receipt
 assert summary['totalTestCount']==summary['passedTests']+summary['expectedFailures'] and summary['failedTests']==summary['skippedTests']==0 and not summary['runtimeWarnings'] and not summary['testFailures']
 assert checks['runs']=={k:sum(d[k] for d in summary['devicesAndConfigurations']) for k in ('passedTests','failedTests','expectedFailures','skippedTests')}
 assert all(v==0 for v in read(prefix+'export-status.json').values())
 for p,h in receipt['source_sha256'].items():assert sha(subprocess.check_output(['git','show',receipt['head']+':'+p]))==h,p
 if kind=='full':
  for p,h in receipt['source_sha256'].items():assert sha(Path(p).read_bytes())==h,p
  for base in (receipt['accepted'],receipt['frozen55']):subprocess.run(['git','merge-base','--is-ancestor',base,receipt['head']],check=True)
 archives={}
 for label,members in read(prefix+'archive-members.json').items():
  with tarfile.open(r/prefix/(label+'.tar.gz')) as saved:data={m.name:saved.extractfile(m).read() for m in saved.getmembers()}
  assert data.keys()==members.keys()
  for p,b in data.items():assert sha(b)==members[p]['sha256'] and len(b)==members[p]['bytes']
  archives[label]=data
 audit=read(prefix+'attachment-audit.json');assert not audit['missing'] and not audit['mismatches']
 for m in audit['matches']:assert archives[m['kind']][m['file']]==archives['attachments'][m['exported']] and m['exact']
 assert len(audit['matches'])==len(archives['scopes'])+len(archives['bridge'])
 counts=collections.Counter()
 for data in archives['scopes'].values():
  rows=json.loads(data);live=set();owned=[];removed=[];accepted=set()
  for i,row in enumerate(rows):
   stage=row['stage'];counts[stage]+=1
   if stage=='opened':assert row['connection'] not in live;live.add(row['connection'])
   if stage=='closed':assert row['result']=='0' and row['connection'] in live;live.remove(row['connection'])
   if stage=='root-owned':owned.append(row['root'])
   if stage=='root-removed':assert not live and row['exists']=='false';removed.append(row['root'])
   assert stage!='teardown-timeout'
   if stage=='expected-sqlite-failure':
    at=int(row['eventIndex']);assert 0<=at<i and at not in accepted and rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation'];accepted.add(at)
  assert not live and collections.Counter(owned)==collections.Counter(removed)
 assert dict(counts)==read(prefix+'native-audit.json')['counts'] and not read(prefix+'native-audit.json')['violations']
 stdout=gzip.decompress((r/prefix/'stdout.txt.gz').read_bytes());s=read(prefix+'stdout-audit.json');assert sha(stdout)==s['combined_sha256'] and s['vnode_lines']==s['extended6922']==0
 mapping=read(prefix+'stdout-line-map.json');lines=stdout.decode(errors='replace').splitlines()
 for m in mapping['sqlite_lines']+mapping['e5rt_lines']:assert lines[m['line']-1]==m['raw']
 assert mapping['counts']['exact_scoped']==counts['sqlite-failure'] and mapping['counts']['scoped_rollback']==0
 ocr=read(prefix+'ocr-audit.json');assert not ocr['errors']
 for c in ocr['invocations']:
  data=archives['attachments'][c['input']];assert c['valid'] and sha(data)==c['result']['inputSHA256'] and len(data)==c['result']['inputBytes']
  assert json.loads(c['result_raw'])==c['result'] and sha(c['result_raw'].encode())==c['result_sha256']
 telemetry=[json.loads(l) for l in (r/prefix/'telemetry.jsonl').read_text().splitlines()];assert min(t['free_bytes'] for t in telemetry)>=receipt['reserve_bytes']==6*1024**3
 required=read(prefix+'required-path-tests.json');assert all(n['result']=='Passed' for n in required)
 if kind=='full':
  for suite in ['E5NativeTests','KnowledgeSearchNativeTests','EmbeddingIndexNativeTests','LocalIndexingNativeTests','TalkConnectionRenderTests','MenuBarRenderTests','ProjectMemoryPanelTests','TestHostIsolationTests']:
   assert any(n['nodeIdentifier'].startswith(suite+'/') for n in required),suite
  for png in read(prefix+'render-file-audit.json'):assert sha(archives['renders'][png['file']])==png['sha256'] and png['width']>0 and png['height']>0
  assert len(read(prefix+'render-file-audit.json'))==44
  for p in (r/prefix/'previews').glob('*.png'):assert p.read_bytes()==archives['renders'][p.name]
old=subprocess.check_output(['git','show','50e22e00504ec2f87628464c9ed68fa8c4bb09e7:golos-meet/UI/Projects/ProductionMemoryPanel.swift'],text=True).split('struct ProjectMemoryEntry: View')[0]
new=Path('golos-meet/UI/Projects/ProductionMemoryPanel.swift').read_text().split('extension ProjectMemoryEntry')[0];assert old==new
assert set(read('source-after-targeted.json')['changed_paths'])=={'golos-meet/UI/Projects/ProductionMemoryPanel.swift','golos-meet/UI/Projects/ProjectMemoryEntry.swift','golos-meet/UI/Projects/ProjectMemoryNavigation.swift','golos-meet/UI/Meetings/MeetingsScreen.swift'}
first=read('ui/25chunks-first-part.json');job=next(q for q in first['queue'] if q['source_key']=='meeting:new-1');assert job['cursor']==12 and job['total']==25 and job['state']=='needsConsent'
manual=read('ui/25chunks-complete-and-retraction.json');calls=[json.loads(l) for l in manual['ui_events_raw'].splitlines() if json.loads(l).get('action')=='fake_transport'];assert [len(json.loads(c['payload'])['fragments']) for c in calls]==[12,12,1]
source=read('ui/after-held-source-change.json');project=read('ui/after-held-project-change.json');assert source['events_unchanged'] and project['events_unchanged'] and source['events']==project['events']
assert next(q for q in project['queue'] if q['source_key']=='meeting:current')['state']=='failed' # actual timeout, never count as successful project-cancel proof
final=read('ui/entry-route-factory.json');events=final['tables']['memory_events'];assert events[:len(source['events'])]==source['events']
trace=[json.loads(l) for l in final['trace_raw'].splitlines()];calls=[v for v in trace if v.get('action')=='fake_transport'];assert len(calls)==7 and all('Приватная договорённость' not in c['payload'] for c in calls)
factories=[v for v in trace if v.get('action')=='entry-factory'];assert len(factories)==2 and {v['meeting'] for v in factories}=={'nil','current'} and next(v for v in factories if v['meeting']=='current')['project']=='nil'
# Trace preserves actual callback order. It has no action clock, so do not assert that view factories follow the click order.
print('Offline evidence/source validation Passed. Targeted54/67 and finalfull478/676 are separate runs. Actual UI timeout/min-max/fullnormal-environment gaps remain explicit.')
