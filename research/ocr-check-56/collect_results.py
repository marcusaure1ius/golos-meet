#!/usr/bin/env python3
"""Package synthetic inputs and lossless observations; never include model caches."""
from pathlib import Path
import gzip,hashlib,json,shutil,subprocess,re
ROOT=Path(__file__).parent
OUT=ROOT/'results';ASSETS=OUT/'assets'
ASSETS.mkdir(parents=True,exist_ok=True)
def sha(data): return hashlib.sha256(data).hexdigest()
def put_asset(path):
    data=path.read_bytes();name=sha(data)+path.suffix.lower()
    target=ASSETS/name
    if not target.exists(): target.write_bytes(data)
    return {'asset':'assets/'+name,'bytes':len(data),'sha256':sha(data)}
def save_json(name,data):
    (OUT/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
run_names=['baseline-sequential-default','baseline-parallel-default','candidate-parallel-default','baseline-parallel-cpu','isolated-default','isolated-cpu','fanout-default','fanout-preflight-default','fanout-cpu','threads-default','queue-fanout-default','worker-fanout-default','matched-reference','matched-queue']
runs={}
for name in run_names:
    folder=Path('/private/tmp/golos56-'+name)
    if not (folder/'summary.json').exists():continue
    summary=json.loads((folder/'summary.json').read_text())
    streams=[];assets={}
    for f in sorted(folder.glob('*.jsonl')):
        raw=f.read_bytes();events=[json.loads(l) for l in raw.splitlines()]
        streams.append({'id':f.stem,'raw_sha256':sha(raw),'events':events})
        for e in events:
            for key in ['image','input']:
                n=e.get(key)
                if n and Path(n).name==n and (folder/n).is_file():assets[n]=put_asset(folder/n)
    record={'summary':summary,'streams':streams,'assets':assets}
    for key in ['stdout.txt','stderr.txt']:
        f=folder/key
        if f.exists():
            data=f.read_bytes();record[key]={'sha256':sha(data),'bytes':len(data)}
            (OUT/(name+'-'+key+'.gz')).write_bytes(gzip.compress(data,mtime=0))
    save_json(name+'.json',record)
    runs[name]={'summary':summary,'report':name+'.json'}
save_json('probe-index.json',runs)
save_json('frozen-inputs.json',{f.name:put_asset(f) for f in sorted(Path('/private/tmp/golos56-frozen-inputs').iterdir()) if f.is_file()})
# Full instrumentation preserves actual per-invocation source and preprocessed images.
for name in ['baseline-full','candidate-full','candidate-overlay']:
    folder=Path('/private/tmp/golos56-'+name+'-events')
    if not folder.exists():continue
    records=[]
    for f in sorted(folder.glob('*.jsonl')):
        raw=f.read_bytes();events=[json.loads(l) for l in raw.splitlines()];assets={}
        for e in events:
            for key in ['image','input']:
                n=e.get(key)
                if n and Path(n).name==n and (folder/n).is_file():assets[n]=put_asset(folder/n)
        records.append({'id':f.stem,'raw_sha256':sha(raw),'events':events,'assets':assets})
    save_json(name+'-events.json',records)
# The source archive may contain unrelated system processes: publish ONLY filtered test PID data.
original=Path('/private/tmp/golos56-original-pr55/research/memory-panel-37')
for name in ['full-previous-failed','full-final-failed','ocr-png-activities','ocr-pdf-activities']:
    data=(original/'checks'/f'{name}.json').read_bytes()
    (OUT/(name+'.json')).write_bytes(data)
unified=Path('/private/tmp/golos56-original-pr55/original-vision-unified.json')
rows=json.loads(unified.read_text())
def redact(value):
    return value.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<test-temp>')
filtered=[{k:redact(v) if isinstance(v,str) else v for k,v in row.items() if k in ['timestamp','threadID','subsystem','eventMessage','activityIdentifier','parentActivityIdentifier']} for row in rows]
save_json('original-vision-unified-redacted.json',{'original_sha256':sha(unified.read_bytes()),'pid':84693,'records':filtered})
for name in ['sqlite-lifecycle','sqlite-retained']:
    file=Path('/private/tmp/golos56-'+name+'/lifecycle.jsonl')
    if file.exists():
        save_json(name+'.json',{'raw_sha256':sha(file.read_bytes()),'events':[json.loads(l) for l in file.read_text().splitlines()]})
sample=Path('/private/tmp/golos56-fanout-default.sample.txt')
if sample.exists():(OUT/'fanout-default-sample.txt.gz').write_bytes(gzip.compress(sample.read_bytes(),mtime=0))
# Machine-readable Xcode summaries, preserving failures/warnings and run identities.
checks={}
for name in ['baseline-full','baseline-instrumented-full','candidate-instrumented-full','sqlite-lifecycle','sqlite-retained','final-targeted','final-proof-full','candidate-overlay-full']:
    log=Path('/private/tmp/golos56-'+name+'.log')
    if not log.exists():continue
    text=log.read_text(errors='replace');m=re.search(r'\n\s*(/\S+\.xcresult)',text)
    if not m:continue
    result=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',m[1],'--format','json'],text=True,capture_output=True)
    if result.returncode:
        checks[name]={'xcresult':m[1],'unavailable':result.stderr};continue
    s=json.loads(result.stdout)
    checks[name]={'xcresult':m[1],'result':s['result'],'passed_tests':s['passedTests'],'failed_tests':s['failedTests'],'skipped_tests':s['skippedTests'],'passed_runs':sum(d['passedTests'] for d in s['devicesAndConfigurations']),
       'failures':s.get('testFailures',[]),'warnings':[{k:redact(v) if isinstance(v,str) else v for k,v in w.items()} for w in s.get('runtimeWarnings',[])]}
save_json('checks.json',checks)
# Build receipts document EXACT selected sources and explicit diagnostic-only patches.
receipts={}
for name in ['baseline-probe','candidate-probe','traced-baseline-probe','final-probe','executor-probe','queue-probe','worker-probe','matched-reference-probe','matched-queue-probe']:
    folder=Path('/private/tmp/golos56-'+name)
    if (folder/'build.json').exists():receipts[name]=json.loads((folder/'build.json').read_text())
for name in ['baseline-test-copy','candidate-test-copy']:
    folder=Path('/private/tmp/golos56-'+name)
    for f in ['diagnostic-copy.json','sqlite-diagnostic-copy.json','sqlite-retention-control.json','overlay-fix.json']:
        if (folder/f).exists():receipts[name+'/'+f]=json.loads((folder/f).read_text())
save_json('build-receipts.json',receipts)
print(json.dumps({'runs':len(runs),'assets':len(list(ASSETS.iterdir())),'checks':checks},ensure_ascii=False,indent=2))
