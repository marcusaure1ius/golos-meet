#!/usr/bin/env python3
"""Read only the owned synthetic host database and preserve observed UI receipts."""
from pathlib import Path
import argparse,datetime,hashlib,json,sqlite3
p=argparse.ArgumentParser();p.add_argument('stage');p.add_argument('--note',required=True);a=p.parse_args()
r=Path(__file__).parent/'results';h=json.loads((r/'host-source-receipt.json').read_text());root=Path(h['root'])/'library';target=r/'ui'/(a.stage+'.json');assert not target.exists()
c=sqlite3.connect('file:'+str(root/'knowledge.sqlite')+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
names=[row[0] for row in c.execute("select name from sqlite_master where type='table'") if 'memory' in row[0]]
tables={name:[{k:(v.hex() if isinstance(v,bytes) else v) for k,v in dict(row).items()} for row in c.execute('select * from "'+name+'"')] for name in names}
raw=(root/'ui-events.jsonl').read_bytes();calls=[json.loads(l) for l in raw.splitlines() if json.loads(l).get('action')=='fake_transport']
v=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),app=h['app'],binary_sha256=h['binary_sha256'],tables=tables,trace_raw=raw.decode(),trace_sha256=hashlib.sha256(raw).hexdigest(),fake_calls=len(calls),observed_note=a.note,limits='Observed note records CUA actions/state, not a machine-captured AX dump; SQL and trace are raw read-only captures.')
target.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps(dict(stage=a.stage,fake_calls=len(calls),events=len(tables['memory_events']))))
