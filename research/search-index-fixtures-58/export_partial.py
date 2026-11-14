#!/usr/bin/env python3
"""Attempt read-only export of an interrupted bundle; it is never a full result."""
from pathlib import Path
import json,subprocess
prefix='/private/tmp/golos58si-partial';receipt=json.loads(Path('/private/tmp/golos58si-partial-bundle-receipt.json').read_text());bundle=receipt['preserved'];status={}
for noun in ('summary','tests'):
 with open(prefix+'-'+noun+'-raw.json','w') as out,open(prefix+'-'+noun+'-error.txt','w') as err:
  result=subprocess.run(['xcrun','xcresulttool','get','test-results',noun,'--path',bundle],stdout=out,stderr=err)
 status[noun]=result.returncode
for noun in ('diagnostics','attachments'):
 with open(prefix+'-'+noun+'-export.log','w') as out:
  result=subprocess.run(['xcrun','xcresulttool','export',noun,'--path',bundle,'--output-path',prefix+'-'+noun],stdout=out,stderr=subprocess.STDOUT)
 status[noun]=result.returncode
Path(prefix+'-export-status.json').write_text(json.dumps(dict(status='interrupted; not a completed full check',exports=status),indent=2)+'\n');print(status)
