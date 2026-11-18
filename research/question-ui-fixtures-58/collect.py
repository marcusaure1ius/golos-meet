#!/usr/bin/env python3
"""Preserve exact synthetic traces and attachment bytes; never run tests here."""
from pathlib import Path
import collections,gzip,hashlib,json,re,shutil,subprocess
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
def sha(b):return hashlib.sha256(b).hexdigest()
def redact(s):return s.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>').replace('/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>')
def write(name,value):
 data=(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode()
 if len(data)>16384:(r/(name+'.gz')).write_bytes(gzip.compress(data,mtime=0))
 else:(r/name).write_bytes(data)
checks={};audits={};scopes={};ocr=[]
for kind in ('before','before-probe','retain','after','full'):
 prefix='/private/tmp/golos58qui-'+kind
 s=json.loads(Path(prefix+'-summary.json').read_text());checks[kind]={k:s[k] for k in ('result','totalTestCount','passedTests','failedTests','expectedFailures','skippedTests','runtimeWarnings','testFailures')}
 checks[kind]['runs']={k:sum(d[k] for d in s['devicesAndConfigurations']) for k in ('passedTests','failedTests','expectedFailures','skippedTests')}
 write(kind+'-summary.json',json.loads(redact(json.dumps(s))))
 before=kind in ('before','before-probe','retain')
 folder=Path(prefix+'-events');raw={p.name:p.read_text() for p in sorted(folder.glob('*.jsonl' if before else '*.json'))}
 (r/(kind+'-events.json.gz')).write_bytes(gzip.compress(json.dumps(raw,ensure_ascii=False).encode(),mtime=0))
 write(kind+'-trace-hashes.json',{name:sha(text.encode()) for name,text in raw.items()})
 stdout='\n'.join(p.read_text(errors='replace') for p in sorted(Path(prefix+'-diagnostics').rglob('StandardOutputAndStandardError.txt')))
 (r/(kind+'-stdout.txt.gz')).write_bytes(gzip.compress(redact(stdout).encode(),mtime=0))
 (r/(kind+'-xcodebuild.log.gz')).write_bytes(gzip.compress(redact(Path(prefix+'.log').read_text(errors='replace')).encode(),mtime=0))
 vnode=[l for l in stdout.splitlines() if 'vnode unlinked' in l]
 write(kind+'-sqlite-stdout.json',json.loads(redact(json.dumps([l for l in stdout.splitlines() if 'SQLite failure' in l or 'vnode unlinked' in l]))))
 audits[kind]=dict(vnode=len(vnode),families=dict(collections.Counter(re.sub(r'-[0-9A-F-]{36}$','',m.group(1)) for l in vnode for m in re.finditer(r'/([^/]+)/knowledge.sqlite',l))),extended6922=stdout.count('"extended":6922'))
 cases=[]
 for filename,text in raw.items():
  rows=list(map(json.loads,text.splitlines())) if before else json.loads(text)
  live={};stats=collections.Counter();unlink=[];accepted=set()
  for index,row in enumerate(rows):
   stage=row['stage'];stats[stage]+=1
   if stage=='opened':assert row['connection'] not in live;live[row['connection']]=row['root']
   if stage=='closed':assert row['result']=='0';del live[row['connection']]
   if stage=='root-removed':
    assert row['exists']=='false';unlink.append(dict(root=row['root'],open_connections=list(live)))
   if stage=='expected-sqlite-failure':
    at=int(row['eventIndex']);assert at not in accepted;accepted.add(at)
    assert rows[at]['diagnostic']==row['diagnostic'] and rows[at]['acceptedBy']==row['expectation']
  assert not live,(kind,filename,live)
  if not before:assert not any(x['open_connections'] for x in unlink)
  cases.append(dict(file=filename,test=rows[0].get('test'),counts=dict(stats),unlink=unlink))
 scopes[kind]=cases
 if before:
  copy=Path('/private/tmp/golos58qui-'+('before' if kind=='before-probe' else kind)+'-copy')
  shutil.copy2(copy/'control-receipt.json',r/(kind+'-receipt.json'))
  shutil.copy2(copy/'golos-meetTests/QuestionUIObservation.swift',r/(kind+'-observer.swift.txt'))
  if kind!='before':shutil.copy2(copy/'probe-receipt.json',r/(kind+'-probe-receipt.json'))
 else:
  manifest=json.loads(Path(prefix+'-attachments/manifest.json').read_text());mapping=[];captured=set()
  for test in manifest:
   for a in test['attachments']:
    name=a['suggestedHumanReadableName'];p=Path(prefix+'-attachments')/a['exportedFileName'];m=re.match(r'sqlite-fixture-([0-9A-F-]{36})_',name)
    if m:
     identity=m[1];data=p.read_bytes();assert data==(folder/(identity+'.json')).read_bytes();captured.add(identity+'.json')
     mapping.append(dict(test=test['testIdentifier'],scope=identity,attachment=a['exportedFileName'],sha256=sha(data)))
  assert captured==set(raw),(kind,len(captured),len(raw));write(kind+'-attachment-audit.json',mapping)
  if kind=='full':
   inputs={};outputs={}
   for test in manifest:
    for a in test['attachments']:
     m=re.match(r'ocr-([0-9A-F-]{36})-(input|result)_',a['suggestedHumanReadableName'])
     if m:(inputs if m[2]=='input' else outputs)[m[1]]=(test['testIdentifier'],Path(prefix+'-attachments')/a['exportedFileName'])
   assert inputs.keys()==outputs.keys();assets=r/'ocr-assets';assets.mkdir(exist_ok=True)
   for identity,(test,p) in inputs.items():
    data=p.read_bytes();result=outputs[identity][1].read_text();value=json.loads(result)
    assert value['inputSHA256']==sha(data) and value['inputBytes']==len(data)
    name=sha(data)+p.suffix;target=assets/name
    if target.exists():assert target.read_bytes()==data
    else:target.write_bytes(data)
    ocr.append(dict(test=test,invocation=identity,input=name,result=value,result_raw=result,result_sha256=sha(result.encode())))
write('checks.json',checks);write('stdout-audit.json',audits);write('scope-audit.json',scopes);write('full-ocr-audit.json',ocr)
for name in ('receipt.json','telemetry.jsonl'):(r/('full-'+name)).write_text(redact(Path('/private/tmp/golos58qui-full-'+name).read_text()))
shutil.copy2('/private/tmp/golos58qui-retain-cleanup.json',r/'retain-parent-cleanup.json')
base='7be254c4a1eceb28755ad60d718a4ed72cb21179';path='golos-meetTests/KnowledgeQuestionModelTests.swift'
original=subprocess.check_output(['git','show',base+':'+path],text=True);after=Path(path).read_text().split('@MainActor private final class QuestionUIWitness')[0]
def assertions(s):return [l.strip().replace('f.reopenedStore()','ProjectStore(url: f.root.appendingPathComponent("knowledge.sqlite"))') for l in s.splitlines() if '#expect' in l or '#require' in l]
a=assertions(original);b=[l for l in assertions(after) if l!='let scope = try #require(SQLiteFixtureScope.current)'];assert a==b
write('source-check.json',dict(base=base,assertion_lines=a,assertion_comparison='identical with reopened constructor spelling normalized',source_sha256={path:sha(Path(path).read_bytes())},production_diff=subprocess.check_output(['git','diff',base,'--','golos-meet','asr'],text=True),allowance_diff=subprocess.check_output(['git','diff',base,'--','golos-meetTests/SQLiteFixtureScope.swift'],text=True)))
print(json.dumps(dict(checks=checks,stdout=audits,scopes={k:len(v) for k,v in scopes.items()},ocr_invocations=len(ocr)),ensure_ascii=False,indent=2))
