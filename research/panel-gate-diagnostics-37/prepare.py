#!/usr/bin/env python3
"""Static provenance/ordering/allowlist assessment. No compiler or host execution."""
from pathlib import Path
import ast,datetime,hashlib,json,subprocess
r=Path(__file__).parent/'results';r.mkdir(exist_ok=True)
base='24b49b067fcda107e397ed4f2461f9bb23de322f';accepted='23b1da158304a2c0c596752d9150e489b1884fb4'
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
def sha(b):return hashlib.sha256(b).hexdigest()
for ref in (base,accepted):subprocess.run(['git','merge-base','--is-ancestor',ref,'HEAD'],check=True)
protected=git('ls-files','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile').splitlines()
source={p:sha(Path(p).read_bytes()) for p in protected if Path(p).is_file()}
for p,h in source.items():assert sha(subprocess.check_output(['git','show',base+':'+p]))==h,p
assert not git('diff',base,'--','golos-meet','golos-meetTests','asr','golos-meet.xcodeproj','Makefile')
allowed=['research/MemoryPanelGateDiagnostics.swift','research/build_memory_panel_preview.py','research/panel-gate-diagnostics-37/']
for p in git('diff','--name-only',base).splitlines():assert any(p==a or a.endswith('/') and p.startswith(a) for a in allowed),p
plan=Path(__file__).parent/'SELF_RECORDING_GATE_PLAN.md';assert sha(plan.read_bytes())=='ddeee469bd5ce06b0fc0f02b0a55083ea6f00ed2f358c3ec148f8161bbae64ed'
model=Path('golos-meet/UI/Projects/ProjectMemoryPanelModel.swift').read_text();send=model.split('    func send() {')[1].split('    func cancelAction')[0]
assert send.index('busy = true')<send.index('request = nil')<send.index('operation = Task')<send.index('worker.approvePreview')
worker=Path('golos-meet/Core/Knowledge/ProjectMemoryQueueWorker.swift').read_text();approve=worker.split('    func approvePreview')[1].split('    /// Closing')[0]
assert approve.index('service.approve')<approve.index('store.resumeMemoryQueueConsent')<approve.index('await process')
process=worker.split('    private func process(')[1].split('    private func failureState')[0];assert process.index('let task = Task')<process.index('active = (lease,service,task)')<process.index('let timer = Task')
store=Path('golos-meet/Core/Knowledge/MemoryQueueStore.swift').read_text();resume=store.split('    func resumeMemoryQueueConsent')[1].split('\n    }')[0]
assert 'memoryTransaction' in resume and "SET state='running'" in resume
host=Path('research/MemoryPanelGateDiagnostics.swift').read_text();ast.parse(Path('research/build_memory_panel_preview.py').read_text())
for marker in ['SQLITE_OPEN_READONLY','before.sameIdentity(as:now)','previous.ended <= sendMarker','sample.ended-anchor.began < 20','actor-arm-ACK','physical-held-waiter-registered-ACK','early-cancel-saved','fresh-preview-approval-idle-receipt','weak var model','[weak self]','appearedEntries','cleanup-only-begin','withoutOverwriting','diagnostic-overflow','final-pending-']:
 assert marker in host,marker
assert 'PanelPreviewState' not in host and 'setCloudPolicy(.all' not in host and 'model.projectID =' not in host
result=dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),base=base,accepted=accepted,head=git('rev-parse','HEAD'),plan_sha256=sha(plan.read_bytes()),protected_source_sha256=source,diagnostic_sha256=sha(host.encode()),builder_sha256=sha(Path('research/build_memory_panel_preview.py').read_bytes()),production_test_rust_makefile_byte_unchanged=True,compiler_executed=False,host_launched=False,actual_case_executed=False,ordering=['Published request=nil with busy=true saved synchronously before operationTask','approve then resumeMemoryQueueConsent transaction COMMIT before process/timer creation','fresh complete needsConsent sample frozen at observed send state; budget uses its READ BEGIN','first running same attempt/generation/input/cycle and actual held waiter ACK before switch instruction','cancelled READ END<20 then flushed proof before diagnostic release','physical return + old weak model nil + fresh canApprovePreview true; never waitUntilIdle alone'],published_reference='https://developer.apple.com/documentation/combine/published?changes=la__7_1_3',published_semantics='Apple documents willSet publication. Direct sink, no receive(on)/Task, uses emitted request and project value; model.busy was stored earlier in send. Initial project emission ignored. SQL conservative anchor remains independent of fake call time.',limits=['No runtime claim: one build still pending','Captures are atomic only inside one readonly SQL transaction, not across source/UI/actor reads','Callbacks/read polling/log sync can perturb scheduling; no historical root cause claim','No normal singleton composition or width-extrema claim'])
(r/'static-assessment.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('Static assessment Passed; protected tree byte-equal24b; no compiler/host/case executed')
