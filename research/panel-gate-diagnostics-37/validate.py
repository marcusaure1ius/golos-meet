#!/usr/bin/env python3
"""Validate saved preparation/build evidence only. Never launch or execute a case."""
from pathlib import Path
import gzip,hashlib,json,plistlib,subprocess
r=Path(__file__).parent/'results'
def sha(b):return hashlib.sha256(b).hexdigest()
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()))
base='24b49b067fcda107e397ed4f2461f9bb23de322f';assessment=read('static-assessment.json');receipt=read('build-receipt.json')
assert assessment['base']==receipt['base']==base and assessment['plan_sha256']=='ddeee469bd5ce06b0fc0f02b0a55083ea6f00ed2f358c3ec148f8161bbae64ed'
for p,h in assessment['protected_source_sha256'].items():
 assert sha(Path(p).read_bytes())==h==sha(subprocess.check_output(['git','show',base+':'+p])),p
for p,h in receipt['diagnostic_source_sha256'].items():assert sha(Path(p).read_bytes())==h==sha(subprocess.check_output(['git','show',receipt['code_head']+':'+p])),p
assert receipt['build_started'] and not receipt['host_launched'] and not receipt['actual_case_executed']
assert receipt['exit_code']==0 and 'stop_reason' not in receipt and receipt['elapsed']<180 and receipt['output_bytes']<=1024**3
telemetry=[json.loads(l) for l in (r/'build-telemetry.jsonl').read_text().splitlines()]
assert min(v['free_bytes'] for v in telemetry)>=receipt['reserve_bytes']==6*1024**3
assert receipt['preflight_free_bytes']>=receipt['reserve_bytes']+receipt['forecast_bytes'] and receipt['forecast_bytes']==1024**3
assert all(v['exit_code']==1 for v in receipt['inventory'].values())
qa=Path(receipt['output_root']);assert qa.parent.name=='T' and str(qa).startswith('/private/var/folders/') and qa.name.startswith('golos-memory-gate37-')
assert not (qa/'library').exists(),'Unexpected runtime library: no launch was authorized'
manifest=read('source-manifest.json');assert manifest['mode']=='gate-diagnostics-build-only' and manifest['sourceCommit']==receipt['code_head']
for p,h in manifest['files'].items():assert sha(Path(p).read_bytes())==h,p
assert 'research/MemoryPanelGateDiagnostics.swift' in manifest['files'] and 'research/MemoryPanelPreview.swift' not in manifest['files']
for p in manifest['files']:
 assert Path(p).name not in ['OpenRouterClient.swift','Keychain.swift','golos_meetApp.swift','ProductionMemoryPanel.swift','AppDelegate.swift','Recorder.swift','LocalASR.swift']
app=qa/'Golos Memory Gate Diagnostics.app';info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'].startswith('com.golos.memory-gate37.') and info['SyntheticRoot']==str(qa/'library') and 'PublicWeightsFolder' not in info
assert info['SourceCommit']==receipt['code_head'] and info['SourceManifestSHA256']==sha((r/'source-manifest.json').read_bytes())
binary=app/'Contents/MacOS/MemoryPanelGateDiagnostics';assert binary.read_bytes()[:4]==b'\xcf\xfa\xed\xfe'
for p,m in read('build-output-files.json').items():
 q=qa/p;assert q.stat().st_size==m['bytes'] and sha(q.read_bytes())==m['sha256'],p
for p,m in read('linked-inputs-postbuild.json')['files'].items():
 q=Path(p);assert q.stat().st_size==m['bytes'] and sha(q.read_bytes())==m['sha256'],p
if (r/'artifact-sha256.json').exists():
 for p,h in read('artifact-sha256.json').items():assert sha((r/p).read_bytes())==h,p
print('Prepared-source/build evidence validated. ONE build Passed; host NOT launched; actual held case NOT RUN; independent review and root decision still required.')
