#!/usr/bin/env python3
"""Run exactly one final make check, preserving disk and log-stage telemetry."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,time
prefix=Path('/private/tmp/golos58qui-full');log=prefix.with_suffix('.log');telemetry=Path(str(prefix)+'-telemetry.jsonl')
assert not log.exists() and not telemetry.exists(), 'Never overwrite or silently rerun a completed full check'
workspace=Path.cwd();derived='/private/tmp/golos58qui-derived'
env=os.environ.copy();env.update(TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=str(prefix)+'-events',TEST_RUNNER_GOLOS_MEET_E5_FOLDER='/tmp/golos-embedding-native/e5-small',TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS='1',TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW='1')
command=['make','check','DERIVED_DATA='+derived]
paths=['golos-meetTests/KnowledgeQuestionModelTests.swift']
receipt=dict(command=command,cwd=str(workspace),source_sha256={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},base=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),safe_test_environment={k:v for k,v in env.items() if k.startswith('TEST_RUNNER_GOLOS_')})
Path(str(prefix)+'-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
# Stop before low-space writes; do not compete with another xcodebuild.
assert os.statvfs('/private/tmp').f_bavail*os.statvfs('/private/tmp').f_frsize >= 6*1024**3, 'Low space: STOP before full'
assert subprocess.run(['pgrep','-x','xcodebuild'],stdout=subprocess.DEVNULL).returncode == 1, 'Another build is active: STOP before full'
start=time.monotonic();stages=[]
def sample(process=None):
 text=log.read_text(errors='replace') if log.exists() else ''
 for marker in ['Resolve Package Graph','Build description signature','Testing started','** TEST SUCCEEDED **','** TEST FAILED **','Test session results']:
  if marker in text and marker not in stages:stages.append(marker)
 row=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),elapsed=time.monotonic()-start,free_bytes=os.statvfs('/private/tmp').f_bavail*os.statvfs('/private/tmp').f_frsize,log_bytes=log.stat().st_size if log.exists() else 0,observed_stages=stages.copy(),process_exit=process.poll() if process else None)
 with telemetry.open('a') as out:out.write(json.dumps(row)+'\n');out.flush();os.fsync(out.fileno())
sample()
with log.open('w') as out:
 process=subprocess.Popen(command,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 while process.poll() is None:
  sample(process)
  if os.statvfs('/private/tmp').f_bavail*os.statvfs('/private/tmp').f_frsize < 4*1024**3:
   receipt['stop_reason']='low-space-runtime-floor-4GiB'
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL)
   break
  time.sleep(5)
 code=process.wait()
sample(process);receipt.update(exit_code=code,elapsed=time.monotonic()-start)
Path(str(prefix)+'-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(dict(exit_code=code,seconds=receipt['elapsed'],telemetry=str(telemetry))))
raise SystemExit(code)
