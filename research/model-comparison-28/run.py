"""Run fixed native processes with all network denied; Python does no inference."""
import argparse,hashlib,json,platform,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--e5-folder',type=Path,required=True);p.add_argument('--minilm-folder',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
research=Path(__file__).resolve().parent;repo=research.parents[1]
a.output.mkdir(parents=True,exist_ok=False)
folders={'e5-small':a.e5_folder.resolve(),'minilm':a.minilm_folder.resolve()}
order=['e5-small','minilm','minilm','e5-small','e5-small','minilm'];counts={k:0 for k in folders}
commands=[]
for candidate in order:
    repetition=counts[candidate];counts[candidate]+=1
    report=a.output/f'{candidate}-{repetition}.json';vectors=a.output/f'{candidate}-{repetition}-vectors.json'
    command=['sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(a.binary.resolve()),candidate,str(folders[candidate]),str(research),str(report.resolve()),str(vectors.resolve()),str(repetition)]
    start=time.monotonic()
    with (a.output/f'{candidate}-{repetition}.log').open('w') as log:
        subprocess.run(command,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
    commands.append({'candidate':candidate,'repetition':repetition,'argv':command,'whole_process_seconds':time.monotonic()-start})
    print('Completed',candidate,repetition,flush=True)
def output(command): return subprocess.check_output(command,text=True).strip()
metadata={'source_base':output(['git','rev-parse','HEAD']), 'preregistered_corpus_commit':output(['git','rev-parse','3961bd2']),
          'binary_sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),
          'research_hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in research.iterdir() if f.suffix in {'.swift','.py'} or f.name in {'models.json','corpus.json','token-fixtures.json','PROTOCOL.md'}},
          'macos':platform.mac_ver()[0],'architecture':platform.machine(),'machine':output(['sysctl','-n','hw.model']),
          'memory_bytes':int(output(['sysctl','-n','hw.memsize'])),'cpu':output(['sysctl','-n','machdep.cpu.brand_string']),
          'xcode':output(['xcodebuild','-version']),'swift':output(['xcrun','swift','--version']),
          'runtime':'ONNX Runtime 1.24.2; Swift Transformers 1.3.5; CPU intra-op=2, batch=1, spin=0',
          'build':'Standalone Swift default -Onone, linked pinned Debug SwiftPM objects; no app linkage',
          'network_profile':'(version 1)(allow default)(deny network*)','disk_cache_reset':False,
          'order':order,'runs':commands}
(a.output/'environment.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
