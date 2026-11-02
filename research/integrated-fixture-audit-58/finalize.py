#!/usr/bin/env python3
"""Finalize criteria from saved evidence only; never mark independent review done."""
from pathlib import Path
import collections,gzip,hashlib,json,tarfile
r=Path(__file__).parent/'results'
def read(n):
 p=r/n;return json.loads(p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()))
checks=read('checks.json');native=read('native-audit.json');stdout=read('stdout-audit.json')
criteria=read('criteria-mapping.json')
criteria[1]['limits']='Сохраняются intentional faults/negative controls. В global stdout один rollback result1; в зарегистрированных scopes rollback faults0. Исторический unlink-associated rollback не приписывается этому контролю без connection trace.'
criteria[1]['status']='combined observed ledger supported' if not native['violations'] and stdout['vnode_lines']==stdout['extended6922']==0 else 'observed violations; see native/stdout audit'
criteria[2]['status']='supported for registered roots in completed combined workload' if not native['violations'] else 'observed violations'
criteria[3]['status']='one accepted combined make check Passed' if checks['status']=='Passed' else checks['status']
criteria[3]['limits']='Один новый Passed не отменяет historical red/partial и не устанавливает причину bridge61/OCR56; ASR E2E исключён штатным target'
(r/'criteria-mapping.json').write_text(json.dumps(criteria,ensure_ascii=False,indent=2)+'\n')
family=collections.defaultdict(collections.Counter)
with tarfile.open(r/'scopes.tar.gz') as saved:
 for m in saved.getmembers():
  rows=json.loads(saved.extractfile(m).read());connections={}
  for row in rows:
   stage=row['stage']
   if stage in ('root-owned','root-removed','opened'):
    name=__import__('re').sub(r'-[0-9A-F-]{36}$','',row['root']);family[name][stage]+=1
   if stage=='opened':connections[row['connection']]=name
   if stage=='closed' and row['result']=='0':family[connections[row['connection']]]['closed0']+=1
(r/'family-ledger.json').write_text(json.dumps(family,indent=2)+'\n')
(r/'artifact-sha256.json').write_text(json.dumps({str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(r.rglob('*')) if p.is_file() and p.name!='artifact-sha256.json'},indent=2)+'\n')
print(json.dumps(family,indent=2))
