#!/usr/bin/env python3
"""Collect completed P2 runs only. Never launches tests or OCR."""
from pathlib import Path
import collections,gzip,hashlib,json,re,shutil,subprocess
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
def sha(b):return hashlib.sha256(b).hexdigest()
def redact(s):return s.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>').replace('/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>')
def write(name,obj):(r/name).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
checks={};stdout_audit={}
for name,summary,events,diagnostics,log in [
 ('before','before-suite','before-suite','before-suite','before-suite'),
 ('targeted','targeted','targeted','targeted','targeted-authorized'),
 ('full','final-full','final','final-full','final-full')]:
 s=json.loads(Path('/private/tmp/golos60-p2-'+summary+'-summary.json').read_text())
 checks[name]=dict(result=s['result'],total_tests=s['totalTestCount'],passed_tests=s['passedTests'],failed_tests=s['failedTests'],expected_tests=s['expectedFailures'],skipped_tests=s['skippedTests'],passed_runs=sum(x['passedTests'] for x in s['devicesAndConfigurations']),failed_runs=sum(x['failedTests'] for x in s['devicesAndConfigurations']),expected_runs=sum(x['expectedFailures'] for x in s['devicesAndConfigurations']),warnings=s['runtimeWarnings'],failures=s['testFailures'])
 raw={p.name:p.read_text() for p in sorted(Path('/private/tmp/golos60-p2-'+events+'-events').glob('*.json'))}
 (r/(name+'-events.json.gz')).write_bytes(gzip.compress(json.dumps(raw,ensure_ascii=False).encode(),mtime=0))
 write(name+'-trace-hashes.json',{k:sha(v.encode()) for k,v in raw.items()})
 stdout='\n'.join(p.read_text(errors='replace') for p in sorted(Path('/private/tmp/golos60-p2-'+diagnostics+'-diagnostics').rglob('StandardOutputAndStandardError.txt')))
 (r/(name+'-stdout.txt.gz')).write_bytes(gzip.compress(redact(stdout).encode(),mtime=0))
 (r/(name+'-xcodebuild.log.gz')).write_bytes(gzip.compress(redact(Path('/private/tmp/golos60-p2-'+log+'.log').read_text(errors='replace')).encode(),mtime=0))
 lines=stdout.splitlines();unlink=[l for l in lines if 'vnode unlinked' in l]
 stdout_audit[name]=dict(vnode_lines=len(unlink),families=dict(collections.Counter(re.sub(r'-[0-9A-F-]{36}$','',m.group(1)) for l in unlink for m in re.finditer(r'/([^/]+)/knowledge.sqlite',l))),extended6922_lines=sum('"extended":6922' in l for l in lines))
write('checks.json',json.loads(redact(json.dumps(checks))))
write('stdout-audit.json',stdout_audit)
shutil.copy2('/private/tmp/golos60-p2-before-copy/p2-before-receipt.json',r/'before-receipt.json')
write('bridge-activities.json',json.loads(redact(Path('/private/tmp/golos60-p2-bridge-activities.json').read_text())))
for key in ['targeted','full','before']:
 log={'targeted':'/private/tmp/golos60-p2-targeted.log','full':'/private/tmp/golos60-p2-full.log','before':'/private/tmp/golos60-p2-before.log'}[key]
 (r/('discarded-'+key+'-attempt.log.gz')).write_bytes(gzip.compress(redact(Path(log).read_text(errors='replace')).encode(),mtime=0))
write('attempt-limitations.json',dict(sandbox_targeted='Exit74 before test execution: cache writes denied. Authorized targeted run completed.',infrastructure_full='Exit2 during dependency build; no completed bundle reader (Info.plist absent), no tests started. Log preserved. No causal claim from incomplete log.',before_selector='Succeeded command but selected0 tests; discarded as evidence. Entire frozen suite executed subsequently.',disk_pressure='Data volume observed around1.8GiB free during infrastructure investigation; root separately observed ENOSPC. Per-OCR free-space telemetry missing. Completed full occurred in this pressure/recovery window; no claim ENOSPC explains earlier/current e5rt13.',reruns='No completed red full repeated; no new build/OCR after coordinator pause. Mandatory gate after recovery remains separate.'))
# Exact scope attachments and synthetic OCR inputs/results from the completed red full.
export=Path('/private/tmp/golos60-p2-final-attachments');m=json.loads((export/'manifest.json').read_text())
fullraw=json.loads(gzip.decompress((r/'full-events.json.gz').read_bytes()));scopes=[];ocr={};assets=r/'ocr-assets';assets.mkdir(exist_ok=True)
for test in m:
 for a in test['attachments']:
  name=a['suggestedHumanReadableName'];data=(export/a['exportedFileName']).read_bytes()
  match=re.match(r'sqlite-fixture-([0-9A-F-]{36})_',name)
  if match:
   assert data==fullraw[match[1]+'.json'].encode();scopes.append(dict(id=match[1],test=test['testIdentifier'],sha256=sha(data)))
  match=re.match(r'ocr-([0-9A-F-]{36})-(input|result)_',name)
  if not match:continue
  record=ocr.setdefault(match[1],dict(test=test['testIdentifier']));kind=match[2]
  if kind=='result':record['result']=json.loads(data)
  else:
   ext=Path(a['exportedFileName']).suffix;file=sha(data)+ext;(assets/file).write_bytes(data);record['input']=dict(asset=file,sha256=sha(data),bytes=len(data))
for key,x in ocr.items():assert x['result']['inputSHA256']==x['input']['sha256'] and x['result']['inputBytes']==x['input']['bytes'],key
write('attachment-audit.json',dict(scope_count=len(scopes),scopes=scopes,ocr_attachment_count=2*len(ocr),ocr_invocations=len(ocr),ocr=ocr))
paths=['golos-meetTests/SQLiteFixtureScope.swift','golos-meetTests/SQLiteFaultExpectationTests.swift']
write('source-hashes.json',{p:sha(Path(p).read_bytes()) for p in paths})
print(json.dumps(dict(checks=checks,stdout_audit=stdout_audit,scopes=len(scopes),ocr=len(ocr)),ensure_ascii=False,indent=2))
