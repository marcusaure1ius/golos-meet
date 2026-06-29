#!/usr/bin/env python3
"""Dev-only: собрать transcript.json из model-comparison/<id>/raw.json.

mic → «me», system → «participants», сортировка по start (как TranscriptMerger).
Также проставляет meta.asrModel и status=ready, чтобы шапка деталей показывала модель.

NOTE: raw.json хранит системный трек под ключом «sys» (не «system»).
"""
import json
import os
from pathlib import Path

BASE = Path.home() / "Library/Application Support/golos-meet"
COMP = BASE / "model-comparison"
MEET = BASE / "meetings"
MODEL_ID = "gigaam-v3"


def build(raw: dict) -> list[dict]:
    g = raw.get("gigaam", {})
    segs = []
    for seg in g.get("mic", {}).get("segments", []):
        segs.append({"start": seg["start"], "end": seg["end"], "speaker": "me", "text": seg["text"]})
    # raw.json uses "sys", not "system"
    for seg in g.get("sys", {}).get("segments", []):
        segs.append({"start": seg["start"], "end": seg["end"], "speaker": "participants", "text": seg["text"]})
    segs.sort(key=lambda s: s["start"])
    return segs


def main() -> None:
    count = 0
    for d in sorted(COMP.iterdir()):
        raw_path = d / "raw.json"
        if not raw_path.is_file():
            continue
        meeting_id = d.name
        meeting_dir = MEET / meeting_id
        if not meeting_dir.is_dir():
            print(f"skip {meeting_id}: нет папки встречи")
            continue
        raw = json.loads(raw_path.read_text())
        transcript = {"meetingId": meeting_id, "asrModel": MODEL_ID, "segments": build(raw)}
        (meeting_dir / "transcript.json").write_text(json.dumps(transcript, ensure_ascii=False, indent=2))

        meta_path = meeting_dir / "meta.json"
        if meta_path.is_file():
            meta = json.loads(meta_path.read_text())
            meta["asrModel"] = MODEL_ID
            meta["status"] = "ready"
            meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True))
        print(f"ok {meeting_id}: {len(transcript['segments'])} сегментов")
        count += 1
    print(f"готово: {count} встреч")


if __name__ == "__main__":
    main()
