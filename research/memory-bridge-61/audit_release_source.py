from pathlib import Path
import subprocess,re,json,hashlib
base='fc2a92956fd50bd791e4926d5b388c8fe39f84d4'
def release(s):
 active=True;stack=[];out=[]
 for line in s.splitlines():
  token=line.strip()
  if token=='#if DEBUG':stack.append(active);active=False;continue
  if token=='#else' and stack:active=stack[-1] and not active;continue
  if token=='#endif' and stack:active=stack.pop();continue
  if active:out.append(line)
 assert not stack
 return '\n'.join(out)
records={}
for name in ['golos-meet/Core/Knowledge/ProjectMemoryQueueWorker.swift','golos-meet/UI/Projects/KnowledgeMemoryQueue.swift']:
 old=subprocess.check_output(['git','show',base+':'+name],text=True);new=Path(name).read_text()
 normalize=lambda s:re.sub(r'[\s;]','',s)
 a,b=normalize(release(old)),normalize(release(new))
 assert a==b,name
 records[name]={'normalizedReleaseTokensEqual':True,'sha256':hashlib.sha256(b.encode()).hexdigest(),'normalization':'Whitespace and optional statement semicolons only; DEBUG blocks excluded.'}
assert not release(Path('golos-meet/Core/Knowledge/MemoryQueueDiagnostics.swift').read_text()).strip()
Path('/tmp/golos61-release-source-audit.json').write_text(json.dumps(records,indent=2)+'\n')
print('Release source equivalence passed')
