#!/usr/bin/env python3
import argparse,json,subprocess,time,os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--inputs',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--mode',choices=['sequential','parallel','fanout','threads'],required=True);p.add_argument('--compute',choices=['default','preflight-default','cpu'],required=True);p.add_argument('--repeats',type=int,default=3);p.add_argument('--timeout',type=int,default=120);p.add_argument('--expect',choices=['success','timeout'],default='success');p.add_argument('--strict',action='store_true');p.add_argument('--isolated-home',type=Path);a=p.parse_args()
if not 1 <= a.repeats <= 8 or not 1 <= a.timeout <= 300: p.error('bounded limits: repeats 1..8, timeout 1..300')
a.output.mkdir(parents=True,exist_ok=False)
cmd=[str(a.binary),str(a.inputs),str(a.output),a.mode,a.compute,str(a.repeats)]
start=time.monotonic();timedout=False
environment=os.environ.copy()
if a.strict: environment['LIBDISPATCH_COOPERATIVE_POOL_STRICT']='1'
if a.isolated_home:
 a.isolated_home.mkdir(parents=True,exist_ok=False)
 environment['CFFIXED_USER_HOME']=str(a.isolated_home)
with (a.output/'stdout.txt').open('wb') as out,(a.output/'stderr.txt').open('wb') as err:
 try:r=subprocess.run(cmd,stdout=out,stderr=err,timeout=a.timeout,env=environment);code=r.returncode
 except subprocess.TimeoutExpired:timedout=True;code=None
counts={};events={};framework_errors=[];assertion_mismatches=[];parse_errors=[]
for f in a.output.glob('*.jsonl'):
 rows=[]
 for line in f.read_text().splitlines():
  try: rows.append(json.loads(line))
  except json.JSONDecodeError as error: parse_errors.append({'id':f.stem,'error':str(error)})
 events[f.stem]=rows
 if not rows: continue
 last=rows[-1]['stage']
 outcome=rows[-1].get('outcome', 'framework-error' if last=='extract-error' else 'incomplete')
 errors=[row for row in rows if row['stage']=='perform-error']
 extraction_errors=[row for row in rows if row['stage']=='extract-error']
 if errors:
  framework_errors.append({'id':f.stem,'errors':errors})
  outcome='framework-error'
 elif extraction_errors: outcome='extract-error'
 if any(row.get('outcome')=='assertion-mismatch' for row in rows): assertion_mismatches.append(f.stem)
 counts[outcome]=counts.get(outcome,0)+1
summary={'process_outcome':'process-timeout' if timedout else ('process-error' if code else 'completed'),'not_started_invocations':max(0,8*a.repeats-len(events)),'command':cmd,'seconds':time.monotonic()-start,'returncode':code,'timeout':timedout,'outcomes':counts,'expected_invocations':8*a.repeats,'observed_invocations':len(events),'framework_errors':framework_errors,'assertion_mismatches':assertion_mismatches,'parse_errors':parse_errors,'strict_pool_requested':a.strict,'isolated_home':str(a.isolated_home) if a.isolated_home else None}
summary['expectation']=a.expect
summary['expected_outcome_observed']=(timedout and bool(events)) if a.expect=='timeout' else (not timedout and code==0 and counts=={'success':8*a.repeats} and not parse_errors)
(a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))

if not summary['expected_outcome_observed']: raise SystemExit(1)
