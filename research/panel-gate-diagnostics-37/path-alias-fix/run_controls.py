#!/usr/bin/env python3
"""ONE <=60s Foundation-only path validator. Failure preserves receipt; no retry."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,tempfile,time,uuid
folder=Path(__file__).parent;r=folder/'controls';r.mkdir(exist_ok=True)
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(data):return hashlib.sha256(data).hexdigest()
def free():
    s=os.statvfs('/private/tmp');return s.f_bavail*s.f_frsize
receipt=dict(startedUTC=utc(),kind='ONE Foundation-only addressed controls; no host/SQLite/models/network',
    code_head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),status='PREFLIGHT incomplete',started=False)
output=r/'receipt.json'
with output.open('x') as out:json.dump(receipt,out,indent=2);out.write('\n')
def save():output.write_text(json.dumps(receipt,indent=2)+'\n')
qa=None;child=None;failure=None
try:
    floor=6*1024**3;budget=256*1024**2
    receipt['free_before']=free();assert free()>=floor+budget,'STOP: space'
    temporary=Path(tempfile.gettempdir()).resolve();assert str(temporary).startswith('/private/var/folders/') and temporary.name=='T'
    qa=temporary/('golos-path-controls37-'+uuid.uuid4().hex);qa.mkdir()
    helper=Path('research/DiagnosticGatePaths.swift');harness=folder/'controls.swift'
    assert helper.read_text().count('import Foundation')==1 and 'import ' not in helper.read_text().replace('import Foundation','')
    combined=helper.read_bytes()+b'\n'+harness.read_bytes()
    (qa/'check.swift').write_bytes(combined);(r/'check.swift').write_bytes(combined)
    command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)','/usr/bin/swift','-swift-version','5','-module-cache-path',str(qa/'module-cache'),str(qa/'check.swift'),str(qa)]
    receipt.update(command=command,root=str(qa),helper_sha256=sha(helper.read_bytes()),harness_sha256=sha(harness.read_bytes()),combined_sha256=sha(combined),preflight_free_bytes=free(),reserve_bytes=floor,output_budget_bytes=budget,time_budget_seconds=60)
    save();start=time.monotonic()
    with (r/'stdout.txt').open('x') as out,(r/'stderr.txt').open('x') as err:
        child=subprocess.Popen(command,stdout=out,stderr=err,start_new_session=True)
        receipt.update(started=True,pid=child.pid,process_startedUTC=utc());save()
        while child.poll() is None:
            size=sum(p.stat().st_size for p in qa.rglob('*') if p.is_file())
            row=dict(utc=utc(),elapsed=time.monotonic()-start,free_bytes=free(),output_bytes=size)
            with (r/'telemetry.jsonl').open('a') as log:log.write(json.dumps(row)+'\n')
            if row['elapsed']>=60 or row['free_bytes']<floor or size>budget:
                receipt['stop_reason']=row;save();os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL)
                break
            time.sleep(.25)
        code=child.wait()
    receipt.update(exit_code=code,elapsed=time.monotonic()-start,free_after=free(),finishedUTC=utc())
    if (qa/'control-results.json').exists():(r/'control-results.json').write_bytes((qa/'control-results.json').read_bytes())
    assert code==0 and 'stop_reason' not in receipt,'STOP: addressed controls failed/incomplete; no automatic retry'
    cases=json.loads((r/'control-results.json').read_text());assert len(cases)==16 and all(c['passed'] for c in cases)
    assert sha(helper.read_bytes())==receipt['helper_sha256'] and sha(harness.read_bytes())==receipt['harness_sha256']
    receipt.update(status='Foundation-only addressed controls Passed; no app/runtime case run',control_count=len(cases))
except Exception as error:
    failure=repr(error);receipt.update(status='STOP INCOMPLETE/FAILED; no retry; root assessment required',failure=failure)
finally:
    if child is not None and child.poll() is None:os.killpg(child.pid,signal.SIGTERM);child.wait(timeout=5)
    receipt['artifact_sha256']={p.name:sha(p.read_bytes()) for p in r.iterdir() if p.is_file() and p!=output}
    save();print(json.dumps(receipt,ensure_ascii=False,indent=2))
raise SystemExit(1 if failure else 0)
