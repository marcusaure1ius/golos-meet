"""Build a developer-only native CLI after `make build` (Apple Silicon).

Python invokes the compiler; all model/tokenizer execution is native Swift/ORT.
No downloads, source texts, credentials, UI, or production storage are accessed.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", type=Path)
parser.add_argument("--output", type=Path)
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--index", action="store_true", help="Build synthetic import/native/SQLite persistence probe")
mode.add_argument("--queue", action="store_true", help="Build native serial worker/runtime/reconciliation probe")
mode.add_argument("--search", action="store_true", help="Build synthetic local hybrid retrieval/freshness probe")
mode.add_argument("--assignment", action="store_true", help="Build local assignment engine/evaluation probe")
args = parser.parse_args()
args.output = args.output or Path("/tmp/golos-native-assignment-probe" if args.assignment else "/tmp/golos-native-search-probe" if args.search else "/tmp/golos-native-indexing-queue-probe" if args.queue else
                                "/tmp/golos-native-embedding-index-probe" if args.index else "/tmp/golos-native-embedding-probe")
repo = Path(__file__).resolve().parents[1]
derived = (args.derived_data or repo / ".build/xcode").resolve()
products = derived / "Build/Products/Debug"
maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
artifacts = derived / "SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers"
sources = [repo / "golos-meet/Core/Knowledge" / name for name in
           ["LocalTextEmbedding.swift", "EmbeddingModelManifest.swift", "EmbeddingModelInstaller.swift", "E5TextEmbedding.swift"]]
if args.index or args.queue or args.search or args.assignment:
    sources += [repo / "golos-meet/Core/Knowledge" / name for name in
                ["KnowledgeModels.swift", "KnowledgeChunker.swift", "DocumentModels.swift", "DocumentImporter.swift",
                 "LocalDocumentExtractor.swift", "ProjectStore.swift", "EmbeddingIndexModels.swift", "MeetingEmbeddingSnapshot.swift", "KnowledgeSearchModels.swift", "MeetingAssignmentModels.swift", "MeetingAssignmentRuntimeModels.swift"]]
if args.queue or args.search or args.assignment:
    sources += [repo / "golos-meet/Core/Knowledge" / name for name in ["LocalIndexingRuntime.swift", "LocalIndexingService.swift"]]
if args.search or args.assignment:
    sources += [repo / "golos-meet/Core/Knowledge" / name for name in ["KnowledgeSearchService.swift", "KnowledgeSearchSourceReader.swift"]]
if args.assignment:
    sources += [repo / "golos-meet/Core/Knowledge" / name for name in ["MeetingAssignmentPolicy.swift", "MeetingAssignmentService.swift", "MeetingAssignmentInputReader.swift", "MeetingAssignmentWorker.swift"]]
probe = "NativeMeetingAssignmentProbe.swift" if args.assignment else "NativeKnowledgeSearchProbe.swift" if args.search else "NativeIndexingQueueProbe.swift" if args.queue else "NativeEmbeddingIndexProbe.swift" if args.index else "NativeEmbeddingProbe.swift"
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
           *map(str, sources), str(repo / "research" / probe), *map(str, objects),
           "-framework", "onnxruntime", "-lc++", "-Xlinker", "-rpath", "-Xlinker", str(products),
           "-o", str(args.output)]
subprocess.run(command, check=True)
print(args.output)
