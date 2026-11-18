#!/usr/bin/env python3
"""Collect this local study's synthetic-only receipts; paths intentionally fixed."""
import collections,gzip,hashlib,json,re,shutil,subprocess
from pathlib import Path
out=Path(__file__).parent/'results';out.mkdir(exist_ok=True)
def write(name,value): (out/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def redact(s):
 return s.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>').replace('/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>')
for kind in ['before','retain']:
 root=Path('/private/tmp/golos58-'+kind+'-copy');raw=Path('/private/tmp/golos58-'+kind+'-evidence/events.jsonl')
 rows=[json.loads(l) for l in raw.read_text().splitlines()]
 # ObjectIdentifier addresses are irrelevant to ownership. Preserve stable
 # equality with opaque per-export IDs and retain the original raw digest.
 owners={x['owner']:f'owner-{i+1}' for i,x in enumerate({r['owner']:r for r in rows if 'owner' in r}.values())}
 for row in rows:
  if 'owner' in row:row['owner']=owners[row['owner']]
 write(kind+'-events.json',dict(original_raw_sha256=digest(raw),events=rows))
 shutil.copy2(root/'before-receipt.json',out/(kind+'-receipt.json'))
 shutil.copy2(root/'golos-meet/Util/FixtureBefore58.swift',out/(kind+'-observer.swift.txt'))
write('retain-parent-cleanup.json',json.loads(Path('/private/tmp/golos58-retain-parent-cleanup.json').read_text()))
write('native-unlink.json',[json.loads(l) for l in Path('/private/tmp/golos58-native-unlink.jsonl').read_text().splitlines()])
checks={}
for key in ['before','retain','targeted-third','controls','final-targeted','full','combined-full','combined-final']:
 log=Path('/private/tmp/golos58-'+key+'.log')
 if not log.exists():continue
 s=log.read_text(errors='replace');(out/(key+'-xcodebuild.log.gz')).write_bytes(gzip.compress(redact(s).encode(),mtime=0))
 summary_file={'full':'/private/tmp/golos58-full-summary.json','combined-full':'/private/tmp/golos58-combined-summary.json','combined-final':'/private/tmp/golos58-combined-final-summary.json'}.get(key)
 if summary_file:
  summary=json.loads(Path(summary_file).read_text())
 else:
  paths=re.findall(r'(/[^\n]+\.xcresult)',s)
  if not paths:continue
  bundle=paths[-1].strip()
  if not Path(bundle).exists():
   checks[key]={'summary_available':False,'xcresult':bundle,'limit':'Xcode retention; full xcodebuild log preserved'};continue
  summary=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',bundle]))
 checks[key]=dict(result=summary['result'],passed_tests=summary['passedTests'],failed_tests=summary['failedTests'],skipped_tests=summary['skippedTests'],passed_runs=sum(x['passedTests'] for x in summary['devicesAndConfigurations']),failures=summary.get('testFailures',[]),runtime_warnings=summary.get('runtimeWarnings',[]))
 checks[key]=json.loads(redact(json.dumps(checks[key])))
write('checks.json',checks)
for name,folder in [('first-targeted','/private/tmp/golos58-targeted-third-evidence'),('after','/private/tmp/golos58-combined-final-evidence'),('controls','/private/tmp/golos58-controls-evidence'),('failed-full-scopes','/private/tmp/golos58-full-evidence'),('failed-combined-scopes','/private/tmp/golos58-combined-evidence')]:
 dest=out/name;dest.mkdir(exist_ok=True)
 for p in Path(folder).glob('*.json'):shutil.copy2(p,dest/p.name)
for name,folder in [('prototype-crash','/private/tmp/golos58-first-diagnostics'),('old-base-full','/private/tmp/golos58-full-failed-diagnostics'),('combined-full','/private/tmp/golos58-combined-diagnostics'),('combined-final','/private/tmp/golos58-combined-final-diagnostics')]:
 files=sorted(Path(folder).rglob('StandardOutputAndStandardError.txt'))
 text='\n'.join(p.read_text(errors='replace') for p in files)
 (out/(name+'-stdout.txt.gz')).write_bytes(gzip.compress(redact(text).encode(),mtime=0))
 diagnostics=[l for l in text.splitlines() if 'vnode unlinked' in l or '"extended":6922' in l]
 write(name+'-sqlite-stdout.json',json.loads(redact(json.dumps(diagnostics))))
 if name=='combined-final':
  write('stdout-audit.json',dict(stdout_parts=len(files),vnode_unlinked_lines=sum('vnode unlinked' in x for x in diagnostics),extended6922_lines=sum('"extended":6922' in x for x in diagnostics),remaining_root_families=dict(collections.Counter(re.sub(r'-[0-9A-F-]{36}$','',m.group(1)) for l in diagnostics if 'vnode unlinked' in l for m in re.finditer(r'/([^/]+)/knowledge.sqlite',l)))))
for name in ['full-summary','combined-summary','combined-final-summary','bridge-failure-activities']:
 p=Path('/private/tmp/golos58-'+name+'.json')
 if p.exists():write(name+'.json',json.loads(redact(p.read_text())))
# Original #56 is historical, not relabelled as a new run.
for name in ['sqlite-lifecycle.json','sqlite-retained.json','sqlite-control-summary.json']:
 shutil.copy2(Path('research/ocr-check-56/results')/name,out/('original56-'+name))
sources=['golos-meet/Core/Knowledge/ProjectStore.swift']+[str(p) for p in Path('golos-meetTests').glob('*.swift') if p.name in ['SQLiteFixtureScope.swift','SQLiteFixtureLifecycleTests.swift','ProjectMemoryQueueTests.swift','ProjectMemoryUpdateTests.swift','IndexingProductionHooksTests.swift','MeetingAssignmentRuntimeTests.swift','LocalIndexingNativeTests.swift']]
write('source-hashes.json',{p:digest(Path(p)) for p in sources})
print(json.dumps(checks,ensure_ascii=False,indent=2))
