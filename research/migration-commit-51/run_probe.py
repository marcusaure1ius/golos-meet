#!/usr/bin/env python3
"""Repeat the native, real-lock VFS experiment; stop on any unexpected outcome."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--iterations', type=int, default=100)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
if not 1 <= args.iterations <= 1000:
    parser.error('iterations must be in 1..1000')
args.output_dir.mkdir(parents=True, exist_ok=True)
raw = args.output_dir / 'native-stress.jsonl'
groups = {(initialized, action): 0 for initialized in (0, 1) for action in ('commit', 'rollback')}
versions = set()
with raw.open('w') as output:
    for iteration in range(args.iterations):
        process = subprocess.run([str(args.binary.resolve())], text=True, capture_output=True, timeout=20, check=True)
        rows = [json.loads(line) for line in process.stdout.splitlines()]
        assert len(rows) == 4
        seen = set()
        for row in rows:
            key = row['initialized'], row['action']
            assert key in groups and key not in seen
            seen.add(key)
            commit = key[1] == 'commit'
            assert row['sqlite_begin_entries'] == 2 and row['native_shared_holder'] in (1, 2)
            assert row['native_shared_state'] == 1 and row['writer_lock_before'] == 2
            assert row['writer_lock_after'] == (3 if commit else 0)
            assert row['result'] == row['extended'] == (5 if commit else 0)
            assert row['cleanup'] == (0 if commit else -1) and row['close'] == 0
            for field in ('peer_begin', 'peer_commit', 'peer_close'):
                assert row[field] == [0, 0]
            groups[key] += 1
            versions.add(row['sqlite'])
            output.write(json.dumps({'iteration': iteration, **row}, sort_keys=True) + '\n')
summary = {
    'iterations': args.iterations, 'cases': sum(groups.values()), 'sqlite_versions': sorted(versions),
    'outcomes': [{'initialized': key[0], 'action': key[1], 'cases': count} for key, count in groups.items()],
    'probe_source_sha256': hashlib.sha256(Path(__file__).with_name('lock_probe.c').read_bytes()).hexdigest(),
    'raw_sha256': hashlib.sha256(raw.read_bytes()).hexdigest(), 'all_expected_outcomes': True,
}
(args.output_dir / 'native-stress-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
