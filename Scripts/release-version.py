#!/usr/bin/env python3
"""Validate a release tag against the source Info.plist; print a filename-safe version."""
import plistlib
import re
import sys
from pathlib import Path


def release_version(info: dict, tag: str = "") -> str:
    version = info.get("CFBundleShortVersionString", "")
    number = r"(?:0|[1-9][0-9]*)"
    base_pattern = rf"{number}\.{number}\.{number}"
    if not re.fullmatch(base_pattern, version):
        raise ValueError("CFBundleShortVersionString must be MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info.get("CFBundleVersion", "")):
        raise ValueError("CFBundleVersion must be a numeric build version")
    if not tag:
        return version
    match = re.fullmatch(rf"v({base_pattern})(?:-([0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*))?", tag)
    if match is None or match.group(1) != version:
        raise ValueError(f"Tag must match v{version} (optional prerelease suffix allowed)")
    return tag[1:]


def main() -> None:
    info_path = Path(__file__).resolve().parent.parent / "Otolog" / "Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    try:
        print(release_version(info, sys.argv[1] if len(sys.argv) > 1 else ""))
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
