"""Build a developer-only native CLI after `make build` (Apple Silicon).

Python invokes the compiler; all model/tokenizer execution is native Swift/ORT.
No downloads, source texts, credentials, UI, or production storage are accessed.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", type=Path)
parser.add_argument("--output", type=Path, default=Path("/tmp/golos-native-embedding-probe"))
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
derived = (args.derived_data or repo / ".build/xcode").resolve()
products = derived / "Build/Products/Debug"
maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
artifacts = derived / "SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers"
sources = [repo / "golos-meet/Core/Knowledge" / name for name in
           ["LocalTextEmbedding.swift", "EmbeddingModelManifest.swift", "EmbeddingModelInstaller.swift", "E5TextEmbedding.swift"]]
objects = [products / (name + ".o") for name in ["Crypto", "EventSource", "Hub", "HuggingFace",
           "InternalCollectionsUtilities", "Jinja", "OnnxRuntimeBindings", "OrderedCollections", "Tokenizers", "yyjson"]]
for required in sources + objects:
    if not required.exists():
        parser.error(f"Missing build output: {required}. Run make build first.")
args.output.parent.mkdir(parents=True, exist_ok=True)
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
           "-target", "arm64-apple-macos14.4", "-I", str(products), "-F", str(products),
           "-Xcc", "-fmodule-map-file=" + str(maps / "OnnxRuntimeBindings.modulemap"),
           "-Xcc", "-fmodule-map-file=" + str(maps / "yyjson.modulemap"), "-Xcc", "-I" + str(artifacts),
           *map(str, sources), str(repo / "research/NativeEmbeddingProbe.swift"), *map(str, objects),
           "-framework", "onnxruntime", "-lc++", "-Xlinker", "-rpath", "-Xlinker", str(products),
           "-o", str(args.output)]
subprocess.run(command, check=True)
print(args.output)
