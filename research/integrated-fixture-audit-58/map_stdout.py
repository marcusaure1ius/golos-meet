#!/usr/bin/env python3
"""Attribute raw stderr lines only where native connection/event evidence exists."""
from pathlib import Path
import collections,gzip,hashlib,json,tarfile
r=Path(__file__).parent/'results'
scopes=[]
with tarfile.open(r/'scopes.tar.gz') as t:
 for m in t.getmembers():
  rows=json.loads(t.extractfile(m).read())
  for i,row in enumerate(rows):
   if row['stage']=='sqlite-failure':scopes.append(dict(file=m.name,event_index=i,test=rows[0].get('test'),diagnostic=json.loads(row['diagnostic']),acceptedBy=row.get('acceptedBy'),expected=row.get('expected')))
stdout=gzip.decompress((r/'stdout.txt.gz').read_bytes()).decode(errors='replace');sqlite=[];e5rt=[]
for i,line in enumerate(stdout.splitlines(),1):
 if 'SQLite failure {' in line:
  d=json.loads(line.split('SQLite failure ',1)[1]);matches=[x for x in scopes if x['diagnostic']==d]
  sqlite.append(dict(line=i,raw=line,diagnostic=d,scope_matches=matches,attribution='exact native diagnostic + connection identity' if matches else 'no registered scope match; exact test attribution unavailable in captured stdout'))
 if 'e5rt' in line:
  e5rt.append(dict(line=i,raw=line,attribution='System TextRecognition framework path; no per-invocation identity in this line',limits='Not the approved ONNX E5 path. No causal/harmlessness inference from this successful OCR workload.'))
value=dict(sqlite_lines=sqlite,e5rt_lines=e5rt,counts=dict(sqlite=len(sqlite),exact_scoped=sum(bool(x['scope_matches']) for x in sqlite),unattributed=sum(not x['scope_matches'] for x in sqlite),e5rt=len(e5rt),scoped_rollback=sum(x['diagnostic']['operation']=='rollback' for x in scopes),global_rollback=sum(x['diagnostic']['operation']=='rollback' for x in sqlite)),source_control_context=dict(path='golos-meetTests/ProjectDatabaseDiagnosticsTests.swift',test='commitErrorSurvivesFailedCleanupAndConnectionRemainsUsable()',contract='The source explicitly ends the transaction so wrapper COMMIT and cleanup ROLLBACK fail; that test Passed. No native UUID-to-test receipt was captured for this unscoped case, so the one global rollback line is not asserted to originate in it.'),limits='Global test pass is not per-line acceptance. Unattributed lines remain raw evidence, not silently accepted by fixture allowances.')
(r/'stdout-line-map.json.gz').write_bytes(gzip.compress((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode(),mtime=0))
print(json.dumps(value['counts']))
print(dict(collections.Counter((x['test'],x['acceptedBy'] is not None) for x in scopes)))
