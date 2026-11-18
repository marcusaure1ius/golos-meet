#!/usr/bin/env python3
"""Export an already finished xcresult, without running tests."""
from pathlib import Path
import argparse,re,subprocess
p=argparse.ArgumentParser();p.add_argument('kinds',nargs='+');a=p.parse_args()
for kind in a.kinds:
 prefix='/private/tmp/golos58qui-'+kind
 bundle=re.findall(r'(/[^\n]+\.xcresult)',Path(prefix+'.log').read_text())[-1].strip()
 assert Path(bundle).is_dir();Path(prefix+'-bundle.txt').write_text(bundle)
 for noun in ('summary','tests'):
  with open(prefix+'-'+noun+'.json','w') as out:subprocess.run(['xcrun','xcresulttool','get','test-results',noun,'--path',bundle],stdout=out,check=True)
 with open(prefix+'-export.log','a') as out:
  for noun in ('diagnostics','attachments'):
   target=Path(prefix+'-'+noun)
   if not target.exists():subprocess.run(['xcrun','xcresulttool','export',noun,'--path',bundle,'--output-path',str(target)],stdout=out,check=True)
 print(kind,bundle)
