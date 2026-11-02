#!/usr/bin/env python3
"""Assess both confirmed fixes without a compiler, signing or runtime call."""
from pathlib import Path
import ast, datetime, gzip, hashlib, json, subprocess, sys

folder = Path(__file__).parent
old = '049ff242643240a8bd57006fa1b1ad8ee240fb1b'
startup = 'f152e7daad646e53d8269646db6bea4954d86954'
base = '24b49b067fcda107e397ed4f2461f9bb23de322f'
prefix = 'research/panel-gate-diagnostics-37/'
builder = 'research/build_memory_panel_preview.py'
host = 'research/MemoryPanelGateDiagnostics.swift'
def git(*args): return subprocess.check_output(['git',*args])
def sha(data): return hashlib.sha256(data).hexdigest()
for ref in [base,old,startup]:
    subprocess.run(['git','merge-base','--is-ancestor',ref,'HEAD'],check=True)
allowed = [builder,prefix+'README.md',prefix+'final-fix/']
for name in (git('diff','--name-only',startup).decode().splitlines()+git('ls-files','--others','--exclude-standard').decode().splitlines()):
    assert any(name==p or p.endswith('/') and name.startswith(p) for p in allowed),name
protected = json.loads(gzip.decompress(Path(prefix+'results/static-assessment.json.gz').read_bytes()))['protected_source_sha256']
for name,digest in protected.items():
    assert sha(Path(name).read_bytes())==digest==sha(git('show',base+':'+name)),name
assert Path(host).read_bytes()==git('show',startup+':'+host)
assert sha(Path(host).read_bytes())==json.loads(Path(prefix+'p2-initial-attempt/static-assessment.json').read_text())['diagnostic_source_sha256']
preserved = {}
for name in git('ls-tree','-r','--name-only',startup,prefix).decode().splitlines():
    if name==prefix+'README.md': continue
    digest=sha(Path(name).read_bytes());assert digest==sha(git('show',startup+':'+name)),name
    preserved[name]=digest
before=ast.parse(git('show',startup+':'+builder).decode())
after=ast.parse(Path(builder).read_text())
# Removing just the final diagnostic-only block must restore the exact old AST.
blocks=[i for i,node in enumerate(after.body) if isinstance(node,ast.If) and ast.unparse(node.test)=='args.gate_diagnostics'
        and any(isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='bundle_root' for t in n.targets) for n in node.body)]
assert len(blocks)==1
after.body.pop(blocks[0])
assert ast.dump(before,include_attributes=False)==ast.dump(after,include_attributes=False),'Normal builder behavior changed'
text=Path(builder).read_text()
seal=text.index('# Seal only the finished NEW diagnostic bundle')
assert text.index('for resource in products.glob')<seal<text.index("'--force','--sign','-'")<text.index("'--verify','--deep','--strict'")<text.index("signature['binary_sha256_after_sign']")
assert 'target.resolve().is_relative_to(bundle_root)' in text and 'not member.is_symlink()' in text
for name in folder.glob('*.py'): ast.parse(name.read_text())
for name,digest in [('FINAL_STATIC_REVIEW.md','cf836f79f82144103c0085e9a109fee4fd3e2abc117c5c9d8d838d834d831fbb'),('static-review-receipt.json','4b959a86a76b89d9c42584b7900b9c67b1e169ec532f055bd05a1aa31351ba58')]:
    assert sha((folder/'review049ff'/name).read_bytes())==digest,name
old_receipt=json.loads(Path(prefix+'results/build-receipt.json').read_text())
old_root=Path(old_receipt['output_root']);assert not (old_root/'library').exists()
assert sha((old_root/'Golos Memory Gate Diagnostics.app/Contents/MacOS/MemoryPanelGateDiagnostics').read_bytes())=='3fe0e3b68bcbbd08c8f73e7f8a928994f73e2b6c04eddf62a328a148b0f4980c'
stable=dict(frozen_review_head=old,startup_fix_head=startup,production_base=base,
    source_sha256={p:sha(Path(p).read_bytes()) for p in [host,builder]},
    protected_source_count=len(protected),preserved_file_sha256=preserved,
    normal_builder_ast_equal_without_final_diagnostic_block=True,
    signing_scope='NEW completed own diagnostic bundle only; no external products/frameworks',
    signing_order='all sealed files complete -> nested own Mach-O -> nested own containers -> root bundle -> deep strict verify -> post-sign hashes',
    old_binary_unlaunched=True,compiler_executed=False,host_launched=False,actual_case_executed=False)
output=folder/'static-assessment.json'
if sys.argv[1:]==['--check']:
    saved=json.loads(output.read_text());assert {k:v for k,v in saved.items() if k!='utc'}==stable
else:
    assert not sys.argv[1:] and not output.exists()
    stable['utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    output.write_text(json.dumps(stable,ensure_ascii=False,indent=2)+'\n')
print('Both-fix static assessment Passed; normal builder AST preserved; no compiler/signing/launch executed.')
