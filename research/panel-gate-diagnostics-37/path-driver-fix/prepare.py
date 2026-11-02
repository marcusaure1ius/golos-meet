#!/usr/bin/env python3
"""Static grouped driver fix assessment, with all controlled sources frozen."""
from pathlib import Path
import ast,hashlib,json,subprocess,sys
from preflight import SOURCES,REVIEW_HEAD,CONTROL_HEAD,PRODUCTION,PREFIX,DRIVER_FOLDER
folder=Path(__file__).resolve().parent
def git(*args):return subprocess.check_output(['git',*args])
def sha(data):return hashlib.sha256(data).hexdigest()
subprocess.run(['git','merge-base','--is-ancestor',REVIEW_HEAD,'HEAD'],check=True)
for p in git('diff','--name-only',REVIEW_HEAD).decode().splitlines()+git('ls-files','--others','--exclude-standard').decode().splitlines():
    assert p==PREFIX+'README.md' or p.startswith(DRIVER_FOLDER),p
preserved={}
for p in git('ls-tree','-r','--name-only',REVIEW_HEAD,PREFIX).decode().splitlines():
    if p==PREFIX+'README.md':continue
    h=sha(Path(p).read_bytes());assert h==sha(git('show',REVIEW_HEAD+':'+p)),p
    preserved[p]=h
for p,h in SOURCES.items():
    current=Path(p).read_bytes();assert sha(current)==h and current==git('show',CONTROL_HEAD+':'+p)==git('show',REVIEW_HEAD+':'+p),p
assert not git('diff',PRODUCTION,'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
for p,h in [('FINAL_STATIC_REVIEW.md','85c30e34eaf124053959702a288125b976b79e28234abcf5d58f9070f116d15e'),('static-review-receipt.json','2586dcd52d8feba50ebd1e64820adea2a191e177cac6a48c5536a336945449ad')]:assert sha((folder/'review-fda'/p).read_bytes())==h,p
scripts={p.name:sha(p.read_bytes()) for p in folder.glob('*.py')}
for p in folder.glob('*.py'):ast.parse(p.read_text())
stable=dict(reviewed_driver_failure_head=REVIEW_HEAD,immutable_control_checkpoint=CONTROL_HEAD,
    protected_source_base=PRODUCTION,frozen_source_sha256=SOURCES,preserved_file_sha256=preserved,driver_script_sha256=scripts,
    status='Static driver-only group fix; compiler/controls/app not executed by this assessment',
    limits=['Old receipts are immutable; new exclusive namespace results-first-compile',
        'Raw status/normalized folder captured before assertion; exact per-file whitelist',
        'Ancestry plus exact current/git/control-source bytes, no raw controls.code_head==HEAD',
        'New controls/host runtime/LaunchServices not run'])
output=folder/'static-assessment.json'
if sys.argv[1:]==['--check']:assert json.loads(output.read_text())==stable
else:
    assert not sys.argv[1:] and not output.exists();output.write_text(json.dumps(stable,ensure_ascii=False,indent=2)+'\n')
print('Driver-only static group fix assessment Passed; controlled helper/host/builder/harness unchanged.')
