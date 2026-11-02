"""Read-only structured status and immutable controls/source provenance. No compiler."""
from pathlib import Path, PurePosixPath
import hashlib,json,subprocess

CONTROL_HEAD='35c4da62abe23c4de90656525617676d75fbdcf7'
REVIEW_HEAD='fda8a2f104501b1f6bcf2b25446342729421dd92'
PRODUCTION='24b49b067fcda107e397ed4f2461f9bb23de322f'
PREFIX='research/panel-gate-diagnostics-37/'
CONTROL_FOLDER=PREFIX+'path-alias-fix/controls/'
DRIVER_FOLDER=PREFIX+'path-driver-fix/'
SOURCES={
    'research/DiagnosticGatePaths.swift':'17e72c66e142e379517bb38d596329d8cf682465b3b719675e03a7712c645c15',
    'research/MemoryPanelGateDiagnostics.swift':'1628d3b018d5f72cc671d4fc034303f392ab0c4954399506e6f4d499572dec4e',
    'research/build_memory_panel_preview.py':'1ec090093a376a0b61f82981d7840890f79e9019c476ae79e20e9b413bbfd570',
    PREFIX+'path-alias-fix/controls.swift':'91fade077b2081fee6c4590c5624a106895c32b9b2c3247b99c1ae4824d03171',
}
def git(repo,*args):return subprocess.check_output(['git',*args],cwd=repo)
def digest(data):return hashlib.sha256(data).hexdigest()
def clean_file(repo,name):
    relative=PurePosixPath(name)
    assert not relative.is_absolute() and name==relative.as_posix() and '..' not in relative.parts and '.' not in relative.parts,name
    path=repo.joinpath(*relative.parts)
    for part in [path,*path.parents]:
        if part==repo:break
        assert not part.is_symlink(),f'STOP: symlink {part}'
    assert path.resolve().is_relative_to(repo) and path.is_file(),f'STOP: outside/non-file {name}'
    return path.read_bytes()

def capture_status(repo,folder):
    command=['git','status','--porcelain=v1','-z','--untracked-files=all']
    result=subprocess.run(command,cwd=repo,capture_output=True)
    entries=[];error=None
    try:
        parts=result.stdout.split(b'\0');index=0
        while index<len(parts)-1:
            record=parts[index];index+=1
            assert len(record)>=4 and record[2:3]==b' ',repr(record)
            status=record[:2].decode('ascii');name=record[3:].decode('utf-8')
            item=dict(status=status,path=name)
            if 'R' in status or 'C' in status:
                item['original_path']=parts[index].decode('utf-8');index+=1
            entries.append(item)
        assert not parts[-1], 'porcelain -z missing trailing NUL'
    except Exception as exc:error=repr(exc)
    return dict(phase='status captured BEFORE assertion/attempt-file creation',command=command,cwd=str(repo),
        normalized_driver_folder=folder.resolve().relative_to(repo).as_posix(),exit_code=result.returncode,
        stdout_hex=result.stdout.hex(),stdout_text=result.stdout.decode('utf-8','surrogateescape'),
        stderr=result.stderr.decode('utf-8','surrogateescape'),entries=entries,parse_error=error)

def bind(repo,head,status,publish):
    # All tolerated dirty files have exact immutable git-object identities. No subtree exemption.
    names=git(repo,'ls-tree','-r','--name-only',REVIEW_HEAD,CONTROL_FOLDER).decode().splitlines()
    allowlist={name:digest(git(repo,'show',REVIEW_HEAD+':'+name)) for name in names}
    publish('status-and-exact-allowlist-before-assertion',dict(status_capture=status,dirty_file_sha256_allowlist=allowlist))
    assert status['exit_code']==0 and status['parse_error'] is None,'STOP: status unavailable/unparseable'
    assert status['normalized_driver_folder']==DRIVER_FOLDER.rstrip('/'),'STOP: unexpected driver folder'
    for item in status['entries']:
        assert item['status']=='??','STOP: modified/staged/deleted tracked path'
        name=item['path'];assert name in allowlist,'STOP: foreign/unreceipted untracked file '+name
        assert digest(clean_file(repo,name))==allowlist[name],'STOP: dirty artifact hash mismatch '+name

    publish('ancestry-and-scope-before-assertion',dict(current_compile_checkpoint=head,immutable_control_checkpoint=CONTROL_HEAD,reviewed_head=REVIEW_HEAD))
    for ancestor in [CONTROL_HEAD,REVIEW_HEAD]:
        subprocess.run(['git','cat-file','-e',ancestor+'^{commit}'],cwd=repo,check=True)
        subprocess.run(['git','merge-base','--is-ancestor',ancestor,head],cwd=repo,check=True)
    scoped=git(repo,'diff','--name-only','-z',REVIEW_HEAD,head).split(b'\0')
    scoped=[p.decode() for p in scoped if p]
    publish('reviewed-scope-diff-before-assertion',dict(reviewed_scope_diff=scoped))
    for name in scoped:assert name==PREFIX+'README.md' or name.startswith(DRIVER_FOLDER),'STOP: semantic/unreviewed scope change '+name

    receipt_bytes=clean_file(repo,CONTROL_FOLDER+'receipt.json')
    assert receipt_bytes==git(repo,'show',REVIEW_HEAD+':'+CONTROL_FOLDER+'receipt.json'),'STOP: immutable control receipt changed'
    controls=json.loads(receipt_bytes)
    publish('immutable-control-receipt-before-assertion',dict(control_receipt_sha256=digest(receipt_bytes),original_control_code_head=controls.get('code_head')))
    assert controls['code_head']==CONTROL_HEAD and controls['exit_code']==0 and controls['control_count']==16
    artifacts={}
    for name,h in allowlist.items():
        value=clean_file(repo,name);assert digest(value)==h,name;artifacts[name]=h
    for name,h in controls['artifact_sha256'].items():
        assert '/' not in name and digest(clean_file(repo,CONTROL_FOLDER+name))==h,name
    actual={}
    for name,h in SOURCES.items():
        current=clean_file(repo,name)
        assert digest(current)==h,name
        assert current==git(repo,'show',CONTROL_HEAD+':'+name)==git(repo,'show',REVIEW_HEAD+':'+name)==git(repo,'show',head+':'+name),name
        actual[name]=h
    helper=clean_file(repo,'research/DiagnosticGatePaths.swift')
    harness=clean_file(repo,PREFIX+'path-alias-fix/controls.swift')
    combined=helper+b'\n'+harness
    assert combined==clean_file(repo,CONTROL_FOLDER+'check.swift') and digest(combined)==controls['combined_sha256']
    assert digest(helper)==controls['helper_sha256'] and digest(harness)==controls['harness_sha256']
    cases=json.loads(clean_file(repo,CONTROL_FOLDER+'control-results.json'))
    stdout=clean_file(repo,CONTROL_FOLDER+'stdout.txt').decode()
    decoded,end=json.JSONDecoder().raw_decode(stdout)
    assert decoded==cases and 'allPassed=true; aliasIdentitiesMatch=true' in stdout[end:]
    assert len(cases)==16 and all(c['passed'] and c['actual']==c['expected'] for c in cases)
    positives=[c['resolution'] for c in cases if c['expected']=='accepted']
    assert len(positives)==3
    for key in ['temporaryIdentity','outputIdentity','library']:assert all(p[key]==positives[0][key] for p in positives)
    original=Path(controls['root'])
    assert (original/'check.swift').read_bytes()==combined
    assert (original/'control-results.json').read_bytes()==clean_file(repo,CONTROL_FOLDER+'control-results.json')
    # Every compile input, including the new helper, is bound to CURRENT checkpoint.
    prior=json.loads(clean_file(repo,PREFIX+'final-fix/results/source-manifest.json'))
    compile_names=list(prior['files'])+['research/DiagnosticGatePaths.swift']
    compile_files={}
    for name in compile_names:
        current=clean_file(repo,name);assert current==git(repo,'show',head+':'+name),name
        compile_files[name]=digest(current)
    assert len(compile_files)==60
    assert not git(repo,'diff',PRODUCTION,head,'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
    result=dict(current_compile_checkpoint=head,control_checkpoint=CONTROL_HEAD,control_checkpoint_is_ancestor=True,
        reviewed_head=REVIEW_HEAD,reviewed_scope_diff=scoped,control_receipt_sha256=digest(receipt_bytes),
        immutable_control_artifact_sha256=artifacts,source_sha256=actual,combined_sha256=digest(combined),
        compile_source_sha256=compile_files,compile_source_count=60,controls_rerun=False,
        limits='Byte/ancestry provenance, no new Foundation invocation; not a LaunchServices startup/UI proof')
    publish('control-source-compile-binding-complete',dict(provenance=result))
    return result
