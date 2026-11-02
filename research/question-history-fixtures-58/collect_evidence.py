#!/usr/bin/env python3
"""Collect this study's synthetic traces and stdout; keep exact per-case bytes."""
from pathlib import Path
import collections,gzip,hashlib,json,re,shutil,subprocess
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
def sha(data):return hashlib.sha256(data).hexdigest()
def redact(s):
 return s.replace('/Users/alfa','<user-home>').replace('/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>').replace('/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T','<synthetic-temp>')
def write(name,value): (r/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
checks={};audits={}
for kind in ['before','retain','after','controls','full']:
 summary=json.loads(Path('/private/tmp/golos58qh-'+kind+'-summary.json').read_text())
 checks[kind]=dict(result=summary['result'],passed_tests=summary['passedTests'],failed_tests=summary['failedTests'],skipped_tests=summary['skippedTests'],passed_runs=sum(x['passedTests'] for x in summary['devicesAndConfigurations']),warnings=summary['runtimeWarnings'],failures=summary.get('testFailures',[]))
 folder=Path('/private/tmp/golos58qh-'+kind+'-events')
 suffix='*.jsonl' if kind in ['before','retain'] else '*.json'
 raw={p.name:p.read_text() for p in sorted(folder.glob(suffix))}
 payload=json.dumps(raw,ensure_ascii=False).encode()
 (r/(kind+'-events.json.gz')).write_bytes(gzip.compress(payload,mtime=0))
 write(kind+'-trace-hashes.json',{name:sha(text.encode()) for name,text in raw.items()})
 stdout='\n'.join(p.read_text(errors='replace') for p in sorted(Path('/private/tmp/golos58qh-'+kind+'-diagnostics').rglob('StandardOutputAndStandardError.txt')))
 (r/(kind+'-stdout.txt.gz')).write_bytes(gzip.compress(redact(stdout).encode(),mtime=0))
 log=Path('/private/tmp/golos58qh-'+kind+'.log').read_text(errors='replace')
 (r/(kind+'-xcodebuild.log.gz')).write_bytes(gzip.compress(redact(log).encode(),mtime=0))
 lines=stdout.splitlines();unlink=[l for l in lines if 'vnode unlinked' in l]
 audits[kind]=dict(vnode_unlinked_lines=len(unlink),families=dict(collections.Counter(re.sub(r'-[0-9A-F-]{36}$','',m.group(1)) for l in unlink for m in re.finditer(r'/([^/]+)/knowledge.sqlite',l))),extended6922_lines=sum('"extended":6922' in l for l in lines))
 write(kind+'-sqlite-stdout.json',json.loads(redact(json.dumps([l for l in lines if 'vnode unlinked' in l or 'SQLite failure' in l]))))
 if kind in ['before','retain']:
  source=Path('/private/tmp/golos58qh-'+kind+'-copy')
  shutil.copy2(source/'control-receipt.json',r/(kind+'-receipt.json'))
  shutil.copy2(source/'golos-meetTests/QuestionHistoryObservation.swift',r/(kind+'-observer.swift.txt'))
write('checks.json',json.loads(redact(json.dumps(checks))))
write('stdout-audit.json',audits)
shutil.copy2('/private/tmp/golos58qh-retain-cleanup.json',r/'retain-parent-cleanup.json')
paths=['golos-meetTests/'+name+'.swift' for name in ['KnowledgeQuestionServiceTests','ProjectMemoryHistoryTests','SQLiteFixtureScope']]
write('source-hashes.json',{name:sha(Path(name).read_bytes()) for name in paths})
# Publish the actual compiler invocation from xcodebuild and unchanged app tree.
write('base.json',dict(accepted_preview='9dfdf8feecf83e94782c0e78acfdd0b2d920a37e',reviewed_head59='2a5907a79c21f8ad8e394961fa68b9275609c1a3',application_diff=subprocess.check_output(['git','diff','--name-only','--','golos-meet','asr'],text=True).splitlines()))
print(json.dumps(dict(checks=checks,stdout_audit=audits),ensure_ascii=False,indent=2))
