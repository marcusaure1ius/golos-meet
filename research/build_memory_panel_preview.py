"""Build-only isolated panel hosts. Never launch an app or download models.

Normal preview retains its existing weights/reuse defaults. --gate-diagnostics
selects a separate fresh self-recording host, no weights/inference/seed reuse.
"""
import argparse
from pathlib import Path
import hashlib,json,plistlib,shutil,subprocess,tempfile,uuid

parser = argparse.ArgumentParser()
parser.add_argument('--weights', type=Path)
parser.add_argument('--derived-data', type=Path)
parser.add_argument('--resume-library', action='store_true', help='Keep this stopped task-owned preview library')
parser.add_argument('--reuse-root', type=Path, help='Rebuild the same stopped task-owned preview')
parser.add_argument('--gate-diagnostics', action='store_true', help='Build a fresh unlaunched one-case diagnostic host')
parser.add_argument('--gate-root', type=Path, help='New unique diagnostic output root under the actual macOS temp directory')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
derived = (args.derived_data or repo / '.build/xcode').resolve()
products = derived / 'Build/Products/Debug'
if not (products / 'Tokenizers.o').exists():
    parser.error('Completed package build products are required; this builder never runs make/build')
if args.gate_root and not args.gate_diagnostics:
    parser.error('--gate-root requires --gate-diagnostics')
weights = None
if args.gate_diagnostics:
    if args.weights or args.reuse_root or args.resume_library:
        parser.error('Diagnostic host forbids weights, reuse and completed-library reset')
    temporary = Path(tempfile.gettempdir()).resolve()
    qa = (args.gate_root or temporary / ('golos-memory-gate37-' + uuid.uuid4().hex)).absolute().resolve()
    if not str(temporary).startswith('/private/var/folders/') or temporary.name != 'T' or qa.parent != temporary or not qa.name.startswith('golos-memory-gate37-') or qa.exists():
        parser.error('Diagnostic output must be a NEW unique root directly below /private/var/folders/.../T')
    qa.mkdir()
    app_name, executable = 'Golos Memory Gate Diagnostics', 'MemoryPanelGateDiagnostics'
    bundle = 'com.golos.memory-gate37.' + uuid.uuid4().hex
    synthetic_root = qa / 'library'
else:
    if args.weights is None or not args.weights.resolve().is_dir():
        parser.error('Explicit installed weights folder is required for normal preview')
    weights = args.weights.resolve()
    qa = args.reuse_root.absolute() if args.reuse_root else Path(tempfile.mkdtemp(prefix='golos-memory-panel-preview37-'))
    if args.reuse_root:
        if not qa.name.startswith('golos-memory-panel-preview37-') or not qa.resolve().is_relative_to(Path(tempfile.gettempdir()).resolve()):
            parser.error('Reuse is restricted to this task-owned temporary host')
        old = plistlib.loads((qa / 'Golos Memory Panel Preview.app/Contents/Info.plist').read_bytes())
        if not old['CFBundleIdentifier'].startswith('com.golos.memory-panel-preview37.'):
            parser.error('Unexpected host bundle')
    app_name, executable = 'Golos Memory Panel Preview', 'MemoryPanelPreview'
    bundle = old['CFBundleIdentifier'] if args.reuse_root else 'com.golos.memory-panel-preview37.' + uuid.uuid4().hex
    if args.resume_library and not args.reuse_root:
        parser.error('--resume-library requires a stopped task-owned --reuse-root')
    synthetic_root = Path(old['SyntheticRoot']) if args.resume_library else qa / ('library-' + uuid.uuid4().hex) if args.reuse_root else qa / 'library'
    if args.resume_library and (not synthetic_root.resolve().is_relative_to(qa.resolve()) or not (synthetic_root / 'knowledge.sqlite').is_file()):
        parser.error('Resume is restricted to the existing task-owned synthetic library')
app = qa / (app_name + '.app') / 'Contents'
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
sources = sorted((repo / 'golos-meet/Core/Knowledge').glob('*.swift'))
sources += [repo / 'golos-meet/Core/Insights/ChatCompleter.swift']
sources += [repo / 'golos-meet' / p for p in ['Util/AppRuntime.swift', 'UI/DesignSystem/Palette.swift', 'UI/DesignSystem/Components.swift']]
sources += [repo / 'golos-meet/UI/Projects' / (p + '.swift') for p in ['ProjectLibrary', 'KnowledgeIndexing', 'KnowledgeSearchModel',
    'KnowledgeSearchScreen', 'KnowledgeSourceView', 'KnowledgeQuestionModel', 'KnowledgeQuestionScreen', 'ProjectCloudSettings', 'ProjectMemoryPanelModel', 'ProjectMemoryPanel', 'ProjectMemoryNavigation', 'ProjectMemoryEntry']]
sources += [repo / 'research' / ('MemoryPanelGateDiagnostics.swift' if args.gate_diagnostics else 'MemoryPanelPreview.swift')]
for name in ['OpenRouterClient.swift','Keychain.swift','golos_meetApp.swift','ProductionMemoryPanel.swift','AppDelegate.swift','Recorder.swift','LocalASR.swift']:
    assert all(p.name != name for p in sources)
manifest = {'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
            'files':{str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
            'mode':'gate-diagnostics-build-only' if args.gate_diagnostics else 'normal-preview-build-only'}
manifest_bytes = (json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode()
(qa / 'source-manifest.json').write_bytes(manifest_bytes)
(qa / 'source-allowlist.txt').write_text('\n'.join(map(str,sources))+'\n')
info = {'CFBundleExecutable':executable,'CFBundleIdentifier':bundle,'CFBundleName':app_name,'NSHighResolutionCapable':True,
        'SyntheticRoot':str(synthetic_root),'SourceCommit':manifest['sourceCommit'],'SourceManifestSHA256':hashlib.sha256(manifest_bytes).hexdigest()}
if weights: info['PublicWeightsFolder'] = str(weights)
with (app / 'Info.plist').open('wb') as out: plistlib.dump(info,out)
if args.gate_diagnostics:
    (qa / 'READ-BEFORE-ONE-AUTHORIZED-RUN.txt').write_text('''Этот build НЕ разрешает запуск. Сначала независимое exact-SHA review и отдельное решение root.
После разрешённого запуска: одна fresh library, один consent и один physical held call.
1. Открыть Память, Подготовить контроль удержания; дождаться token ACK.
2. Очередь → Просмотреть контекст. Спокойно прочитать весь context, затем один раз Разрешить.
3. Дождаться видимого physical-held ACK + сохранённого first running; выбрать Приватный в actual Picker.
4. Не нажимать Release: coordinator делает это только после durable early cancel END<20s.
5. После physical return/history0/calls1: К проекту → Память → Очередь → Retry при необходимости → новый preview.
Второго согласия не давать. После send весь actual case ограничен45s, подготовка5мин.
Любой timeout/read/write/overflow/identity gap — INCONCLUSIVE. Cleanup не означает proof.
Не очищать и не переиспользовать библиотеку. Не запускать обычное приложение, OCR, сеть, ASR.
''')
command = ['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',
           '-module-cache-path',str(qa/'module-cache'),'-target','arm64-apple-macos14.4','-I',str(products),'-F',str(products),
           '-Xcc','-fmodule-map-file='+str(derived/'Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap'),
           '-Xcc','-fmodule-map-file='+str(derived/'Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap'),
           '-Xcc','-I'+str(derived/'SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers'),
           *map(str,sources),*map(str,products.glob('*.o')),'-framework','onnxruntime','-lc++','-Xlinker','-rpath','-Xlinker',str(products),'-o',str(app/'MacOS'/executable)]
(qa/'compile-command.json').write_text(json.dumps(command,indent=2)+'\n')
with (qa/'build.log').open('w') as log: result = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
if result.returncode: parser.exit(result.returncode,'Build failed: '+str(qa/'build.log')+'\n')
for resource in products.glob('*.bundle'): shutil.copytree(resource,app/'Resources'/resource.name,dirs_exist_ok=True)
if args.gate_diagnostics:
    # Seal only the finished NEW diagnostic bundle. Never sign linked products.
    bundle_root = app.parent.resolve()
    binary = app/'MacOS'/executable
    signature = {'scope':str(bundle_root),'commands':[],
                 'binary_sha256_before_sign':hashlib.sha256(binary.read_bytes()).hexdigest(),
                 'status':'INCOMPLETE','host_launched':False,
                 'comparison':'Whole-file before/after hashes only; no executable-section equivalence claim'}
    try:
        assert bundle_root.parent == qa and not synthetic_root.exists()
        members = list(bundle_root.rglob('*'))
        for member in members:
            assert not member.is_symlink() and member.resolve().is_relative_to(bundle_root), 'Signing refuses symlink/outside member'
        magic = {b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'}
        nested_code = []
        for member in members:
            if member.is_file() and member != binary:
                with member.open('rb') as inp: header = inp.read(4)
                if header in magic: nested_code.append(member)
        containers = [p for p in members if p.is_dir() and p.suffix in {'.bundle','.app','.framework','.xpc','.appex'}]
        targets = sorted(nested_code,key=lambda p:len(p.parts),reverse=True) + sorted(containers,key=lambda p:len(p.parts),reverse=True) + [bundle_root]
        for target in targets:
            assert target.resolve().is_relative_to(bundle_root)
            command = ['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(target)]
            signed = subprocess.run(command,capture_output=True,text=True)
            signature['commands'].append({'kind':'sign','command':command,'exit_code':signed.returncode,'stdout':signed.stdout,'stderr':signed.stderr})
            if signed.returncode: parser.exit(signed.returncode,'Diagnostic signing failed\n')
        command = ['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(bundle_root)]
        verified = subprocess.run(command,capture_output=True,text=True)
        signature['commands'].append({'kind':'verify','command':command,'exit_code':verified.returncode,'stdout':verified.stdout,'stderr':verified.stderr})
        if verified.returncode: parser.exit(verified.returncode,'Diagnostic strict signature verification failed\n')
        signature['binary_sha256_after_sign'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        signature['status'] = 'Signed own completed diagnostic bundle; strict verify Passed; NOT launched'
    finally:
        (qa/'signature-receipt.json').write_text(json.dumps(signature,indent=2)+'\n')
print('APP='+str(app.parent));print('BUNDLE='+bundle);print('ROOT='+str(synthetic_root));print('BUILD_LOG='+str(qa/'build.log'));print('SOURCE_ALLOWLIST='+str(qa/'source-allowlist.txt'))
