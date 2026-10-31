"""Build-only synthetic UI host; never launches the app or downloads weights.

Fresh bundle id + temp library every run. Only the declared source subset is
linked: no AppDelegate, recording, ASR, Keychain or cloud-generation classes.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--weights", required=True, type=Path, help="Explicit local pinned public E5 folder")
parser.add_argument("--derived-data", type=Path)
parser.add_argument("--assignment", action="store_true", help="Build isolated assignment runtime/UI host")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
derived = (args.derived_data or repo / ".build/xcode").resolve()
prod = derived / "Build/Products/Debug"
if not (prod / "Tokenizers.o").exists():
    parser.error("Run make build with this worktree's DerivedData first")
weights = args.weights.resolve()
if not weights.is_dir():
    parser.error("The explicitly selected weights folder does not exist")
qa = Path(tempfile.mkdtemp(prefix="golos-assignment-preview14-" if args.assignment else "golos-search-preview14-"))
app_name = "Golos Assignment Preview" if args.assignment else "Golos Search Preview"
executable = "AssignmentPreview" if args.assignment else "SearchPreview"
app = qa / (app_name + ".app/Contents")
(app / "MacOS").mkdir(parents=True)
with (app / "Info.plist").open("wb") as output:
    plistlib.dump({"CFBundleExecutable": executable, "CFBundleIdentifier": ("com.golos.assignment-preview14." if args.assignment else "com.golos.search-preview14.") + uuid.uuid4().hex,
                   "CFBundleName": app_name, "NSHighResolutionCapable": True,
                   "SyntheticRoot": str(qa / "library"), "PublicWeightsFolder": str(weights)}, output)
names = ["LocalTextEmbedding", "EmbeddingModelManifest", "EmbeddingModelInstaller", "E5TextEmbedding", "LocalIndexingRuntime",
         "LocalIndexingService", "KnowledgeModels", "KnowledgeChunker", "DocumentModels", "DocumentImporter", "LocalDocumentExtractor",
         "ProjectStore", "MeetingAssignmentModels", "MeetingAssignmentRuntimeModels", "MeetingEmbeddingSnapshot", "EmbeddingIndexModels", "DocumentImportQueue", "KnowledgeIndexEvents", "KnowledgeFileMonitor",
         "KnowledgeSearchModels", "KnowledgeSearchService", "KnowledgeSearchSourceReader", "MeetingAssignmentService", "MeetingAssignmentInputReader", "MeetingAssignmentWorker"]
sources = [repo / "golos-meet/Core/Knowledge" / (name + ".swift") for name in names]
sources += [repo / "golos-meet" / name for name in ["Util/AppRuntime.swift", "UI/Projects/KnowledgeIndexing.swift", "UI/Projects/ProjectLibrary.swift",
            "UI/Projects/KnowledgeSearchModel.swift", "UI/Projects/KnowledgeSearchScreen.swift", "UI/Projects/KnowledgeSourceView.swift",
            "UI/DesignSystem/Palette.swift", "UI/DesignSystem/Components.swift"]]
if args.assignment:
    sources += [repo / "golos-meet/UI/Projects" / (name + ".swift") for name in ["KnowledgeAssignments", "MeetingAssignmentPanel", "ProjectEditors"]]
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor", "-module-cache-path", str(qa / "module-cache"),
           "-target", "arm64-apple-macos14.4", "-I", str(prod), "-F", str(prod),
           "-Xcc", "-fmodule-map-file=" + str(derived / "Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap"),
           "-Xcc", "-fmodule-map-file=" + str(derived / "Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap"),
           "-Xcc", "-I" + str(derived / "SourcePackages/artifacts/onnxruntime-swift-package-manager/onnxruntime/Headers"),
           *map(str, sources), str(repo / "research" / ("MeetingAssignmentPreview.swift" if args.assignment else "KnowledgeSearchPreview.swift")), *map(str, prod.glob("*.o")),
           "-framework", "onnxruntime", "-lc++", "-Xlinker", "-rpath", "-Xlinker", str(prod), "-o", str(app / "MacOS" / executable)]
with (qa / "build.log").open("w") as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    parser.exit(result.returncode, "Build failed; diagnostics: " + str(qa / "build.log") + "\n")
for bundle in prod.glob("*.bundle"):
    shutil.copytree(bundle, app / "Resources" / bundle.name)
print(app.parent)
print("Synthetic library:", qa / "library")
print("Build log:", qa / "build.log")
