"""Guard regressions on synthetic bundle fixtures; never run Xcode or the app."""
import importlib.util
from pathlib import Path
import plistlib
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


if __name__ == "__main__":
    unittest.main()
