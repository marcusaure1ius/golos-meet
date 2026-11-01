"""Generate a real v6 fixture using frozen accepted code, never downgrade v7.

Requires local package build outputs. Does not launch app, use real materials,
read Keychain, run ASR/cloud or download model weights. Ref is pinned below.
"""
from pathlib import Path
import hashlib,json,subprocess,tempfile

repo = Path(__file__).resolve().parents[2]
ref = '8efd4be56d77a34184e4955f54373bac2f7a8f64'
out = Path(__file__).resolve().parent / 'v6-fixture'
if out.exists():
    raise SystemExit('Refusing to overwrite a committed fixture')
build = repo / '.build/xcode'
products = build / 'Build/Products/Debug'
if not (products/'Tokenizers.o').exists():
    raise SystemExit('Run make build first; only existing local build outputs are used')
work = Path(tempfile.mkdtemp(prefix='golos-memory-v6-',dir='/tmp'))
paths = subprocess.check_output(['git','ls-tree','-r','--name-only',ref,'golos-meet/Core/Knowledge'],cwd=repo,text=True).splitlines()
paths = [p for p in paths if p.endswith('.swift')] + ['golos-meet/Core/Insights/ChatCompleter.swift']
sources=[]; hashes={}
for relative in paths:
    data = subprocess.check_output(['git','show',ref+':'+relative],cwd=repo)
    target=work/Path(relative).name;target.write_bytes(data);sources.append(target)
    hashes[relative]=hashlib.sha256(data).hexdigest()
command=['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',
 '-module-cache-path',str(work/'module-cache'),'-target','arm64-apple-macos14.4','-I',str(products),'-F',str(products),
 '-Xcc','-fmodule-map-file='+str(build/'Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap'),
 '-Xcc','-fmodule-map-file='+str(build/'Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap'),
 '-Xcc','-I'+str(build/'SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers'),
 *map(str,sources),str(Path(__file__).with_name('SeedV6.swift')),*map(str,products.glob('*.o')),
 '-framework','onnxruntime','-lc++','-Xlinker','-rpath','-Xlinker',str(products),'-o',str(work/'seed-v6')]
with (work/'build.log').open('w') as log:
    subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(work/'seed-v6'),str(out)],check=True)
manifest={'accepted_ref':ref,'actual_previous_schema':6,'downgraded_new_schema':False,'sources':hashes,
          'seed_sha256':hashlib.sha256(Path(__file__).with_name('SeedV6.swift').read_bytes()).hexdigest(),
          'files':{str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file()}}
(out.parent/'v6-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(out)
print('Build log:',work/'build.log')
