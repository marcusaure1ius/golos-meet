#!/usr/bin/env python3
"""One meaningful targeted and one final full; no overwrites/repeat-to-green."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('kind',choices=['targeted','full']);kind=p.parse_args().kind
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
prefix=Path('/private/tmp/golos37recovery-'+kind);derived=Path('/private/tmp/golos37recovery-derived');log=Path(str(prefix)+'.log');telemetry=Path(str(prefix)+'-telemetry.jsonl');receipt_path=Path(str(prefix)+'-receipt.json')
assert not any(p.exists() for p in (log,telemetry,receipt_path)), 'Never overwrite/retry a run'
def free():
 s=os.statvfs('/private/tmp');return s.f_bavail*s.f_frsize
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
floor=6*1024**3;forecast=3*1024**3
assert free()>=floor+forecast,'STOP: forecast/reserve'
assert subprocess.run(['pgrep','-x','xcodebuild'],stdout=subprocess.DEVNULL).returncode==1,'STOP: other build'
frozen='50e22e00504ec2f87628464c9ed68fa8c4bb09e7';accepted='23b1da158304a2c0c596752d9150e489b1884fb4'
for sha in (frozen,accepted):subprocess.run(['git','merge-base','--is-ancestor',sha,'HEAD'],check=True)
assert git('rev-parse','origin/codex/37-project-memory-panel')==frozen,'STOP: remote changed'
assert not git('diff','HEAD','--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
source={f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in git('ls-files','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile').splitlines() if Path(f).is_file()}
if not derived.exists():
 derived.mkdir();subprocess.run(['cp','-cR','/private/tmp/golos58integrated-derived/SourcePackages',str(derived/'SourcePackages')],check=True)
env=os.environ.copy();env.update(TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=str(prefix)+'-events',TEST_RUNNER_GOLOS_BRIDGE_EVIDENCE=str(prefix)+'-bridge')
if kind=='full':
 model=next(m for m in json.loads(Path('research/model-comparison-28/models.json').read_text())['models'] if m['id']=='e5-small');assert model['revision']=='fd1525a9fd15316a2d503bf26ab031a61d056e98'
 assets=[a for a in model['files'] if a['required_for_inference']];assert len(assets)==5
 entries=re.findall(r'\.init\(path: "([^"]+)", bytes: (\d+), sha256: "([0-9a-f]{64})"\)',Path('golos-meet/Core/Knowledge/EmbeddingModelManifest.swift').read_text())
 assert {(p,int(n),h) for p,n,h in entries}=={(a['path'],a['bytes'],a['sha256']) for a in assets}
 for a in assets:
  f=Path('/tmp/golos-embedding-native/e5-small')/a['path'];assert f.stat().st_size==a['bytes'] and hashlib.sha256(f.read_bytes()).hexdigest()==a['sha256']
 (r/'model-preflight.json').write_text(json.dumps(dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),revision=model['revision'],repository=model['repository'],assets=assets,download=False,inference=False),indent=2)+'\n')
 env.update(TEST_RUNNER_GOLOS_MEET_E5_FOLDER='/tmp/golos-embedding-native/e5-small',TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS='1',TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW='1',TEST_RUNNER_GOLOS_MEET_RENDER_MEMORY_PANEL=str(prefix)+'-renders')
 command=['make','check','DERIVED_DATA='+str(derived)]
else:
 command=['xcodebuild','test','-project','golos-meet.xcodeproj','-scheme','golos-meet','-destination','platform=macOS','-derivedDataPath',str(derived),'-disableAutomaticPackageResolution','-skipPackageUpdates',*['-only-testing:golos-meetTests/'+s for s in ['ProjectMemoryPanelTests','ProjectMemoryQueueTests','MemoryBridgeDiagnosticsTests','MemoryBridgeOverflowTests','TestHostIsolationTests']],'CODE_SIGNING_ALLOWED=NO']
receipt=dict(kind=kind,command=command,cwd=str(Path.cwd()),head=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}'),accepted=accepted,frozen55=frozen,source_sha256=source,reserve_bytes=floor,forecast_bytes=forecast,preflight_free_bytes=free(),safe_test_environment={k:v for k,v in env.items() if k.startswith('TEST_RUNNER_GOLOS_')},started_epoch=time.time(),status='running')
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
print(json.dumps(dict(kind=kind,exit_code=code,elapsed=receipt['elapsed'],minimum_free=min(json.loads(s)['free_bytes'] for s in telemetry.read_text().splitlines()),status=receipt['status'])))
raise SystemExit(code)
