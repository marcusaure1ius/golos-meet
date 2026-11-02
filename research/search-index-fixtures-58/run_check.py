#!/usr/bin/env python3
"""One guarded run per kind; never overwrite a completed or interrupted run."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('kind',choices=['after','full']);a=p.parse_args()
prefix=Path('/private/tmp/golos58si-'+a.kind);log=prefix.with_suffix('.log');telemetry=Path(str(prefix)+'-telemetry.jsonl')
assert not log.exists() and not telemetry.exists(), 'Do not overwrite evidence or rerun to green'
def free():return os.statvfs('/private/tmp').f_bavail*os.statvfs('/private/tmp').f_frsize
floor=6*1024**3
warm=Path('/private/tmp/golos58si-derived/Build/Products/Debug/Golos Meet.app').exists()
forecast=(1 if a.kind=='after' and not warm else .25)*1024**3
assert free()>=floor+forecast, 'STOP: forecast would consume the 6GiB reserve'
assert subprocess.run(['pgrep','-x','xcodebuild'],stdout=subprocess.DEVNULL).returncode==1,'STOP: another build is active'
derived='/private/tmp/golos58si-derived';env=os.environ.copy();env['TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE']=str(prefix)+'-events'
if a.kind=='full':
 env.update(TEST_RUNNER_GOLOS_MEET_E5_FOLDER='/tmp/golos-embedding-native/e5-small',TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS='1',TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW='1')
 command=['make','check','DERIVED_DATA='+derived]
else:command=['xcodebuild','test','-project','golos-meet.xcodeproj','-scheme','golos-meet','-destination','platform=macOS','-derivedDataPath',derived,'-disableAutomaticPackageResolution','-skipPackageUpdates','-only-testing:golos-meetTests/KnowledgeSearchTests','-only-testing:golos-meetTests/LocalIndexingServiceTests','CODE_SIGNING_ALLOWED=NO']
paths=['golos-meetTests/'+name+'.swift' for name in ('KnowledgeSearchTests','LocalIndexingServiceTests','SearchIndexFixtureCleanup')]
receipt=dict(command=command,cwd=str(Path.cwd()),base=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256={s:hashlib.sha256(Path(s).read_bytes()).hexdigest() for s in paths},reserve_bytes=floor,forecast_bytes=forecast,preflight_free_bytes=free(),safe_test_environment={k:v for k,v in env.items() if k.startswith('TEST_RUNNER_GOLOS_')})
start=time.monotonic();stages=[]
def sample(process=None):
 text=log.read_text(errors='replace') if log.exists() else ''
 for marker in ('Resolve Package Graph','Build description signature','Testing started','** TEST SUCCEEDED **','** TEST FAILED **','Test session results'):
  if marker in text and marker not in stages:stages.append(marker)
 row=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),elapsed=time.monotonic()-start,free_bytes=free(),log_bytes=log.stat().st_size if log.exists() else 0,observed_stages=stages.copy(),process_exit=process.poll() if process else None)
 with telemetry.open('a') as out:out.write(json.dumps(row)+'\n');out.flush();os.fsync(out.fileno())
sample()
with log.open('w') as out:
 process=subprocess.Popen(command,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 while process.poll() is None:
  sample(process)
  if free()<floor:
   receipt['stop_reason']='runtime-free-below-6GiB';os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL)
   break
  time.sleep(1)
 code=process.wait()
sample(process);receipt.update(exit_code=code,elapsed=time.monotonic()-start)
Path(str(prefix)+'-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(dict(exit_code=code,elapsed=receipt['elapsed'],minimum_free=min(json.loads(s)['free_bytes'] for s in telemetry.read_text().splitlines()),stop_reason=receipt.get('stop_reason'))))
raise SystemExit(code)
