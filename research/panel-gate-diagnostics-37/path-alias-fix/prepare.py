#!/usr/bin/env python3
"""Static scope/provenance assessment for the confirmed acfe path-only fix."""
from pathlib import Path
import ast,gzip,hashlib,json,subprocess,sys
folder=Path(__file__).parent;old='acfe44fb379a9ba8de3c0aa5de7fefb9c93bd28f'
base='24b49b067fcda107e397ed4f2461f9bb23de322f';prefix='research/panel-gate-diagnostics-37/'
sources=['research/MemoryPanelGateDiagnostics.swift','research/DiagnosticGatePaths.swift','research/build_memory_panel_preview.py']
def git(*args):return subprocess.check_output(['git',*args])
def sha(data):return hashlib.sha256(data).hexdigest()
subprocess.run(['git','merge-base','--is-ancestor',old,'HEAD'],check=True)
allowed=sources+[prefix+'README.md',prefix+'path-alias-fix/']
for p in git('diff','--name-only',old).decode().splitlines()+git('ls-files','--others','--exclude-standard').decode().splitlines():
    assert any(p==a or a.endswith('/') and p.startswith(a) for a in allowed),p
protected=json.loads(gzip.decompress(Path(prefix+'results/static-assessment.json.gz').read_bytes()))['protected_source_sha256']
for p,h in protected.items():assert sha(Path(p).read_bytes())==h==sha(git('show',base+':'+p)),p
preserved={}
for p in git('ls-tree','-r','--name-only',old,prefix).decode().splitlines():
    if p==prefix+'README.md':continue
    h=sha(Path(p).read_bytes());assert h==sha(git('show',old+':'+p)),p
    preserved[p]=h
before=ast.parse(git('show',old+':'+sources[2]).decode());after=ast.parse(Path(sources[2]).read_text())
blocks=[i for i,n in enumerate(after.body) if isinstance(n,ast.If) and ast.unparse(n.test)=='args.gate_diagnostics' and 'DiagnosticGatePaths.swift' in ast.unparse(n)]
assert len(blocks)==1;after.body.pop(blocks[0])
assert ast.dump(before,include_attributes=False)==ast.dump(after,include_attributes=False),'Builder changed beyond diagnostic helper allowlist'
helper=Path(sources[1]).read_text();assert helper.count('import Foundation')==1 and 'import ' not in helper.replace('import Foundation','')
for marker in ['.systemNumber','.systemFileNumber','.ownerAccountID','typeSymbolicLink','reusedLibrary','invalidOutputName','outsideTemporary','canonicalOutput.deletingLastPathComponent()','requireAbsent(library)']:
    assert marker in helper,marker
host=Path(sources[0]).read_text();start=host.split('    init() {',1)[1].split('    @discardableResult',1)[0]
assert start.index('installValidatedConfiguration()')<start.index('GateLog(folder:paths.library)')<start.index('await self?.setup()')
assert 'var evidencePath: String { AppPaths.displayPath }' in host and 'as! String' not in host
assert 'precondition(root.path.hasPrefix' not in host
for p in folder.glob('*.py'):ast.parse(p.read_text())
for p,h in [('FINAL_STARTUP_CRASH_REVIEW.md','715047f155aa2c5c3214660871b7b36db60d925acfda1b00c39ea970d3cd5450'),('startup-crash-review-receipt.json','39ab23c360e0876c5c31c33456e1233f56bb322069343f438e7265b285ebc023'),('foundation-stdout.txt','d716cff77797248c06eaf3f2b8d9d72d67e7ae20e95b801357067ebe0a0efb89')]:assert sha((folder/'review-acfe'/p).read_bytes())==h,p
stable=dict(reviewed_crash_head=old,production_base=base,source_sha256={p:sha(Path(p).read_bytes()) for p in sources},
    protected_source_count=len(protected),preserved_file_sha256=preserved,builder_only_adds_diagnostic_helper=True,
    typed_configuration_before_logger_and_database=True,display_path_does_not_require_installed_root=True,
    limits=['Static checks only; Foundation controls and one addressed build have separate receipts',
        'CLI path values are not captured LaunchServices environment',
        'AppPaths URL accessor retains an internal installed-root invariant; invalid configuration returns from coordinator init before any accessor/default singleton/DB',
        'Filesystem checks are bounded snapshots, not an atomic openat capability or concurrent-tampering proof'])
output=folder/'static-assessment.json'
if sys.argv[1:]==['--check']:assert json.loads(output.read_text())==stable
else:
    assert not sys.argv[1:] and not output.exists();output.write_text(json.dumps(stable,ensure_ascii=False,indent=2)+'\n')
print('Path-only static scope/provenance Passed; protected source unchanged; no runtime executed.')
