"""Record screenshot provenance without changing pixels; uses only stdlib."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
source = root / "research/ui18/native/MockHost.swift"
origin = b"Origin\x00Native AppKit window-frame + NSHostingView/cacheDisplay; research/ui18/native/MockHost.swift; synthetic data; no ImageGen"
chunk_type = b"tEXt"
chunk = struct.pack(">I", len(origin)) + chunk_type + origin + struct.pack(">I", zlib.crc32(chunk_type + origin))
manifest = {
    "kind": "conceptual native offscreen renders, not production screenshots",
    "source": "research/ui18/native/MockHost.swift",
    "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "command": "research/ui18/native/render.sh",
    "checked_environment": "macOS 27.0.1; Xcode 27.1 (27A9275); SDK 27.0; arm64; target 14.4",
    "optical_glass": "not validated; native NSToolbar and NSVisualEffectView sidebar; offscreen inactive window",
    "images": [],
}
for path in sorted(output.glob("*.png")):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not PNG: {path.name}")
    width, height = struct.unpack(">II", data[16:24])
    # IHDR ends at byte 33; insert provenance before the image chunks.
    data = data[:33] + chunk + data[33:]
    path.write_bytes(data)
    manifest["images"].append({"file": path.name, "pixels": [width, height], "sha256": hashlib.sha256(data).hexdigest()})
(output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
