#!/usr/bin/env python3
"""Preserve every exported attachment and raw trace, report observed violations."""
from pathlib import Path
import collections,gzip,hashlib,json,re,shutil,tarfile
r=Path(__file__).parent/'results';prefix='/private/tmp/golos58integrated-full'
def sha(b):return hashlib.sha256(b).hexdigest()
def write(n,v):
 data=(json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode()
 (r/(n+'.gz')).write_bytes(gzip.compress(data,mtime=0)) if len(data)>16384 else (r/n).write_bytes(data)
def archive(folder,name):
 files=sorted(p for p in folder.rglob('*') if p.is_file());members={str(p.relative_to(folder)):dict(sha256=sha(p.read_bytes()),bytes=p.stat().st_size) for p in files}
 with tarfile.open(r/(name+'.tar.gz'),'w:gz') as out:
  for p in files:out.add(p,arcname=str(p.relative_to(folder)),recursive=False)
 with tarfile.open(r/(name+'.tar.gz')) as saved:
  for member in saved.getmembers():assert sha(saved.extractfile(member).read())==members[member.name]['sha256']
 return members
members={}
for suffix,label in [('events','scopes'),('bridge','bridge'),('attachments','attachments')]:
 folder=Path(prefix+'-'+suffix)
 if folder.is_dir():members[label]=archive(folder,label)
write('archive-members.json',members)
receipt=json.loads(Path(prefix+'-receipt.json').read_text());summary_path=Path(prefix+'-summary.json');summary=json.loads(summary_path.read_text()) if summary_path.stat().st_size else None
checks=dict(status='INCOMPLETE' if 'stop_reason' in receipt or summary is None else summary['result'],process_exit=receipt['exit_code'],base=receipt['base'],tree=receipt['tree'])
if summary:
 checks.update({k:summary[k] for k in ('result','totalTestCount','passedTests','failedTests','expectedFailures','skippedTests','runtimeWarnings','testFailures')})
 checks['runs']={k:sum(d[k] for d in summary['devicesAndConfigurations']) for k in ('passedTests','failedTests','expectedFailures','skippedTests')}
for suffix,name in [('receipt.json','run-receipt.json'),('telemetry.jsonl','telemetry.jsonl'),('summary.json','summary.json')]:
 p=Path(prefix+'-'+suffix)
 if p.is_file():shutil.copy2(p,r/name)
for p in sorted(Path('/private/tmp').glob('golos58integrated-full-*')):
 if p.is_file() and ('error.txt' in p.name or 'export.log' in p.name or 'activities.json' in p.name):shutil.copy2(p,r/p.name.replace('golos58integrated-full-',''))
for suffix,name in [('.log','xcodebuild.log'),('-tests.json','tests.json')]:
 p=Path(prefix+suffix)
 if p.is_file():(r/(name+'.gz')).write_bytes(gzip.compress(p.read_bytes(),mtime=0))
stdout_files=sorted(Path(prefix+'-diagnostics').rglob('StandardOutputAndStandardError.txt'));stdout=b'\n'.join(p.read_bytes() for p in stdout_files)
(r/'stdout.txt.gz').write_bytes(gzip.compress(stdout,mtime=0));text=stdout.decode(errors='replace')
write('stdout-audit.json',dict(source_files=[dict(path=str(p),bytes=p.stat().st_size,sha256=sha(p.read_bytes())) for p in stdout_files],combined_sha256=sha(stdout),vnode_lines=sum('vnode unlinked' in l for l in text.splitlines()),extended6922=text.count('"extended":6922'),sqlite_failure_lines=sum('SQLite failure' in l for l in text.splitlines()),e5rt_lines=sum('e5rt' in l for l in text.splitlines()),rollback_failure_lines=[l for l in text.splitlines() if 'SQLite failure' in l and '"operation":"rollback"' in l],raw_sqlite_lines=[l for l in text.splitlines() if 'SQLite failure' in l or 'vnode unlinked' in l]))
raw={p.name:p.read_bytes() for p in Path(prefix+'-events').glob('*.json')};bridge={p.name:p.read_bytes() for p in Path(prefix+'-bridge').glob('*.json')}
manifest=json.loads(Path(prefix+'-attachments/manifest.json').read_text()) if Path(prefix+'-attachments/manifest.json').is_file() else []
matches=[];mismatches=[];captured=set();ocrparts={'input':{},'result':{}}
for test in manifest:
 for a in test['attachments']:
  name=a['suggestedHumanReadableName'];file=a['exportedFileName'];data=(Path(prefix+'-attachments')/file).read_bytes()
  m=re.match(r'sqlite-fixture-([0-9A-F-]{36})_',name);b=re.match(r'(bridge61-[0-9A-F-]{36}-.+?)_',name)
  kind='scopes' if m else 'bridge' if b else None;key=m[1]+'.json' if m else b[1]+'.json' if b else None
  if kind:
   original=(raw if m else bridge).get(key);captured.add((kind,key))
   if original!=data:mismatches.append(dict(test=test['testIdentifier'],name=name,kind=kind,file=key))
   matches.append(dict(test=test['testIdentifier'],name=name,exported=file,kind=kind,file=key,sha256=sha(data),bytes=len(data),exact=original==data))
  o=re.match(r'ocr-([0-9A-F-]{36})-(input|result)_',name)
  if o:ocrparts[o[2]][o[1]]=dict(test=test['testIdentifier'],exported=file,data=data)
missing=[dict(kind=k,file=n) for k,files in [('scopes',raw),('bridge',bridge)] for n in files if (k,n) not in captured]
write('attachment-audit.json',dict(matches=matches,mismatches=mismatches,missing=missing,scope_files=len(raw),bridge_files=len(bridge)))
cases=[];total=collections.Counter();families=collections.Counter();violations=[]
for filename,data in sorted(raw.items()):
 rows=json.loads(data);live={};counts=collections.Counter();accepted=set();roots=[];removed=[];issues=[]
 for index,row in enumerate(rows):
  stage=row['stage'];counts[stage]+=1
  if stage=='root-owned':roots.append(row['root']);families[re.sub(r'-[0-9A-F-]{36}$','',row['root'])]+=1
  if stage=='opened':
   if row['connection'] in live:issues.append(dict(kind='duplicate-open',index=index))
   live[row['connection']]=row['root']
  if stage=='closed':
   if row['connection'] not in live or row['result']!='0':issues.append(dict(kind='bad-close',index=index,row=row))
   if row['result']=='0':live.pop(row['connection'],None)
  if stage=='root-removed':
   removed.append(row['root'])
   if live or row['exists']!='false':issues.append(dict(kind='unsafe-unlink',index=index,live=dict(live),row=row))
  if stage=='teardown-timeout':issues.append(dict(kind='teardown-timeout',index=index,row=row))
  if stage=='expected-sqlite-failure':
   at=int(row['eventIndex'])
   if at>=index or at in accepted or rows[at].get('diagnostic')!=row['diagnostic'] or rows[at].get('acceptedBy')!=row['expectation']:issues.append(dict(kind='invalid-fault-acceptance',index=index,row=row))
   accepted.add(at)
 if live:issues.append(dict(kind='unclosed-handles',live=live))
 if collections.Counter(roots)!=collections.Counter(removed):issues.append(dict(kind='root-mismatch',roots=roots,removed=removed))
 total.update(counts);violations.extend(dict(file=filename,**x) for x in issues)
 cases.append(dict(file=filename,test=rows[0].get('test'),counts=dict(counts),roots=roots,removed=removed,issues=issues))
write('native-audit.json',dict(scope_files=len(raw),counts=dict(total),families=dict(families),violations=violations,cases=cases))
ocr=[];ocrerrors=[]
for identity in sorted(ocrparts['input'].keys()|ocrparts['result'].keys()):
 if identity not in ocrparts['input'] or identity not in ocrparts['result']:ocrerrors.append(dict(invocation=identity,error='unpaired input/result'));continue
 i=ocrparts['input'][identity];o=ocrparts['result'][identity];v=json.loads(o['data']);valid=v['inputSHA256']==sha(i['data']) and v['inputBytes']==len(i['data']) and i['test']==o['test']
 if not valid:ocrerrors.append(dict(invocation=identity,error='hash/bytes/test mismatch'))
 ocr.append(dict(invocation=identity,test=i['test'],input=i['exported'],input_sha256=sha(i['data']),input_bytes=len(i['data']),result=v,result_raw=o['data'].decode(),result_sha256=sha(o['data']),valid=valid))
write('ocr-audit.json',dict(invocations=ocr,errors=ocrerrors,stages=dict(collections.Counter(x['result']['stage'] for x in ocr))))
reports=[];timelines=[]
for name,data in sorted(bridge.items()):
 v=json.loads(data)
 if name.endswith('-failure.json'):reports.append(dict(file=name,sha256=sha(data),report=v))
 else:timelines.append(dict(file=name,scenario=v.get('scenario'),caseID=v.get('caseID'),dropped=v.get('dropped'),rows=len(v.get('rows',[])),sha256=sha(data)))
write('bridge-audit.json',dict(failure_reports=reports,timelines=timelines,actual_test_failures=summary.get('testFailures',[]) if summary else [],limits='Failure-recorder controls intentionally produce reports in passing tests; summary actual failures remain separate. Reads non-atomic; no root-cause inference.'))
write('checks.json',checks)
print(json.dumps(dict(checks=checks,native=dict(total),violations=len(violations),matches=len(matches),mismatches=len(mismatches),missing=len(missing),ocr=len(ocr),ocrerrors=len(ocrerrors),bridge_reports=len(reports),bridge_timelines=len(timelines)),ensure_ascii=False,indent=2))
