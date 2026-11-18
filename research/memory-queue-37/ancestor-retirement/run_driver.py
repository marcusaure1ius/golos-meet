"""Build/run the reviewer's actual synthetic worker/store/service repro on HEAD.

Does not modify the reviewer's original data or use models/cloud/Keychain/UI.
All runtime files go to /tmp; only existing local package outputs are linked.
"""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[3]
build=repo/'.build/xcode';products=build/'Build/Products/Debug'
work=Path(tempfile.mkdtemp(prefix='golos54-ancestor-build-',dir='/tmp'))
sources=sorted((repo/'golos-meet/Core/Knowledge').glob('*.swift'))+[repo/'golos-meet/Core/Insights/ChatCompleter.swift']
command=['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',
 '-module-cache-path',str(work/'module-cache'),'-target','arm64-apple-macos14.4','-I',str(products),'-F',str(products),
 '-Xcc','-fmodule-map-file='+str(build/'Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap'),
 '-Xcc','-fmodule-map-file='+str(build/'Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap'),
 '-Xcc','-I'+str(build/'SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers'),
 *map(str,sources),str(Path(__file__).with_name('AncestorRetirementDriver.swift')),*map(str,products.glob('*.o')),
 '-framework','onnxruntime','-lc++','-Xlinker','-rpath','-Xlinker',str(products),'-o',str(work/'driver')]
with (work/'build.log').open('w') as log:
    result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
if result.returncode: raise SystemExit('Build failed: '+str(work/'build.log'))
subprocess.run(['sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(work/'driver')],check=True)
print('Build log:',work/'build.log')
