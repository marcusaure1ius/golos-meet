#!/usr/bin/env python3
"""Validate the one saved final build/signature receipt; no compiler or launch."""
from pathlib import Path
import gzip, hashlib, json, plistlib, subprocess
folder=Path(__file__).parent;r=folder/'results'
def read(name):return json.loads((r/name).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
subprocess.run(['python3','-B',str(folder/'prepare.py'),'--check'],check=True)
receipt=read('build-receipt.json')
assert receipt['build_started'] and receipt['exit_code']==0 and 'failure' not in receipt and 'stop_reason' not in receipt
assert not receipt['host_launched'] and not receipt['actual_case_executed']
assert receipt['elapsed']<180 and receipt['output_bytes']<=1024**3
assert receipt['preflight_free_bytes']>=receipt['reserve_bytes']+receipt['forecast_bytes']
assert receipt['reserve_bytes']==6*1024**3 and receipt['forecast_bytes']==1024**3
assert all(v['exit_code']==1 for v in receipt['inventory'].values())
rows=[json.loads(line) for line in (r/'build-telemetry.jsonl').read_text().splitlines()]
assert rows and min(v['free_bytes'] for v in rows)>=receipt['reserve_bytes']
assert max(v['output_bytes'] for v in rows)<=1024**3
qa=Path(receipt['output_root']);assert qa.parent.name=='T' and str(qa).startswith('/private/var/folders/') and qa.name.startswith('golos-memory-gate37-')
old=json.loads((folder.parent/'results/build-receipt.json').read_text())
assert str(qa)!=old['output_root'] and not (qa/'library').exists() and not (Path(old['output_root'])/'library').exists()
manifest=read('source-manifest.json')
assert manifest['sourceCommit']==receipt['code_head'] and manifest['mode']=='gate-diagnostics-build-only'
for name,digest in manifest['files'].items():
    assert sha(name)==digest==hashlib.sha256(subprocess.check_output(['git','show',receipt['code_head']+':'+name])).hexdigest(),name
for name,digest in receipt['diagnostic_source_sha256'].items():assert sha(name)==digest,name
app=qa/'Golos Memory Gate Diagnostics.app';binary=app/'Contents/MacOS/MemoryPanelGateDiagnostics'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'].startswith('com.golos.memory-gate37.') and 'PublicWeightsFolder' not in info
old_info=plistlib.loads((Path(old['output_root'])/'Golos Memory Gate Diagnostics.app/Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']!=old_info['CFBundleIdentifier']
assert info['SyntheticRoot']==str(qa/'library') and info['SourceCommit']==receipt['code_head']
assert info['SourceManifestSHA256']==sha(r/'source-manifest.json')
signature=read('signature-receipt.json')
assert signature['scope']==str(app) and not signature['host_launched']
assert signature['commands'][-1]['kind']=='verify'
assert signature['commands'][-1]['command']==['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(app)]
assert all(v['exit_code']==0 for v in signature['commands'])
for item in signature['commands']:
    target=Path(item['command'][-1]);assert target.resolve().is_relative_to(app.resolve())
    if item['kind']=='sign':assert item['command'][:-1]==['/usr/bin/codesign','--force','--sign','-','--timestamp=none']
assert sha(binary)==signature['binary_sha256_after_sign'] and len(signature['binary_sha256_before_sign'])==64
files=json.loads(gzip.decompress((r/'build-output-files.json.gz').read_bytes()))
for name,item in files.items():
    q=qa/name;assert q.stat().st_size==item['bytes'] and sha(q)==item['sha256'],name
linked=read('linked-inputs.json');assert linked['unchanged'] and linked['before']==linked['after']
for name,item in linked['after'].items():assert Path(name).stat().st_size==item['bytes'] and sha(name)==item['sha256'],name
summary=dict(status='One final fix build and deep strict signature verify Passed; runtime NOT RUN',
    code_head=receipt['code_head'],source_manifest_sha256=sha(r/'source-manifest.json'),app=str(app),bundle=info['CFBundleIdentifier'],
    binary_sha256_before_sign=signature['binary_sha256_before_sign'],binary_sha256_after_sign=signature['binary_sha256_after_sign'],
    elapsed=receipt['elapsed'],output_bytes=receipt['output_bytes'],telemetry_samples=len(rows),minimum_free_bytes=min(v['free_bytes'] for v in rows),
    signature_commands=len(signature['commands']),strict_verify_exit_code=signature['commands'][-1]['exit_code'],
    old_bundle_unmodified_and_unlaunched=True,host_launched=False,actual_case_executed=False)
output=r/'build-summary.json'
if output.exists():assert json.loads(output.read_text())==summary
else:output.write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summary,ensure_ascii=False,indent=2))
