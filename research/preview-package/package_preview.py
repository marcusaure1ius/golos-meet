#!/usr/bin/env python3
"""Build a committed snapshot without launching the app or accessing its data."""
import argparse
import datetime as dt
import hashlib
import json
import os
import platform
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[2]
MACHO_MAGIC = {bytes.fromhex(s) for s in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}

def qa_profile(identifier):
    if not re.fullmatch(r"[0-9a-f]{32}", identifier):
        raise RuntimeError("Invalid isolated QA identifier")
    return {"kind": "isolated-qa-v1", "identifier": identifier,
            "bundle_id": "com.golos.golos-meet.qa." + identifier,
            "display_name": "Golos Meet QA", "app_support_component": "golos-meet-qa-" + identifier,
            "user_defaults_domain": "com.golos.golos-meet.qa." + identifier,
            "keychain_service": "golos-meet.qa." + identifier}

def apply_qa_metadata(app, identifier):
    profile = qa_profile(identifier)
    path = app / "Contents/Info.plist"
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    info.update(CFBundleIdentifier=profile["bundle_id"], CFBundleDisplayName=profile["display_name"],
                CFBundleName=profile["display_name"], GolosRuntimeProfile=profile["kind"],
                GolosPreviewIdentifier=identifier)
    with path.open("wb") as stream:
        plistlib.dump(info, stream)
    return profile

def validate_identity(info, qa_identifier=None):
    if qa_identifier is None:
        if (info.get("CFBundleIdentifier") != "com.golos.golos-meet"
                or any(k in info for k in ("GolosRuntimeProfile", "GolosPreviewIdentifier"))
                or info.get("CFBundleDisplayName") == "Golos Meet QA"
                or info.get("CFBundleName") == "Golos Meet QA"):
            raise RuntimeError("Unexpected normal bundle/profile identity")
    else:
        profile = qa_profile(qa_identifier)
        expected = {"CFBundleIdentifier": profile["bundle_id"], "CFBundleDisplayName": profile["display_name"],
                    "CFBundleName": profile["display_name"], "GolosRuntimeProfile": profile["kind"],
                    "GolosPreviewIdentifier": qa_identifier}
        if any(info.get(k) != v for k, v in expected.items()):
            raise RuntimeError("Invalid isolated QA profile metadata")

def verify_isolated_source(source):
    # A new packager must not label an old binary that still uses production data.
    archived_packager = source / "research/preview-package/package_preview.py"
    profile = source / "golos-meet/Util/AppProfile.swift"
    if (not archived_packager.is_file() or sha256(archived_packager) != sha256(Path(__file__))
            or not profile.is_file() or '"isolated-qa-v1"' not in profile.read_text()):
        raise RuntimeError("Isolated QA requires the same committed packager and runtime profile source")
    return {"runtime_profile_sha256": sha256(profile), "archived_packager_sha256": sha256(archived_packager)}


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inside(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def loads(binary):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in run("/usr/bin/otool", "-arch", platform.machine(), "-L", str(binary)).splitlines()[1:]]


def build_sidecar(source, work, app):
    target = work / "RustTarget"
    # Do not allow a developer's external ORT paths or linker overrides to select a runtime.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ORT_", "DYLD_", "CARGO_TARGET_"))
           and k not in {"RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_TARGET", "CARGO_TARGET_DIR"}}
    command = ["cargo", "build", "--release", "--locked", "--jobs", "2",
               "--manifest-path", str(source / "asr/Cargo.toml"), "--target-dir", str(target)]
    with (work / "rust-build.log").open("w") as log:
        result = subprocess.run(command, cwd=source / "asr", env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Sidecar build failed ({result.returncode}); see {work / 'rust-build.log'}")
    binary = target / "release/golos-asr"
    # Current locked build links ORT/Whisper statically. Never borrow Swift's ORT for Rust.
    # An unexpected dynamic runtime needs explicit packaging support, not a host-library fallback.
    external = [d for d in loads(binary) if not d.startswith(("/usr/lib/", "/System/Library/"))]
    if external:
        raise RuntimeError(f"Sidecar needs additional bundled runtime support: {external}")
    destination = app / "Contents/Resources/golos-asr"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, destination)
    return {"build_command": command, "cargo_lock_sha256": sha256(source / "asr/Cargo.lock"),
            "cargo": run("cargo", "--version"), "rustc": run("rustc", "-vV"),
            "source_binary_sha256": sha256(binary), "external_non_system_dylibs": external,
            "runtime_linkage": "static ORT/Whisper; system dylibs only (otool)"}


def sign_and_smoke(app, work):
    # Ad-hoc sign inside-out, only this generated copy. No developer certificates/Keychain.
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACHO_MAGIC:
                run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path))
    containers = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink()
                  and p.suffix in {".framework", ".bundle", ".app", ".xpc", ".appex"}]
    for container in sorted(containers, key=lambda p: len(p.parts), reverse=True):
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(container))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    smoke = work / "sidecar-smoke"
    smoke.mkdir()
    env = {"PATH": os.defpath, "HOME": str(smoke), "TMPDIR": str(smoke)}
    report = {}
    for argument in ["--version", "--help"]:
        result = subprocess.run([str(app / "Contents/Resources/golos-asr"), argument],
                                cwd=smoke, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, check=True, timeout=10)
        if "golos-asr" not in result.stdout or '"type":"hello"' in result.stdout:
            raise RuntimeError("Unexpected sidecar CLI smoke output")
        report[argument] = result.stdout.strip()
    return report


def inspect_bundle(app, qa_identifier=None):
    """Static inspection only. Reject external symlinks and non-system dylibs."""
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    validate_identity(info, qa_identifier)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if not executable.is_file():
        raise RuntimeError("Missing app executable")
    binaries = []
    inventory = []
    for path in sorted(app.rglob("*")):
        relative = str(path.relative_to(app))
        if path.is_symlink():
            if not inside(path, app) or not path.exists():
                raise RuntimeError(f"External or broken bundle symlink: {relative}")
            inventory.append({"path": relative, "symlink": str(path.readlink())})
        elif path.is_file():
            if path.suffix.lower() in {".onnx", ".gguf", ".ggml", ".safetensors", ".bin",
                                       ".wav", ".mp3", ".m4a", ".flac", ".docx", ".pdf"}:
                raise RuntimeError(f"Model/audio/document must not be packaged: {relative}")
            inventory.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha256(path)})
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    binaries.append(path)
    if executable not in binaries:
        raise RuntimeError("App executable is not Mach-O")

    def rpaths(binary):
        return re.findall(r"\n\s+path (.+) \(offset \d+\)", run("/usr/bin/otool", "-arch", platform.machine(), "-l", str(binary)))

    def expand(value, binary):
        return Path(value.replace("@executable_path", str(executable.parent))
                    .replace("@loader_path", str(binary.parent)))

    main_rpaths = rpaths(executable)
    report = []
    for binary in binaries:
        search = [expand(p, binary) for p in rpaths(binary)] + [expand(p, executable) for p in main_rpaths]
        dependencies = []
        for dependency in loads(binary):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                dependencies.append({"load": dependency, "system": True})
                continue
            if dependency.startswith("@rpath/"):
                candidates = [p / dependency[len("@rpath/"):] for p in search]
            else:
                candidates = [expand(dependency, binary)]
            resolved = next((p for p in candidates if inside(p, app) and p.is_file()), None)
            if resolved is None:
                raise RuntimeError(f"Unbundled dependency in {binary.name}: {dependency}")
            dependencies.append({"load": dependency, "bundled": str(resolved.relative_to(app))})
        report.append({"path": str(binary.relative_to(app)),
                       "architectures": run("/usr/bin/lipo", "-archs", str(binary)).split(),
                       "dependencies": dependencies})
    onnx = [b for b in report if "onnxruntime.framework/" in b["path"]]
    linked_onnx = any("onnxruntime.framework/" in d["load"]
                      for b in report for d in b["dependencies"])
    if not onnx or not linked_onnx:
        raise RuntimeError("Embedded, linked ONNX Runtime framework is required")
    app_archs = set(next(b["architectures"] for b in report if b["path"] == str(executable.relative_to(app))))
    if any(not app_archs.issubset(set(b["architectures"])) for b in report):
        raise RuntimeError("A bundled runtime lacks an app architecture")
    return info, report, inventory


def unregister_build_product(product):
    # Xcode registers its temporary build product with LaunchServices even for `build`.
    # Remove only that generated URL, never an installed app or a bundle-ID-wide entry.
    tool = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
    if product.is_dir():
        run(tool, "-u", str(product))


def main():
    # Consume literal Make inputs once. Do not expose them or Make's recursive
    # overrides to nested build tools, which may themselves invoke Make.
    ref_default = os.environ.pop("PREVIEW_REF", "HEAD")
    output_default = os.environ.pop("PREVIEW_OUTPUT", None)
    isolated_default = os.environ.pop("PREVIEW_ISOLATED_QA", "0")
    for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "GNUMAKEFLAGS"):
        os.environ.pop(key, None)
    parser = argparse.ArgumentParser(description=__doc__)
    if isolated_default not in {"0", "1"}:
        parser.error("PREVIEW_ISOLATED_QA must be 0 or 1")
    parser.add_argument("--ref", default=ref_default,
                        help="Committed source ref (default: PREVIEW_REF or HEAD)")
    parser.add_argument("--output", type=Path, default=output_default,
                        help="Parent for a new unique build/output directory (or PREVIEW_OUTPUT)")
    parser.add_argument("--isolated-qa", action="store_true", default=isolated_default == "1",
                        help="Package one separate Golos Meet QA with isolated data/settings/Keychain")
    args = parser.parse_args()
    if args.output is None:
        parser.error("--output or PREVIEW_OUTPUT is required")
    # PREVIEW_QA_ID — пин идентификатора изолированного QA-профиля: без него
    # каждая сборка получает свежий uuid и чистый профиль данных/Keychain.
    pinned_qa = os.environ.pop("PREVIEW_QA_ID", None)
    identifier = (pinned_qa or uuid.uuid4().hex) if args.isolated_qa else None
    if pinned_qa and not args.isolated_qa:
        parser.error("PREVIEW_QA_ID requires --isolated-qa / PREVIEW_ISOLATED_QA=1")
    profile = qa_profile(identifier) if identifier else {"kind": "normal"}
    commit = run("git", "rev-parse", "--verify", "--end-of-options", args.ref + "^{commit}", cwd=REPO)
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    # A fresh directory owns the snapshot, DerivedData and deliverables. Never reuse/delete another build.
    work = Path(tempfile.mkdtemp(prefix=f"preview-{commit[:12]}-", dir=output))
    print(f"Source SHA: {commit}\nBuild/output: {work}", flush=True)
    source = work / "source"
    source.mkdir()
    archive = work / "source.tar"
    subprocess.run(["git", "archive", "--format=tar", "-o", str(archive), commit], cwd=REPO, check=True)
    subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(source)], check=True)
    archive.unlink()
    profile_source = verify_isolated_source(source) if identifier else None
    pins = source / "golos-meet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins_hash = sha256(pins)
    cargo_lock_hash = sha256(source / "asr/Cargo.lock")
    derived = work / "DerivedData"
    command = ["xcodebuild", "build", "-project", str(source / "golos-meet.xcodeproj"),
               "-scheme", "golos-meet", "-configuration", "Debug", "-destination", "platform=macOS",
               "-derivedDataPath", str(derived), "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO"]
    if identifier:
        # Even the temporary Xcode product must have a distinct registration identity.
        command.append("PRODUCT_BUNDLE_IDENTIFIER=" + profile["bundle_id"])
    product = derived / "Build/Products/Debug/Golos Meet.app"
    try:
        with (work / "build.log").open("w") as log:
            result = subprocess.run(command, cwd=source, stdout=log, stderr=subprocess.STDOUT)
    finally:
        unregister_build_product(product)
    if result.returncode:
        raise RuntimeError(f"Build failed ({result.returncode}); see {work / 'build.log'}")
    if sha256(pins) != pins_hash:
        raise RuntimeError("Build changed Package.resolved; refusing a non-pinned package")
    payload = work / f"Golos-Meet-preview-{commit[:12]}"
    payload.mkdir()
    app = payload / ("Golos Meet QA.app" if identifier else product.name)
    subprocess.run(["/usr/bin/ditto", str(product), str(app)], check=True)
    if identifier:
        apply_qa_metadata(app, identifier)
    rust = build_sidecar(source, work, app)
    if sha256(source / "asr/Cargo.lock") != cargo_lock_hash:
        raise RuntimeError("Build changed Cargo.lock")
    # Inspect before signing, then hash the final signed bytes.
    inspect_bundle(app, identifier)
    rust["packaged_cli_smoke"] = sign_and_smoke(app, work)
    info, binaries, inventory = inspect_bundle(app, identifier)
    sidecar = app / "Contents/Resources/golos-asr"
    manifest = {
        "source_sha": commit, "source_tree": run("git", "rev-parse", commit + "^{tree}", cwd=REPO),
        "packager_sha256": sha256(Path(__file__)), "package_resolved_sha256": pins_hash,
        "packages": json.loads(pins.read_text())["pins"],
        "built_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "xcode": run("xcodebuild", "-version"), "macos": run("/usr/bin/sw_vers", "-productVersion"),
        "build_command": command, "configuration": "Debug", "code_signing": "ad-hoc local preview; no notarization",
        "bundle_id": info["CFBundleIdentifier"], "executable": info["CFBundleExecutable"],
        "isolation_profile": profile,
        "isolation_source_contract": profile_source,
        "app_launched": False, "temporary_build_registration_removed": True, "model_weights_included": False, "user_data_included": False,
        "asr_sidecar_included": sidecar.is_file(), "whole_product_ready": False,
        "runtime_checks": binaries, "asr_sidecar": rust,
    }
    (payload / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (payload / "bundle-inventory.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n")
    instructions = "ISOLATED_QA.md" if identifier else "README.md"
    subprocess.run(["/usr/bin/ditto", str(Path(__file__).with_name(instructions)), str(payload / "MANUAL_CHECK.md")], check=True)
    package = work / (payload.name + ".zip")
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(package)], check=True)
    (work / "package.sha256").write_text(f"{sha256(package)}  {package.name}\n")
    print(f"Packaged without launch: {package}\nSHA-256: {sha256(package)}\n"
          f"ASR-sidecar included: {sidecar.is_file()}\nThis is not whole-product acceptance.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Preview packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
