#!/usr/bin/env python3
"""Static P2 delta assessment only; never compile, launch, seed or alter old evidence."""
from pathlib import Path
import ast, datetime, gzip, hashlib, json, subprocess, sys

folder = Path(__file__).parent
old = '049ff242643240a8bd57006fa1b1ad8ee240fb1b'
base = '24b49b067fcda107e397ed4f2461f9bb23de322f'
host_path = 'research/MemoryPanelGateDiagnostics.swift'
prefix = 'research/panel-gate-diagnostics-37/'

def git(*args):
    return subprocess.check_output(['git', *args])

def sha(data):
    return hashlib.sha256(data).hexdigest()

def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]

subprocess.run(['git', 'merge-base', '--is-ancestor', old, 'HEAD'], check=True)
allowed = [host_path, prefix+'README.md', prefix+'p2-initial-attempt/']
changed = git('diff', '--name-only', old).decode().splitlines()
untracked = git('ls-files', '--others', '--exclude-standard').decode().splitlines()
for name in changed + untracked:
    assert any(name == p or p.endswith('/') and name.startswith(p) for p in allowed), name

assessment = json.loads(gzip.decompress(Path(prefix+'results/static-assessment.json.gz').read_bytes()))
for name, digest in assessment['protected_source_sha256'].items():
    assert sha(Path(name).read_bytes()) == digest == sha(git('show', base+':'+name)), name

# Keep ALL historical diagnostic files except the revised host/README byte-identical.
historical = {}
for name in git('ls-tree', '-r', '--name-only', old, prefix, 'research/build_memory_panel_preview.py').decode().splitlines():
    if name == prefix+'README.md':
        continue
    digest = sha(Path(name).read_bytes())
    assert digest == sha(git('show', old+':'+name)), name
    historical[name] = digest
receipt = json.loads(Path(prefix+'results/build-receipt.json').read_text())
manifest = json.loads(Path(prefix+'results/source-manifest.json').read_text())
assert receipt['code_head'] == 'fcdd8837d3163bf9aba9274b0c66449e14a11940'
for name, digest in manifest['files'].items():
    assert sha(git('show', receipt['code_head']+':'+name)) == digest, name
qa = Path(receipt['output_root'])
assert not (qa/'library').exists(), 'Old diagnostic app unexpectedly launched'
binary = qa/'Golos Memory Gate Diagnostics.app/Contents/MacOS/MemoryPanelGateDiagnostics'
binary_hash = sha(binary.read_bytes())
assert binary_hash == '3fe0e3b68bcbbd08c8f73e7f8a928994f73e2b6c04eddf62a328a148b0f4980c'

host = Path(host_path).read_text()
setup = section(host, 'await worker.start(); await worker.waitUntilIdle()', 'func openRoute()')
assert setup.index('record("fresh-initial-baseline"') < setup.index('sample.job?.attemptIsNull == true') < setup.index('initialBaseline = sample') < setup.index('phase = .ready')
assert 'sample.job?.selectedIsNull == true' in setup
assert 'sample.job?.attempt.isEmpty == false' not in setup
assert 'attempt IS NULL,selected_key IS NULL' in host
prepared = section(host, 'func prepared(entry:', 'func requestCleared(')
assert '!value.selected.isEmpty' in prepared and 'value.source == "meeting:current"' in prepared
assert 'preparedReceipt = nil; latestNeedsConsent = nil' in prepared
marker = section(host, 'func requestCleared(', 'func projectPublished(')
assert marker.index('let preparedReceipt') < marker.index('previous.matches(fresh)') < marker.index('anchor = fresh')
assert 'fresh.began >= observed' in marker and 'GateClock.mono - fresh.began < 1' in marker
tick = section(host, 'private func tick()', 'if phase == .recordingRunning, heldAt')
assert tick.index('sample.began >= observed') < tick.index('prepared.matches(sample)') < tick.index('record("prepared-lease-receipt"') < tick.index('latestNeedsConsent = sample')
for text in ['before.sameIdentity(as:now)', 'before.generation == now.generation', 'initial.run == sample.run', 'before.selected == now.selected', 'route.flatMap({ observations[$0]?.read().request }) == prepared.request']:
    assert text in tick, text
for text in ['selected == job.selected', '!job.attempt.isEmpty', '!job.attemptIsNull', '!job.selectedIsNull', 'fileStamp == job.identity', 'MemoryFactExtractor.producerKey(model:"fake-only",payload:value.payload,hits:value.fragments,parents:value.parents)', 'before.attempt == now.attempt', 'previous.run == sample.run']:
    assert text in host, text
assert 'value.validation.' not in host and 'value.lease.' not in host
assert 'client:client,model:"fake-only"' in host

# Read actual production order. No synthetic SQL transition or runtime substitute.
store = Path('golos-meet/Core/Knowledge/MemoryQueueStore.swift').read_text()
insert = next(line for line in store.splitlines() if 'INSERT INTO memory_queue_work(' in line)
assert 'attempt' not in insert and 'selected_key' not in insert
worker = Path('golos-meet/Core/Knowledge/ProjectMemoryQueueWorker.swift').read_text()
preview = section(worker, 'func preparePreview(', 'func canApprovePreview(')
assert preview.index('store.claimMemoryQueue') < preview.index('await prepare(lease') < preview.index('store.pauseMemoryQueueForConsent') < preview.index('return request')
service = Path('golos-meet/Core/Knowledge/ProjectMemoryUpdateService.swift').read_text()
assert 'fileprivate let lease: MemoryLease' in service and 'fileprivate let validation: MemoryUpdateGuard' in service
prepare = section(service, 'func prepare(projectID:', 'func approve(')
assert prepare.index('store.bindMemoryQueueInput') < prepare.index('let request = MemoryUpdateRequest') < prepare.index('return request')
assert 'MemoryFactExtractor.producerKey(model: model, payload: payload, hits: hits, parents: provenance.parents)' in prepare
for name in [__file__, 'research/build_memory_panel_preview.py']:
    ast.parse(Path(name).read_text())

stable = dict(frozen_prepared_head=old, production_base=base,
    diagnostic_source_sha256=sha(host.encode()), assessment_script_sha256=sha(Path(__file__).read_bytes()),
    protected_source_file_count=len(assessment['protected_source_sha256']), historical_file_sha256=historical,
    old_binary_sha256=binary_hash, old_compiled_source_head=receipt['code_head'],
    compiled_manifest_sha256=sha(Path(prefix+'results/source-manifest.json').read_bytes()),
    source_order=['fresh needsConsent INSERT omits attempt/selected_key; initial SQL NULL baseline before UI',
        'explicit UI prepare: claim -> service bind selected key -> pause needsConsent -> return request',
        'published actual request -> separate readonly SQL READ BEGIN -> prepared lease receipt',
        'fresh matching prepared receipt/sample required before synchronous send marker/anchor',
        'first running preserves non-null attempt, selected key, identity, generation and run'],
    current_source_built=False, host_launched=False, actual_case_executed=False,
    protected_source_changed=False, old_receipts_changed=False,
    limits=['Static source/API assessment; no Swift typecheck/build or runtime proof',
        'Frozen049ff review remains on its own SHA; new delta requires independent review',
        'No new build until final049ff review and root assessment',
        'A click before a fresh prepared SQL receipt fails INCONCLUSIVE; no automatic consent or UI retry'])
output = folder/'static-assessment.json'
if sys.argv[1:] == ['--check']:
    saved = json.loads(output.read_text())
    assert {k:v for k,v in saved.items() if k != 'utc'} == stable
else:
    assert not sys.argv[1:] and not output.exists(), 'Do not overwrite saved assessment'
    stable['utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    output.write_text(json.dumps(stable, ensure_ascii=False, indent=2)+'\n')
print('P2 static delta assessment Passed; source UNBUILT; old build unlaunched; actual case NOT RUN.')
