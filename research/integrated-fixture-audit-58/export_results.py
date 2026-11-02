#!/usr/bin/env python3
"""Export the one finished/guard-stopped run; no tests, probes or model calls."""
from pathlib import Path
import hashlib,json,re,subprocess
prefix=Path('/private/tmp/golos58integrated-full');r=Path(__file__).parent/'results'
receipt=json.loads(Path(str(prefix)+'-receipt.json').read_text());assert 'exit_code' in receipt
log=Path(str(prefix)+'.log').read_text(errors='replace')
candidates=[Path(s.strip()) for s in re.findall(r'(/[^\n]+\.xcresult)',log) if Path(s.strip()).is_dir()]
selection='final log reference'
if not candidates:
 candidates=[p for p in Path('/private/tmp/golos58integrated-derived/Logs/Test').glob('*.xcresult') if p.stat().st_mtime>=receipt['started_epoch']-3]
 selection='unique own bundle modified since start (partial fallback)'
assert len(set(candidates))==1,(selection,candidates)
bundle=candidates[-1];preserved=Path('/private/tmp/golos58integrated-preserved-full.xcresult');assert not preserved.exists()
subprocess.run(['cp','-cR',str(bundle),str(preserved)],check=True)
files={str(p.relative_to(bundle)):dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(bundle.rglob('*')) if p.is_file()}
assert all((preserved/p).stat().st_size==v['bytes'] and hashlib.sha256((preserved/p).read_bytes()).hexdigest()==v['sha256'] for p,v in files.items())
(r/'bundle-receipt.json').write_text(json.dumps(dict(original=str(bundle),preserved=str(preserved),selection=selection,method='cp -cR; every file SHA256/size verified',files=files),indent=2)+'\n')
status={}
for noun in ('summary','tests'):
 with Path(str(prefix)+'-'+noun+'.json').open('w') as out,Path(str(prefix)+'-'+noun+'-error.txt').open('w') as err:
  status[noun]=subprocess.run(['xcrun','xcresulttool','get','test-results',noun,'--path',str(preserved)],stdout=out,stderr=err).returncode
for noun in ('diagnostics','attachments'):
 target=Path(str(prefix)+'-'+noun);assert not target.exists()
 with Path(str(prefix)+'-'+noun+'-export.log').open('w') as out:
  status[noun]=subprocess.run(['xcrun','xcresulttool','export',noun,'--path',str(preserved),'--output-path',str(target)],stdout=out,stderr=subprocess.STDOUT).returncode
if status['summary']==0:
 summary=json.loads(Path(str(prefix)+'-summary.json').read_text())
 for i,f in enumerate(summary.get('testFailures',[])):
  with Path(str(prefix)+f'-failure-{i}-activities.json').open('w') as out,Path(str(prefix)+f'-failure-{i}-error.txt').open('w') as err:
   status[f'failure-{i}-activities']=subprocess.run(['xcrun','xcresulttool','get','test-results','activities','--path',str(preserved),'--test-id',f['testIdentifierString']],stdout=out,stderr=err).returncode
(r/'export-status.json').write_text(json.dumps(status,indent=2)+'\n')
print(json.dumps(dict(bundle=str(preserved),exports=status)))
