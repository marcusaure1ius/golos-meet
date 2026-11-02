#!/usr/bin/env python3
"""ONE build<=180s, never launch; preserve failures and reject a second attempt."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,time,uuid
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
receipt_path=r/'build-receipt.json';assert not receipt_path.exists(),'One build attempt only; preserve result and ask root before any next attempt'
base='24b49b067fcda107e397ed4f2461f9bb23de322f';ref='refs/heads/codex/37-project-memory-panel'
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
def free():
 s=os.statvfs('/private/tmp');return s.f_bavail*s.f_frsize
floor=6*1024**3;forecast=1024**3;budget=1024**3
assert free()>=floor+forecast,'STOP: reserve+forecast'
assert not git('diff',base,'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
assert subprocess.check_output(['git','ls-remote','--heads','origin',ref],text=True).split()==[base,ref],'STOP: remote55 changed'
inventory={name:subprocess.run(['pgrep','-x',name],capture_output=True,text=True) for name in ['xcodebuild','swiftc','swift-frontend']}
for name,result in inventory.items():
 assert result.returncode==1,('STOP: process present or inventory unavailable; exit3 is not absence',name,result.returncode,result.stdout,result.stderr)
temporary=Path('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T').resolve();assert temporary.is_dir()
qa=temporary/('golos-memory-gate37-'+uuid.uuid4().hex);assert not qa.exists()
command=['python3','research/build_memory_panel_preview.py','--gate-diagnostics','--gate-root',str(qa),'--derived-data','/private/tmp/golos37recovery-derived']
paths=['research/MemoryPanelGateDiagnostics.swift','research/build_memory_panel_preview.py']
source={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths}
receipt=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),code_head=git('rev-parse','HEAD'),base=base,command=command,output_root=str(qa),protected_diff_empty=True,diagnostic_source_sha256=source,preflight_free_bytes=free(),reserve_bytes=floor,forecast_bytes=forecast,output_budget_bytes=budget,build_budget_seconds=180,inventory={name:dict(exit_code=v.returncode,stdout=v.stdout,stderr=v.stderr) for name,v in inventory.items()},build_started=False,host_launched=False,actual_case_executed=False,status='preflight-complete')
def save():receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
def size():return sum(p.stat().st_size for p in qa.rglob('*') if p.is_file()) if qa.exists() else 0
save();telemetry=r/'build-telemetry.jsonl';assert not telemetry.exists();log=r/'build-driver.log';assert not log.exists()
env=os.environ.copy();env['TMPDIR']=str(temporary)+'/'
start=time.monotonic()
with log.open('w') as out:
 p=subprocess.Popen(command,stdout=out,stderr=subprocess.STDOUT,start_new_session=True,env=env);receipt.update(build_started=True,pid=p.pid);save()
 while p.poll() is None:
  row=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),elapsed=time.monotonic()-start,free_bytes=free(),output_bytes=size())
  with telemetry.open('a') as out:out.write(json.dumps(row)+'\n')
  if row['free_bytes']<floor or row['output_bytes']>budget or row['elapsed']>=180:
   receipt['stop_reason']='free<6GiB' if row['free_bytes']<floor else 'outputs>1GiB' if row['output_bytes']>budget else 'build>=180s';save();os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL)
   break
  time.sleep(.5)
 code=p.wait()
receipt.update(exit_code=code,elapsed=time.monotonic()-start,post_free_bytes=free(),output_bytes=size(),status='Build Passed; NOT launched; runtime NOT run' if code==0 and 'stop_reason' not in receipt else 'INCOMPLETE/FAILED build; NOT launched; no runtime verdict')
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in source.items()),'source changed during build'
if qa.exists():
 files={str(p.relative_to(qa)):dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(qa.rglob('*')) if p.is_file()}
 (r/'build-output-files.json').write_text(json.dumps(files,indent=2)+'\n')
 for name in ['source-manifest.json','source-allowlist.txt','compile-command.json','READ-BEFORE-ONE-AUTHORIZED-RUN.txt','build.log']:
  q=qa/name
  if q.exists():(r/name).write_bytes(q.read_bytes())
receipt['stdout']=log.read_text();save();print(json.dumps({k:receipt[k] for k in ['code_head','exit_code','elapsed','status','output_root','output_bytes','host_launched','actual_case_executed']}))
raise SystemExit(code)
