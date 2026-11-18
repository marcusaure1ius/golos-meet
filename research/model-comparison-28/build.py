"""Link the standalone research CLI with pinned dependencies built by make check."""
import argparse
from pathlib import Path
import subprocess
p=argparse.ArgumentParser();p.add_argument('--derived-data',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();repo=Path(__file__).resolve().parents[2];derived=a.derived_data.resolve()
products=derived/'Build/Products/Debug';maps=derived/'Build/Intermediates.noindex/GeneratedModuleMaps'
headers=derived/'SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers'
objects=[products/(name+'.o') for name in ['Crypto','EventSource','Hub','HuggingFace','InternalCollectionsUtilities','Jinja','OnnxRuntimeBindings','OrderedCollections','Tokenizers','yyjson']]
assert all(x.is_file() for x in objects),'Run make check first with this DerivedData'
a.output.parent.mkdir(parents=True,exist_ok=True)
command=['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor','-module-cache-path',str(a.output.parent/'swift-module-cache'),'-target','arm64-apple-macos14.4','-I',str(products),'-F',str(products),'-Xcc','-fmodule-map-file='+str(maps/'OnnxRuntimeBindings.modulemap'),'-Xcc','-fmodule-map-file='+str(maps/'yyjson.modulemap'),'-Xcc','-I'+str(headers),str(Path(__file__).with_name('Compare.swift')),*map(str,objects),'-framework','onnxruntime','-lc++','-Xlinker','-rpath','-Xlinker',str(products),'-o',str(a.output)]
subprocess.run(command,check=True);print(a.output)
