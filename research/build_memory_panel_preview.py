"""Build-only isolated Memory Panel UI. Never launches production app or downloads weights.

Explicit source allowlist: local Knowledge, actual UI model/views, and fake
ChatCompleter. NO OpenRouterClient, Keychain, AppDelegate, Recorder or ASR.
Fresh bundle and temp SQLite every build; weights are an explicit existing path.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--weights', required=True, type=Path)
parser.add_argument('--derived-data', type=Path)
parser.add_argument('--reuse-root', type=Path, help='Rebuild the same stopped task-owned temporary host for a review fix')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
derived = (args.derived_data or repo / '.build/xcode').resolve()
products = derived / 'Build/Products/Debug'
if not (products / 'Tokenizers.o').exists():
    parser.error('Run make build in this worktree first')
weights = args.weights.resolve()
if not weights.is_dir():
    parser.error('Explicit installed weights folder is missing')
qa = args.reuse_root.absolute() if args.reuse_root else Path(tempfile.mkdtemp(prefix='golos-memory-panel-preview37-'))
if args.reuse_root:
    if not qa.name.startswith('golos-memory-panel-preview37-') or not qa.resolve().is_relative_to(Path(tempfile.gettempdir()).resolve()):
        parser.error('Reuse is restricted to this task-owned temporary host')
    old = plistlib.loads((qa / 'Golos Memory Panel Preview.app/Contents/Info.plist').read_bytes())
    if not old['CFBundleIdentifier'].startswith('com.golos.memory-panel-preview37.'):
        parser.error('Unexpected host bundle')
app = qa / 'Golos Memory Panel Preview.app/Contents'
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
bundle = old['CFBundleIdentifier'] if args.reuse_root else 'com.golos.memory-panel-preview37.' + uuid.uuid4().hex
synthetic_root = qa / ('library-' + uuid.uuid4().hex) if args.reuse_root else qa / 'library'
with (app / 'Info.plist').open('wb') as out:
    plistlib.dump({'CFBundleExecutable': 'MemoryPanelPreview', 'CFBundleIdentifier': bundle,
                  'CFBundleName': 'Golos Memory Panel Preview', 'NSHighResolutionCapable': True,
                  'SyntheticRoot': str(synthetic_root), 'PublicWeightsFolder': str(weights)}, out)
sources = sorted((repo / 'golos-meet/Core/Knowledge').glob('*.swift'))
sources += [repo / 'golos-meet/Core/Insights/ChatCompleter.swift']
sources += [repo / 'golos-meet' / p for p in ['Util/AppRuntime.swift', 'UI/DesignSystem/Palette.swift', 'UI/DesignSystem/Components.swift']]
sources += [repo / 'golos-meet/UI/Projects' / (p + '.swift') for p in ['ProjectLibrary', 'KnowledgeIndexing', 'KnowledgeSearchModel',
    'KnowledgeSearchScreen', 'KnowledgeSourceView', 'KnowledgeQuestionModel', 'KnowledgeQuestionScreen', 'ProjectCloudSettings', 'ProjectMemoryPanelModel', 'ProjectMemoryPanel', 'ProjectMemoryNavigation']]
sources += [repo / 'research/MemoryPanelPreview.swift']
for name in ['OpenRouterClient.swift', 'Keychain.swift', 'golos_meetApp.swift', 'ProductionKnowledgeMemory Panel.swift']:
    assert all(p.name != name for p in sources)
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
           '-module-cache-path', str(qa / 'module-cache'), '-target', 'arm64-apple-macos14.4', '-I', str(products), '-F', str(products),
           '-Xcc', '-fmodule-map-file=' + str(derived / 'Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap'),
           '-Xcc', '-fmodule-map-file=' + str(derived / 'Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap'),
           '-Xcc', '-I' + str(derived / 'SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers'),
           *map(str, sources), *map(str, products.glob('*.o')), '-framework', 'onnxruntime', '-lc++', '-Xlinker', '-rpath',
           '-Xlinker', str(products), '-o', str(app / 'MacOS/MemoryPanelPreview')]
with (qa / 'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    parser.exit(result.returncode, 'Build failed: ' + str(qa / 'build.log') + '\n')
for resource in products.glob('*.bundle'):
    shutil.copytree(resource, app / 'Resources' / resource.name, dirs_exist_ok=True)
(qa / 'source-allowlist.txt').write_text('\n'.join(map(str, sources)) + '\n')
print('APP=' + str(app.parent))
print('BUNDLE=' + bundle)
print('ROOT=' + str(synthetic_root))
print('BUILD_LOG=' + str(qa / 'build.log'))
print('SOURCE_ALLOWLIST=' + str(qa / 'source-allowlist.txt'))
