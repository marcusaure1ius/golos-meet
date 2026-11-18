#!/usr/bin/env python3
"""Exactly one combined make check; preserve status, source and resource telemetry."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,time
r=Path(__file__).parent/'results'
prefix=Path('/private/tmp/golos58integrated-full');derived=Path('/private/tmp/golos58integrated-derived')
log=Path(str(prefix)+'.log');telemetry=Path(str(prefix)+'-telemetry.jsonl');receipt_path=Path(str(prefix)+'-receipt.json')
assert not any(p.exists() for p in (log,telemetry,receipt_path,derived)), 'Never overwrite/retry a run'
def free():
 s=os.statvfs('/private/tmp');return s.f_bavail*s.f_frsize
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
floor=6*1024**3;forecast=3*1024**3
assert free()>=floor+forecast,'STOP: forecast/reserve'
assert subprocess.run(['pgrep','-x','xcodebuild'],stdout=subprocess.DEVNULL).returncode==1,'STOP: other build'
assert git('rev-parse','HEAD')==git('rev-parse','origin/codex/product-preview')=='e9990685bdcf334039cbce7edbfb245750b0154a'
assert git('rev-parse','HEAD^{tree}')=='4284d8f240fd40d2abdd2efbd4968973a0d12df0'
assert not git('diff','HEAD','--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
proof=json.loads((r/'accepted-provenance.json').read_text())
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in proof['source_sha256'].items())
assert len(json.loads((r/'model-preflight.json').read_text())['assets'])==5
cache=Path('/Users/alfa/Development/golos-meet/.build/xcode/SourcePackages');assert (cache/'workspace-state.json').is_file()
derived.mkdir()
subprocess.run(['cp','-cR',str(cache),str(derived/'SourcePackages')],check=True)
env=os.environ.copy();env.update(TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=str(prefix)+'-events',TEST_RUNNER_GOLOS_BRIDGE_EVIDENCE=str(prefix)+'-bridge',TEST_RUNNER_GOLOS_MEET_E5_FOLDER='/tmp/golos-embedding-native/e5-small',TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS='1',TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW='1')
command=['make','check','DERIVED_DATA='+str(derived)]
receipt=dict(command=command,cwd=str(Path.cwd()),base=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}'),source_sha256=proof['source_sha256'],reserve_bytes=floor,forecast_bytes=forecast,preflight_free_bytes=free(),safe_test_environment={k:v for k,v in env.items() if k.startswith('TEST_RUNNER_GOLOS_')},cache_source=str(cache),cache_method='cp -cR APFS clone into owned DerivedData',cache_state_sha256=hashlib.sha256((cache/'workspace-state.json').read_bytes()).hexdigest(),started_epoch=time.time(),status='running')
def save():receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
save();start=time.monotonic();stages=[]
def sample(process=None):
 text=log.read_text(errors='replace') if log.exists() else ''
 for marker in ('Resolve Package Graph','Build description signature','Testing started','** TEST SUCCEEDED **','** TEST FAILED **','Test session results'):
  if marker in text and marker not in stages:stages.append(marker)
 row=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),elapsed=time.monotonic()-start,free_bytes=free(),log_bytes=log.stat().st_size if log.exists() else 0,observed_stages=stages.copy(),process_exit=process.poll() if process else None)
 with telemetry.open('a') as out:out.write(json.dumps(row)+'\n');out.flush();os.fsync(out.fileno())
sample()
with log.open('w') as out:
 process=subprocess.Popen(command,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True);receipt['pid']=process.pid;save()
 while process.poll() is None:
  sample(process)
  if free()<floor:
   receipt.update(stop_reason='runtime-free-below-6GiB',status='INCOMPLETE');save();os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL)
   break
  time.sleep(1)
 code=process.wait()
sample(process);receipt.update(exit_code=code,elapsed=time.monotonic()-start,finished_epoch=time.time(),status=receipt['status'] if 'stop_reason' in receipt else 'process-completed; xcresult verdict pending');save()
print(json.dumps(dict(exit_code=code,elapsed=receipt['elapsed'],minimum_free=min(json.loads(s)['free_bytes'] for s in telemetry.read_text().splitlines()),status=receipt['status'])))
raise SystemExit(code)
