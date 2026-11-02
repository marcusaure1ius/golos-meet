#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json
p=argparse.ArgumentParser();p.add_argument('copy',type=Path);a=p.parse_args();assert str(a.copy).startswith('/private/tmp/')
receipt=json.loads((a.copy/'control-receipt.json').read_text());probe=(Path(__file__).parent/'IndexHeldBeforeProbe.swift.txt').read_text()
if receipt['retain_roots_control']:probe=probe.replace('try? FileManager.default.removeItem(at: root)','SearchIndexObservation.current?.note("control-root-retained", ["root":root.lastPathComponent])').replace('"root-removed"','"control-root-not-removed"')
f=a.copy/'golos-meetTests/LocalIndexingServiceTests.swift';old=f.read_bytes();assert b'IndexBeforeProbeState' not in old;f.write_bytes(old+probe.encode())
(a.copy/'index-probe-receipt.json').write_text(json.dumps(dict(source_before_sha256=hashlib.sha256(old).hexdigest(),probe_sha256=hashlib.sha256(probe.encode()).hexdigest(),source_after_sha256=hashlib.sha256(f.read_bytes()).hexdigest()),indent=2)+'\n')
