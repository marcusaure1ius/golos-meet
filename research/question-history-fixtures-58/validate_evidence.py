#!/usr/bin/env python3
"""Validate native ownership order, narrow expected errors and source/assertion parity."""
from pathlib import Path
import collections,gzip,hashlib,json,subprocess
r=Path(__file__).parent/'results'
def read(name):return json.loads((r/name).read_text())
def cases(kind):
 raw=json.loads(gzip.decompress((r/(kind+'-events.json.gz')).read_bytes()))
 hashes=read(kind+'-trace-hashes.json')
 for name,text in raw.items():assert hashlib.sha256(text.encode()).hexdigest()==hashes[name],(kind,name)
 return {name:([json.loads(l) for l in text.splitlines()] if name.endswith('.jsonl') else json.loads(text)) for name,text in raw.items()}
checks=read('checks.json')
for kind,tests,runs in [('before',22,55),('retain',22,55),('after',22,55),('controls',3,4),('full',437,612)]:
 c=checks[kind];assert (c['passed_tests'],c['passed_runs'],c['failed_tests'],c['skipped_tests'])==(tests,runs,0,0),(kind,c)
 assert not c['warnings'] and not c['failures']
before=cases('before');created=0;removed_with_live=0;missing=0;faults=[]
for rows in before.values():
 opened={};closed={};removed={}
 for e in rows:
  if e['stage']=='root-created':created+=1
  elif e['stage']=='opened':opened[e['connection']]=(e['root'],float(e['uptime']))
  elif e['stage']=='closed':assert e['result']=='0';closed[e['connection']]=float(e['uptime'])
  elif e['stage']=='root-removed':removed[e['root']]=float(e['uptime'])
  elif e['stage']=='sqlite-failure':faults.append(json.loads(e['diagnostic']))
 for root,t in removed.items():
  assert any(v[0]==root and v[1]<=t and (k not in closed or closed[k]>t) for k,v in opened.items())
  removed_with_live+=1
 missing+=len(opened.keys()-closed.keys())
assert (created,removed_with_live,missing)==(55,55,14)
assert [(d['phase'],d['operation'],d['result'],d['extended']) for d in faults]==[('step','update',19,1811),('step','delete',19,1811)]
assert len({d['connection'] for d in faults})==1
for kind,expected_roots,expected_opens in [('after',55,87),('controls',4,6),('full',153,246)]:
 roots=set();opens=0;expected=0;unmatched=0
 for rows in cases(kind).values():
  live={};closed={};owned={};test=rows[0]['test']
  assert not any(e['stage']=='teardown-timeout' for e in rows)
  for e in rows:
   stage=e['stage'];t=float(e['uptime'])
   if stage=='root-owned':owned[e['root']]=False
   elif stage=='opened':assert e['connection'] not in live;live[e['connection']]=(e['root'],t);opens+=1
   elif stage=='closed':
    assert e['result']=='0';root,started=live.pop(e['connection']);assert t>=started;closed.setdefault(root,[]).append(t)
   elif stage=='root-removed':
    assert e['exists']=='false' and e['root'] in owned
    assert not any(root==e['root'] for root,_ in live.values())
    assert all(t>=c for c in closed.get(e['root'],[]));owned[e['root']]=True;roots.add(e['root'])
   elif stage=='sqlite-failure':
    d=json.loads(e['diagnostic']);assert d['phase']=='step' and d['result']==19 and d['extended']==1811
    if e.get('expected')=='true':expected+=1
    else:assert test=='fault-boundary-control';unmatched+=1
  assert not live and all(owned.values())
 assert (len(roots),opens)==(expected_roots,expected_opens),(kind,len(roots),opens)
 assert (expected,unmatched)==({'after':(2,0),'controls':(1,2),'full':(3,2)}[kind])
retained=[e for rows in cases('retain').values() for e in rows]
assert sum(e['stage']=='control-root-retained' for e in retained)==55
assert sum(e['stage']=='sqlite-failure' for e in retained)==2
cleanup=read('retain-parent-cleanup.json');assert len(cleanup)==55 and all(not e['exists_after_cleanup'] for e in cleanup)
audit=read('stdout-audit.json')
for kind in ['retain','after','controls']:assert audit[kind]['vnode_unlinked_lines']==0
assert audit['before']['families']=={'question-service':32,'memory-history':23}
assert audit['full']['families']=={'assignment-fixture':18,'questions-ui':14,'knowledge-search':7}
assert all(x['extended6922_lines']==0 for x in audit.values())
for kind in ['before','retain']:
 c=read(kind+'-receipt.json');assert c['ref']=='9dfdf8feecf83e94782c0e78acfdd0b2d920a37e'
 assert hashlib.sha256((r/(kind+'-observer.swift.txt')).read_bytes()).hexdigest()==c['observer_sha256']
for path,expected in read('source-hashes.json').items():assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==expected,path
for name,marker in [('KnowledgeQuestionServiceTests','@MainActor @Suite struct QuestionFixtureLifecycleTests'),('ProjectMemoryHistoryTests','@MainActor @Suite struct MemoryHistoryFixtureLifecycleTests')]:
 path='golos-meetTests/'+name+'.swift';old=subprocess.check_output(['git','show','9dfdf8feecf83e94782c0e78acfdd0b2d920a37e:'+path],text=True)
 current=Path(path).read_text().split(marker)[0]
 # Every original assertion line remains, in order, including both SQL guards.
 assert [l.strip() for l in old.splitlines() if '#expect' in l]==[l.strip() for l in current.splitlines() if '#expect' in l],path
assert not subprocess.check_output(['git','diff','--name-only','9dfdf8feecf83e94782c0e78acfdd0b2d920a37e','--','golos-meet','asr']).strip()
assert read('attachment-audit.json')['verified']==153
print('Before55 roots unlinked with live handles/14 closes absent; after87 native closes before55 unlinks.')
print('Faults19/1811 retained and exactly matched; foreign/late faults rejected; full437/612 passed with153 roots/246 closes.')
print('Original assertions/application tree unchanged;153 actual attachments verified. Remaining39 unrelated vnode diagnostics preserved.')
