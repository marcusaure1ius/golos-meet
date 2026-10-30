"""Guard regressions on synthetic bundle fixtures; never run Xcode or the app."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("package_preview.py")
spec = importlib.util.spec_from_file_location("package_preview", SCRIPT)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Synthetic.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir()
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.golos.golos-meet", "CFBundleExecutable": "fixture"}, stream)
        (self.app / "Contents/MacOS/fixture").write_bytes(bytes.fromhex("feedfacf") + b"synthetic")

    def test_rejects_models_audio_documents_before_inspecting_macho(self):
        for suffix in [".onnx", ".safetensors", ".bin", ".wav", ".m4a", ".docx", ".pdf"]:
            with self.subTest(suffix=suffix):
                forbidden = self.resources / ("fixture" + suffix)
                forbidden.write_bytes(b"synthetic only")
                with patch.object(packager, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "must not be packaged"):
                        packager.inspect_bundle(self.app)
                    run.assert_not_called()
                forbidden.unlink()

    def test_rejects_external_and_broken_symlinks_before_reading_target(self):
        outside = self.root / "outside-fixture"
        outside.write_text("synthetic only")
        link = self.resources / "external-link"
        for target in [outside, self.root / "missing-fixture"]:
            with self.subTest(target=target.name):
                link.symlink_to(target)
                with patch.object(packager, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "External or broken"):
                        packager.inspect_bundle(self.app)
                    run.assert_not_called()
                link.unlink()

    def test_invalid_source_ref_fails_before_creating_build_output(self):
        output = self.root / "no-build-expected"
        result = subprocess.run([sys.executable, str(SCRIPT), "--ref", "no-such-preview-ref-25", "--output", str(output)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertIn("Preview packaging failed", result.stderr)


class MakeArgumentTransport(unittest.TestCase):
    def test_real_make_to_python_preserves_literal_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            tooling = workspace / "research/preview-package"
            tooling.mkdir(parents=True)
            shutil.copy2(SCRIPT, tooling / SCRIPT.name)
            shutil.copy2(packager.REPO / "Makefile", workspace / "Makefile")
            binaries = root / "bin"
            binaries.mkdir()
            (binaries / "python3").symlink_to(sys.executable)
            # Real Python/argparse/path handling; stop at git archive before any build.
            git = binaries / "git"
            git.write_text("#!" + sys.executable + "\n" +
                           "import json, os, sys\n" +
                           "with open(os.environ['ARGUMENT_CAPTURE'], 'a') as log:\n" +
                           "    log.write(json.dumps({'argv': sys.argv[1:], 'env': {k: os.environ[k] for k in ['PREVIEW_REF', 'PREVIEW_OUTPUT', 'MAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES', 'GNUMAKEFLAGS'] if k in os.environ}}) + '\\n')\n" +
                           "if sys.argv[1] == 'rev-parse':\n" +
                           "    print('a' * 40)\n" +
                           "else:\n" +
                           "    print('Stopped before build for argument transport test', file=sys.stderr)\n" +
                           "    sys.exit(7)\n")
            git.chmod(0o755)
            capture = root / "git-arguments.jsonl"
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.defpath,
                       ARGUMENT_CAPTURE=str(capture), PYTHONDONTWRITEBYTECODE="1")
            env.pop("PREVIEW_REF", None)
            env.pop("PREVIEW_OUTPUT", None)
            created_outputs = set()
            for input_kind in ["command-line", "environment", "defaults"]:
                with self.subTest(input_kind=input_kind):
                    capture.unlink(missing_ok=True)
                    output = root / (input_kind + """ "review" package O'Brien $HOME """
                                     '$(touch shell-marker) `touch backtick-marker` '
                                     '$(shell touch make-marker) $(file >make-file-marker,marker)')
                    ref = ("""HEAD "ref" O'Brien $HOME $(touch ref-shell-marker) """
                           '`touch ref-backtick-marker` $(shell touch ref-make-marker)')
                    command = ["/usr/bin/make", "--no-print-directory", "preview-package"]
                    case_env = env.copy()
                    if input_kind == "command-line":
                        command += ["PREVIEW_REF=" + ref, "PREVIEW_OUTPUT=" + str(output)]
                    elif input_kind == "environment":
                        case_env.update(PREVIEW_REF=ref, PREVIEW_OUTPUT=str(output))
                    else:
                        ref = "HEAD"
                        output = workspace / ".build/preview"
                    result = subprocess.run(command, cwd=workspace, env=case_env,
                                            capture_output=True, text=True, timeout=15)
                    self.assertNotEqual(result.returncode, 0)  # Intentional stop at archive.
                    self.assertTrue(output.is_dir(), result.stdout + result.stderr)
                    calls = [json.loads(line) for line in capture.read_text().splitlines()]
                    self.assertEqual(calls[0]["argv"], ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"])
                    self.assertEqual(calls[1]["argv"][0], "archive")
                    self.assertEqual([call["env"] for call in calls], [{}, {}])
                    self.assertIn("Stopped before build for argument transport test", result.stderr)
                    # Only exact output data and fixtures exist; no shell/Make marker ran.
                    if input_kind != "defaults":
                        created_outputs.add(output.name)
                    self.assertEqual({p.name for p in workspace.iterdir()},
                                     {"Makefile", "research"} | ({".build"} if input_kind == "defaults" else set()))
                    self.assertEqual({p.name for p in root.iterdir()},
                                     {"workspace", "bin", "git-arguments.jsonl"} | created_outputs)
                    self.assertEqual(len(list(output.glob("preview-aaaaaaaaaaaa-*"))), 1)


if __name__ == "__main__":
    unittest.main()
