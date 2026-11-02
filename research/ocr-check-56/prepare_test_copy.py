#!/usr/bin/env python3
from pathlib import Path
import argparse,subprocess,tarfile,io,hashlib,json
from instrumentation import patches,instrument
p=argparse.ArgumentParser();p.add_argument('--ref',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False)
blob=subprocess.check_output(['git','archive',a.ref])
with tarfile.open(fileobj=io.BytesIO(blob)) as t:t.extractall(a.output,filter='data')
path=a.output/'golos-meet/Core/Knowledge/LocalDocumentExtractor.swift'
source=path.read_text();patched=instrument(source);path.write_text(patched)
trace=Path(__file__).with_name('Probe.swift').read_text().split('@main struct OCRProbe {')[0]
(a.output/'golos-meet/Util/OCRDiagnostics56.swift').write_text(trace)
manifest={'ref':a.ref,'source_sha256':hashlib.sha256(source.encode()).hexdigest(),'patched_sha256':hashlib.sha256(patched.encode()).hexdigest(),'trace_sha256':hashlib.sha256(trace.encode()).hexdigest(),'patches':patches,'production_branch_modified':False}
(a.output/'diagnostic-copy.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
