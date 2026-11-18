#!/usr/bin/env python3
"""Preserve exact scoped attachment bytes and native event mapping for this change."""
from pathlib import Path
import collections,gzip,hashlib,json,re,shutil,subprocess
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
def sha(b):return hashlib.sha256(b).hexdigest()
def redact(s):return s.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>').replace('/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>')
def write(name,value): (r/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
checks={};audits={};scopes={};ocr=[]
for kind in ('before','retain','after','final-targeted','full'):
 prefix='/private/tmp/golos58assignment-'+kind
 s=json.loads(Path(prefix+'-summary.json').read_text());checks[kind]={k:s[k] for k in ('result','totalTestCount','passedTests','failedTests','expectedFailures','skippedTests','runtimeWarnings','testFailures')}
 checks[kind]['runs']={k:sum(d[k] for d in s['devicesAndConfigurations']) for k in ('passedTests','failedTests','expectedFailures','skippedTests')}
 write(kind+'-summary.json',json.loads(redact(json.dumps(s))))
 folder=Path(prefix+'-events');raw={p.name:p.read_text() for p in sorted(folder.glob('*.jsonl' if kind in ('before','retain') else '*.json'))}
 (r/(kind+'-events.json.gz')).write_bytes(gzip.compress(json.dumps(raw,ensure_ascii=False).encode(),mtime=0))
 write(kind+'-trace-hashes.json',{name:sha(text.encode()) for name,text in raw.items()})
 stdout='\n'.join(p.read_text(errors='replace') for p in sorted(Path(prefix+'-diagnostics').rglob('StandardOutputAndStandardError.txt')))
 (r/(kind+'-stdout.txt.gz')).write_bytes(gzip.compress(redact(stdout).encode(),mtime=0))
 (r/(kind+'-xcodebuild.log.gz')).write_bytes(gzip.compress(redact(Path(prefix+'.log').read_text(errors='replace')).encode(),mtime=0))
 vnode=[l for l in stdout.splitlines() if 'vnode unlinked' in l]
 native=[l for l in stdout.splitlines() if 'SQLite failure' in l or 'vnode unlinked' in l]
 write(kind+'-sqlite-stdout.json',json.loads(redact(json.dumps(native))))
 audits[kind]=dict(vnode=len(vnode),families=dict(collections.Counter(re.sub(r'-[0-9A-F-]{36}$','',m.group(1)) for l in vnode for m in re.finditer(r'/([^/]+)/knowledge.sqlite',l))),extended6922=stdout.count('"extended":6922'))
 caseAudits=[]
 for filename,text in raw.items():
  rows=[json.loads(l) for l in text.splitlines()] if kind in ('before','retain') else json.loads(text)
  live={};stats=collections.Counter();early=[];accepted=[]
  for index,row in enumerate(rows):
   stage=row['stage'];stats[stage]+=1
   if stage=='opened':assert row['connection'] not in live;live[row['connection']]=row['root']
   if stage=='closed':
    assert row['result']=='0';assert row['connection'] in live;del live[row['connection']]
   if stage=='root-removed':
    assert row['exists']=='false';early.append(dict(root=row['root'],open_connections=list(live)))
   if stage=='expected-sqlite-failure':
    source=int(row['eventIndex']);assert source not in accepted;accepted.append(source)
    assert rows[source]['stage']=='sqlite-failure' and rows[source]['acceptedBy']==row['expectation']
  assert not live,(kind,filename,live)
  if kind not in ('before','retain'):assert not any(x['open_connections'] for x in early),(kind,filename)
  caseAudits.append(dict(file=filename,test=rows[0].get('test'),counts=dict(stats),unlink=early))
 scopes[kind]=caseAudits
 if kind in ('before','retain'):
  shutil.copy2(Path(prefix+'-copy/control-receipt.json'),r/(kind+'-receipt.json'))
  shutil.copy2(Path(prefix+'-copy/golos-meetTests/AssignmentObservation.swift'),r/(kind+'-observer.swift.txt'))
 else:
  manifest=json.loads(Path(prefix+'-attachments/manifest.json').read_text());mapping=[];captured=set()
  for test in manifest:
   for attachment in test['attachments']:
    name=attachment['suggestedHumanReadableName'];p=Path(prefix+'-attachments')/attachment['exportedFileName'];match=re.match(r'sqlite-fixture-([0-9A-F-]{36})_',name)
    if match:
     scopeID=match.group(1);data=p.read_bytes();assert data==(folder/(scopeID+'.json')).read_bytes();captured.add(scopeID+'.json')
     mapping.append(dict(test=test['testIdentifier'],scope=scopeID,attachment=attachment['exportedFileName'],sha256=sha(data)))
  assert captured==set(raw),(kind,len(captured),len(raw))
  write(kind+'-attachment-audit.json',mapping)
  if kind=='full':
   inputAttachments={};resultAttachments={}
   for test in manifest:
    for a in test['attachments']:
     m=re.match(r'ocr-([0-9A-F-]{36})-(input|result)_',a['suggestedHumanReadableName'])
     if m:
      record=(test['testIdentifier'],Path(prefix+'-attachments')/a['exportedFileName'])
      (inputAttachments if m[2]=='input' else resultAttachments)[m[1]]=record
   assert inputAttachments.keys()==resultAttachments.keys()
   assetFolder=r/'ocr-assets';assetFolder.mkdir(exist_ok=True)
   for identity,(test,p) in inputAttachments.items():
    data=p.read_bytes();result=resultAttachments[identity][1];value=json.loads(result.read_text());assert value['inputSHA256']==sha(data) and value['inputBytes']==len(data)
    asset=sha(data)+p.suffix;target=assetFolder/asset
    if target.exists():assert target.read_bytes()==data
    else:target.write_bytes(data)
    ocr.append(dict(test=test,invocation=identity,input=asset,result=value,result_sha256=sha(result.read_bytes())))
   # All other JSON attachments include staged bridge diagnostics when present.
   other={a['suggestedHumanReadableName']:(Path(prefix+'-attachments')/a['exportedFileName']).read_text() for t in manifest for a in t['attachments'] if a['exportedFileName'].endswith('.json') and not a['suggestedHumanReadableName'].startswith(('sqlite-fixture-','ocr-'))}
   write('full-other-json-attachments.json',json.loads(redact(json.dumps(other))))
write('checks.json',checks);write('stdout-audit.json',audits);write('scope-audit.json',scopes);write('full-ocr-audit.json',ocr)
for name in ('receipt.json','telemetry.jsonl'):
 (r/('full-'+name)).write_text(redact(Path('/private/tmp/golos58assignment-full-'+name).read_text()))
shutil.copy2('/private/tmp/golos58assignment-retain-cleanup.json',r/'retain-parent-cleanup.json')
base='fc2a92956fd50bd791e4926d5b388c8fe39f84d4';p='golos-meetTests/MeetingAssignmentTests.swift'
original=subprocess.check_output(['git','show',base+':'+p],text=True);after=Path(p).read_text().split('@MainActor extension MeetingAssignmentTests')[0]
def assertions(s):return [l.strip().replace('f.reopenedStore()','ProjectStore(url: f.url)') for l in s.splitlines() if '#expect' in l or '#require' in l]
a=assertions(original);b=[l for l in assertions(after) if l!='let scope = try #require(SQLiteFixtureScope.current)'];assert a==b
paths=[p,'golos-meetTests/SQLiteFixtureScope.swift','golos-meetTests/SQLiteAsyncFaultExpectationTests.swift']
write('source-check.json',dict(base=base,assertion_lines=a,assertion_comparison='identical with constructor spelling normalized',source_sha256={p:sha(Path(p).read_bytes()) for p in paths},production_diff=subprocess.check_output(['git','diff',base,'--','golos-meet','asr'],text=True)))
print(json.dumps(dict(checks=checks,stdout=audits,scopes={k:len(v) for k,v in scopes.items()},ocr_invocations=len(ocr)),ensure_ascii=False,indent=2))
