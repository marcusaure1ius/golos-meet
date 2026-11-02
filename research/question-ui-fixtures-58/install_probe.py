#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json
p=argparse.ArgumentParser();p.add_argument('copy',type=Path);a=p.parse_args();assert str(a.copy).startswith('/private/tmp/')
f=a.copy/'golos-meetTests/KnowledgeQuestionModelTests.swift';old=f.read_bytes();probe=(Path(__file__).parent/'HeldBeforeProbe.swift.txt').read_bytes()
assert b'QuestionUIHeldBeforeProbe' not in old
f.write_bytes(old+probe)
(a.copy/'probe-receipt.json').write_text(json.dumps(dict(source_before_sha256=hashlib.sha256(old).hexdigest(),probe_sha256=hashlib.sha256(probe).hexdigest(),source_after_sha256=hashlib.sha256(f.read_bytes()).hexdigest()),indent=2)+'\n')
