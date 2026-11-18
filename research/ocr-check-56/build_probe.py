#!/usr/bin/env python3
"""Build only a research copy of a selected ref, with explicit trace insertions."""
from pathlib import Path
import argparse, subprocess, hashlib, json
p=argparse.ArgumentParser();p.add_argument('--ref',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--queue-executor',action='store_true');args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
paths=['golos-meet/Core/Knowledge/LocalDocumentExtractor.swift','golos-meet/Core/Knowledge/KnowledgeModels.swift','golos-meetTests/LocalDocumentExtractorTests.swift']
sources={name:subprocess.check_output(['git','show',f'{args.ref}:{name}']).decode() for name in paths}
s=sources[paths[0]]
from instrumentation import patches, instrument
s=instrument(s)
if args.queue_executor:
 executor=Path(__file__).with_name('QueueExecutor.swift.txt').read_text()
 s=s.replace('actor LocalDocumentExtractor {',executor+'actor LocalDocumentExtractor {\n    private nonisolated let extractionExecutor = DocumentExtractionExecutor()\n    nonisolated var unownedExecutor: UnownedSerialExecutor { extractionExecutor.asUnownedSerialExecutor() }')
(args.output/'Extractor.swift').write_text(s)
(args.output/'Models.swift').write_text(sources[paths[1]])
tests=sources[paths[2]]
sections=[('png(_ text: String, _ url: URL)', '            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600', '            let result = '),
('mixed(_ native: String, _ scanned: String, _ duplicateNative: Bool, _ url: URL)', '            let decision = scanned', '            let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))'),
('nativePDF(_ url: URL)', '            let data = NSMutableData()', '            let result = ')]
methods=[]
for signature,start,end in sections:
 begin=tests.index(start);finish=tests.index(end,begin)
 code=tests[begin:finish].replace('try #require(', 'try require(')
 methods.append('    @MainActor static func '+signature+' throws {\n'+code+'    }')
helper='import Foundation\nimport AppKit\nimport PDFKit\nextension OCRProbe {\n'+'\n'.join(methods)+'\n}\n'
(args.output/'Fixtures.swift').write_text(helper)
probe_source=Path(__file__).with_name('Probe.swift')
probe=args.output/'Probe.swift'
probe.write_text(probe_source.read_text())
cmd=['swiftc','-target','arm64-apple-macos14.4','-O','-parse-as-library','-o',str(args.output/'ocr-probe'),str(args.output/'Extractor.swift'),str(args.output/'Models.swift'),str(args.output/'Fixtures.swift'),str(probe),str(Path(__file__).with_name('ProbeExecutor.swift'))]
subprocess.run(cmd,check=True)
manifest={'ref':args.ref,'queue_executor_control':args.queue_executor,'sources':{n:hashlib.sha256(c.encode()).hexdigest() for n,c in sources.items()},'trace_patches':patches,'instrumented_extractor_sha256':hashlib.sha256(s.encode()).hexdigest(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),'fixture_helper_sha256':hashlib.sha256(helper.encode()).hexdigest(),'command':cmd}
(args.output/'build.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest['sources'],indent=2))
