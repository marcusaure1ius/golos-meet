#!/usr/bin/env python3
"""ONE first actual path-helper host compile after independent driver fixes; never launch."""
from pathlib import Path
import datetime, gzip, hashlib, json, os, signal, subprocess, tempfile, time, uuid, sys
sys.dont_write_bytecode=True
from preflight import capture_status,bind

folder=Path(__file__).resolve().parent
repo=Path(subprocess.check_output(['git','rev-parse','--show-toplevel'],text=True).strip()).resolve()
os.chdir(repo)
r=folder/'results-first-compile';r.mkdir(exist_ok=True)
receipt_path=r/'build-receipt.json'
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
def free():
    s=os.statvfs('/private/tmp');return s.f_bavail*s.f_frsize
receipt=dict(utc=utc(),authorization='Root after independent fda driver P2 review: ONE FIRST ACTUAL host compile; immutable controls; no launch',
    status='PREFLIGHT incomplete',build_started=False,host_launched=False,actual_case_executed=False)
receipt['status_capture']=capture_status(repo,folder)
receipt['current_compile_checkpoint']=git('rev-parse','HEAD')
receipt['phase']='status captured BEFORE assertion'
with receipt_path.open('x') as out:json.dump(receipt,out,indent=2);out.write('\n')
def save():receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
def publish(phase,details):
    receipt.update(phase=phase,**details);save()
def linked():
    old=json.loads((folder.parent/'results/linked-inputs-postbuild.json').read_text())
    return {p:dict(bytes=Path(p).stat().st_size,sha256=sha(p)) for p in old['files']}
qa=None;child=None;failure=None
try:
    subprocess.run(['python3','-B',str(folder/'prepare.py'),'--check'],check=True)
    provenance=bind(repo,receipt['current_compile_checkpoint'],receipt['status_capture'],publish)
    (r/'control-source-binding.json').write_text(json.dumps(provenance,indent=2)+'\n')
    base='24b49b067fcda107e397ed4f2461f9bb23de322f';ref='refs/heads/codex/37-project-memory-panel'
    assert not git('diff',base,'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
    floor=6*1024**3;forecast=1024**3;budget=1024**3
    assert free()>=floor+forecast,'STOP: reserve6GiB+forecast1GiB'
    remote=subprocess.run(['git','ls-remote','--heads','origin',ref],capture_output=True,text=True,timeout=20)
    receipt['remote55_preflight']=dict(command=remote.args,exit_code=remote.returncode,stdout=remote.stdout,stderr=remote.stderr);save()
    assert remote.returncode==0 and remote.stdout.split()==['acfe44fb379a9ba8de3c0aa5de7fefb9c93bd28f',ref],'STOP: remote55 guard unavailable/changed'
    inventory={}
    for name in ['xcodebuild','swiftc','swift-frontend']:
        result=subprocess.run(['pgrep','-x',name],capture_output=True,text=True)
        inventory[name]=dict(exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr)
    receipt['inventory']=inventory;save()
    assert all(v['exit_code']==1 for v in inventory.values()),'STOP: process present/inventory unavailable; exit3 is not absence'
    temporary=Path(tempfile.gettempdir()).resolve()
    assert str(temporary).startswith('/private/var/folders/') and temporary.name=='T'
    qa=temporary/('golos-memory-gate37-'+uuid.uuid4().hex);assert not qa.exists()
    old_root=Path(json.loads((folder.parent/'results/build-receipt.json').read_text())['output_root']);assert qa!=old_root
    command=['python3','research/build_memory_panel_preview.py','--gate-diagnostics','--gate-root',str(qa),'--derived-data','/private/tmp/golos37recovery-derived']
    sources={p:sha(p) for p in ['research/MemoryPanelGateDiagnostics.swift','research/DiagnosticGatePaths.swift','research/build_memory_panel_preview.py']}
    linked_before=linked()
    assert linked_before==json.loads((folder.parent/'results/linked-inputs-postbuild.json').read_text())['files'],'STOP: reviewed linked inputs changed'
    receipt.update(code_head=git('rev-parse','HEAD'),base=base,command=command,output_root=str(qa),
        diagnostic_source_sha256=sources,preflight_free_bytes=free(),reserve_bytes=floor,forecast_bytes=forecast,
        output_budget_bytes=budget,build_budget_seconds=180,status='preflight-complete')
    save()
    def size():return sum(p.stat().st_size for p in qa.rglob('*') if p.is_file()) if qa.exists() else 0
    def sample(start):return dict(utc=utc(),elapsed=time.monotonic()-start,free_bytes=free(),output_bytes=size())
    env=os.environ.copy();env['TMPDIR']=str(temporary)+'/'
    start=time.monotonic()
    with (r/'build-driver.log').open('x') as out:
        child=subprocess.Popen(command,stdout=out,stderr=subprocess.STDOUT,start_new_session=True,env=env)
        receipt.update(build_started=True,pid=child.pid);save()
        while child.poll() is None:
            row=sample(start)
            with (r/'build-telemetry.jsonl').open('a') as telemetry:telemetry.write(json.dumps(row)+'\n')
            if row['free_bytes']<floor or row['output_bytes']>budget or row['elapsed']>=180:
                receipt['stop_reason']='free<6GiB' if row['free_bytes']<floor else 'outputs>1GiB' if row['output_bytes']>budget else 'build>=180s';save()
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL)
                break
            time.sleep(.5)
        code=child.wait()
    last=sample(start)
    with (r/'build-telemetry.jsonl').open('a') as telemetry:telemetry.write(json.dumps(last)+'\n')
    receipt.update(exit_code=code,elapsed=last['elapsed'],post_free_bytes=last['free_bytes'],output_bytes=last['output_bytes'])
    save()
    linked_after=linked()
    (r/'linked-inputs.json').write_text(json.dumps(dict(before=linked_before,after=linked_after,unchanged=linked_before==linked_after),indent=2)+'\n')
    assert linked_before==linked_after,'External linked inputs changed'
    assert all(sha(p)==h for p,h in sources.items()),'Source changed during build'
    assert code==0 and 'stop_reason' not in receipt and last['elapsed']<180 and last['free_bytes']>=floor and last['output_bytes']<=budget,'STOP: build failed/incomplete/budget'
    signature=json.loads((qa/'signature-receipt.json').read_text())
    compiled=json.loads((qa/'source-manifest.json').read_text())
    assert compiled['sourceCommit']==receipt['current_compile_checkpoint'] and compiled['files']==provenance['compile_source_sha256']
    assert signature['commands'][-1]['kind']=='verify' and all(c['exit_code']==0 for c in signature['commands'])
    assert not (qa/'library').exists(),'Unexpected runtime library'
    receipt['status']='FIRST actual path-helper host compile/signature verify Passed; NOT launched; runtime NOT RUN'
except Exception as error:
    failure=repr(error);receipt.update(status='STOP INCOMPLETE/FAILED; no retry; root assessment required',failure=failure)
finally:
    if child is not None and child.poll() is None:
        os.killpg(child.pid,signal.SIGTERM);child.wait(timeout=5)
    if qa is not None and qa.exists():
        files={str(p.relative_to(qa)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(qa.rglob('*')) if p.is_file()}
        with gzip.GzipFile(filename=str(r/'build-output-files.json.gz'),mode='wb',mtime=0) as out:out.write((json.dumps(files,indent=2)+'\n').encode())
        for name in ['source-manifest.json','source-allowlist.txt','compile-command.json','READ-BEFORE-ONE-AUTHORIZED-RUN.txt','build.log','signature-receipt.json']:
            q=qa/name
            if q.exists():(r/name).write_bytes(q.read_bytes())
    save()
    print(json.dumps(receipt,ensure_ascii=False,indent=2))
raise SystemExit(1 if failure else 0)
