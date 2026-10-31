#!/usr/bin/env python3
"""Copy an upstream Zed theme bundle byte-for-byte into assets/themes."""
from __future__ import annotations
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="upstream JSON theme bundle")
    parser.add_argument("--output", required=True, help="destination filename under assets/themes/")
    args = parser.parse_args()
    destination_name = Path(args.output)
    if destination_name.is_absolute() or ".." in destination_name.parts:
        parser.error("--output must be a filename or relative path inside assets/themes")
    raw = args.source.read_bytes()
    parsed = json.loads(raw)
    if not isinstance(parsed, dict) or not isinstance(parsed.get("themes"), list):
        parser.error("source must be an upstream Zed theme-family JSON bundle")
    destination = ROOT / "assets/themes" / destination_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(raw)


if __name__ == "__main__":
    main()
