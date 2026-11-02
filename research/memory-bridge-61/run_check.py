#!/usr/bin/env python3
"""Run one explicit check with free-space telemetry; never clear caches/retry."""
import argparse,json,os,shutil,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('mode',choices=['release','full']);p.add_argument('--prefix',type=Path,required=True);a=p.parse_args()
if shutil.disk_usage(Path.cwd()).free < 2*1024**3:raise SystemExit('Less than 2 GiB free; check not started')
env=dict(os.environ);command=['xcodebuild','build','-scheme','golos-meet','-configuration','Release','-destination','platform=macOS','-derivedDataPath','.build/xcode','CODE_SIGNING_ALLOWED=NO']
explicit={}
if a.mode=='full':
 weights=Path('/tmp/golos-embedding-native/e5-small')
 if not weights.is_dir():raise SystemExit('Explicit existing public E5 folder missing; no download')
 command=['make','check']
 explicit={'TEST_RUNNER_GOLOS_MEET_E5_FOLDER':str(weights),'TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS':'1','TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW':'1','TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE':str(a.prefix)+'-scopes','TEST_RUNNER_GOLOS_BRIDGE_EVIDENCE':str(a.prefix)+'-bridge','TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR':str(a.prefix)+'-migration'}
 env.update(explicit)
started=time.time();telemetry=[]
with Path(str(a.prefix)+'.log').open('wb') as log:
 child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env)
 while True:
  telemetry.append({'elapsed':time.time()-started,'freeBytes':shutil.disk_usage(Path.cwd()).free})
  result=child.poll()
  if result is not None:break
  time.sleep(1)
report={'mode':a.mode,'command':command,'cwd':str(Path.cwd()),'explicitEnvironment':explicit,'startedEpoch':started,'duration':time.time()-started,'returncode':result,'minimumFreeBytes':min(x['freeBytes'] for x in telemetry),'samples':telemetry}
Path(str(a.prefix)+'-run.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='samples'}))
raise SystemExit(result)
