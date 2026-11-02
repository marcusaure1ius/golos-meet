#!/usr/bin/env python3
"""Archive finished P2 checks without rerunning tests or normalizing raw bytes."""
from pathlib import Path
import collections, gzip, hashlib, json, re, shutil, tarfile
ROOT = Path(__file__).parent / 'results' / 'p2-ack'
ROOT.mkdir(exist_ok=True)
def sha(data): return hashlib.sha256(data).hexdigest()
def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
def archive(source, target):
    files = sorted(p for p in source.rglob('*') if p.is_file())
    members = {str(p.relative_to(source)): {'sha256': sha(p.read_bytes()), 'bytes': p.stat().st_size} for p in files}
    with tarfile.open(target, 'w:gz') as out:
        for p in files: out.add(p, arcname=str(p.relative_to(source)), recursive=False)
    with tarfile.open(target) as saved:
        for member in saved.getmembers():
            data = saved.extractfile(member).read()
            assert sha(data) == members[member.name]['sha256']
    return members
checks = {}
selected = ('concreteMetadataBridgeReceives', 'pausedStartupSeparates', 'releasingSoleOwner',
            'strongOwnerAndGate', 'overflowPreservesNative', 'oldConfigurationReceipt')
for kind, prefix in [('before', '/tmp/golos61-p2-before-native'), ('targeted', '/tmp/golos61-p2-targeted'), ('full', '/tmp/golos61-p2-final')]:
    folder = ROOT / kind; folder.mkdir(exist_ok=True)
    summary = Path('/tmp/golos61-p2-before-summary.json' if kind == 'before' else prefix + '-summary.json')
    value = json.loads(summary.read_text()); shutil.copy2(summary, folder / 'summary.json')
    checks[kind] = {k: value[k] for k in ('result', 'totalTestCount', 'passedTests', 'failedTests', 'expectedFailures', 'skippedTests', 'runtimeWarnings', 'testFailures')}
    devices = value.get('devicesAndConfigurations', [])
    checks[kind]['runs'] = {k: sum(d[k] for d in devices) for k in ('passedTests', 'failedTests', 'expectedFailures', 'skippedTests')}
    if not devices: checks[kind]['runs'] = {k: value[k] for k in ('passedTests', 'failedTests', 'expectedFailures', 'skippedTests')}
    raw_logs = {}; members = {}
    data = Path(prefix + '.log').read_bytes()
    (folder / 'xcodebuild.log.gz').write_bytes(gzip.compress(data, mtime=0)); raw_logs['xcodebuild'] = {'sha256': sha(data), 'bytes': len(data)}
    stdout = b'\n'.join(p.read_bytes() for p in sorted(Path(prefix + '-diagnostics').rglob('StandardOutputAndStandardError.txt')))
    (folder / 'stdout.txt.gz').write_bytes(gzip.compress(stdout, mtime=0)); raw_logs['stdout'] = {'sha256': sha(stdout), 'bytes': len(stdout)}
    scopes = Path(prefix + '-scopes'); bridge = Path(prefix + '-bridge')
    for label in ('scopes', 'bridge', 'attachments', 'migration'):
        source = Path(prefix + '-' + label)
        if source.is_dir(): members[label] = archive(source, folder / (label + '.tar.gz'))
    raw_traces = {p.name: p.read_bytes() for p in scopes.glob('*.json')}
    bridge_traces = {p.name: p.read_bytes() for p in bridge.glob('*.json')}
    attachment_matches = []
    manifest = json.loads(Path(prefix + '-attachments/manifest.json').read_text())
    for test in manifest:
        for item in test['attachments']:
            name = item['suggestedHumanReadableName']; match = re.match(r'sqlite-fixture-([0-9A-F-]{36})_', name)
            bridge_match = re.match(r'(bridge61-[0-9A-F-]{36}-(?:timeline|failure))_', name)
            raw = raw_traces.get(match[1] + '.json') if match else bridge_traces.get(bridge_match[1] + '.json') if bridge_match else None
            if raw is not None:
                exported = Path(prefix + '-attachments') / item['exportedFileName']
                assert exported.read_bytes() == raw
                attachment_matches.append({'test': test['testIdentifier'], 'name': name, 'sha256': sha(raw)})
    assert len(attachment_matches) == len(raw_traces) + len(bridge_traces)
    ocr = []
    inputs, outputs = {}, {}
    for test in manifest:
        for item in test['attachments']:
            match = re.match(r'ocr-([0-9A-F-]{36})-(input|result)_', item['suggestedHumanReadableName'])
            if match:
                (inputs if match[2] == 'input' else outputs)[match[1]] = (test['testIdentifier'], Path(prefix + '-attachments') / item['exportedFileName'])
    assert inputs.keys() == outputs.keys()
    for identity, (test, path) in inputs.items():
        data = path.read_bytes(); result = json.loads(outputs[identity][1].read_text())
        assert result['inputSHA256'] == sha(data) and result['inputBytes'] == len(data)
        ocr.append({'invocation': identity, 'test': test, 'input_sha256': sha(data), 'input_bytes': len(data), 'result': result})
    write(folder / 'ocr-audit.json', ocr)
    lifecycle = []
    for name, raw in raw_traces.items():
        rows = json.loads(raw); test = rows[0].get('test', '')
        if not any(test.startswith(s) for s in selected) and kind != 'before': continue
        live = set(); counts = collections.Counter(); errors = []
        for row in rows:
            stage = row['stage']; counts[stage] += 1
            if stage == 'opened': live.add(row['connection'])
            if stage == 'closed':
                if row['result'] != '0': errors.append(row)
                live.discard(row['connection'])
            if stage == 'root-removed' and (live or row.get('exists') != 'false'): errors.append(row)
            if stage in ('scope-error', 'sqlite-failure', 'close-refused-live-leases'): errors.append(row)
        assert not live and not errors, (kind, test, errors, live)
        lifecycle.append({'file': name, 'test': test, 'counts': dict(counts), 'errors': errors})
    failures = []
    for name, raw in bridge_traces.items():
        x = json.loads(raw)
        if name.endswith('-failure.json'):
            failures.append({k: x[k] for k in ('scenario', 'phase', 'elapsed', 'beforeUnwind', 'atomic', 'timelineDropped', 'reads')})
    text = stdout.decode(errors='replace')
    audit = {'raw_logs': raw_logs, 'attachment_matches': attachment_matches, 'selected_native_lifecycle': lifecycle,
             'failure_captures': failures, 'remaining_stdout': {'sqlite_failure_lines': sum('SQLite failure' in l for l in text.splitlines()), 'unlink_warning_lines': sum('vnode unlinked' in l for l in text.splitlines()), 'e5rt_lines': sum('e5rt' in l for l in text.splitlines())}}
    write(folder / 'audit.json', audit); write(folder / 'archive-members.json', members)
    tests = Path(prefix + '-tests.json')
    if tests.exists(): (folder / 'tests.json.gz').write_bytes(gzip.compress(tests.read_bytes(), mtime=0))
shutil.copy2('/tmp/golos61-p2-before-probe.swift', ROOT / 'before' / 'NativeOverflowProbe.swift.txt')
(ROOT / 'before' / 'sandbox-package-resolution.log.gz').write_bytes(gzip.compress(Path('/tmp/golos61-p2-before.log').read_bytes(), mtime=0))
checks.update({'tested_source_commit': '0901a1b8a1400233897f2f6b4bc1f19d6057a584', 'accepted_base': 'ec77fea89c480eb1d0db7a5cbc2a1ff452d5bc46', 'checked64': '3561d0cbd81a9a48284274d746b5e1541128d53d', 'merge_commit': 'b21e2d0', 'full_space': json.loads(Path('/tmp/golos61-p2-final-run.json').read_text()), 'before_source': 'c4678c3c396d0d942aa5d4a0b9e6f2b2ace6f524 plus saved native probe', 'targeted_source': 'post-ec77fea ACK implementation, before final publication run/attempt evidence scoping; final scoping is covered by full', 'preserved_full_bundle': '/tmp/golos61-p2-final-preserved.xcresult', 'limitations': 'Only the bounded timeline ACK P2 is fixed. Both actual coverage timeouts still have timelineDropped=0. No historical root cause, production workaround, timeout extension or repeat full.'})
checks['source_sha256'] = {name: sha(Path(name).read_bytes()) for name in (
    'golos-meetTests/MemoryBridgeTestSession.swift', 'golos-meetTests/MemoryBridgeDiagnosticsTests.swift',
    'golos-meetTests/MemoryBridgeOverflowTests.swift', 'golos-meetTests/ProjectMemoryQueueTests.swift',
    'golos-meetTests/SQLiteFixtureScope.swift')}
write(ROOT / 'checks.json', checks)
write(ROOT / 'artifact-sha256.json', {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name != 'artifact-sha256.json'})
print(json.dumps({k: {'result':v['result'], 'tests':v['totalTestCount'], 'runs':v['runs']} for k,v in checks.items() if k in ('before','targeted','full')}, indent=2))
