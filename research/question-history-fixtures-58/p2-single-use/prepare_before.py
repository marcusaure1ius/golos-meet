#!/usr/bin/env python3
"""Run the same nested regression against the frozen pre-P2 helper in a temp copy."""
import argparse,hashlib,io,json,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert str(a.output).startswith('/private/tmp/') and not a.output.exists()
a.output.mkdir();ref='5446d7dfaff87f8cd97256340960b20dc293a874'
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',ref]))) as archive:archive.extractall(a.output,filter='data')
source=Path('golos-meetTests/SQLiteFaultExpectationTests.swift');target=a.output/'golos-meetTests/SQLiteFaultExpectationTests.swift';target.write_bytes(source.read_bytes())
(a.output/'p2-before-receipt.json').write_text(json.dumps(dict(ref=ref,test_source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),helper_sha256=hashlib.sha256((a.output/'golos-meetTests/SQLiteFixtureScope.swift').read_bytes()).hexdigest()),indent=2)+'\n')
