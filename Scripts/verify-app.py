#!/usr/bin/env python3
"""Check both universal architectures and the integrity of an app's code signature."""
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Build/Products/Release/Otolog.app")
executable = app / "Contents" / "MacOS" / "Otolog"
architectures = set(subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split())
if not {"arm64", "x86_64"}.issubset(architectures):
    raise SystemExit(f"Missing universal architecture: {sorted(architectures)}")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(f"Verified app: {app} ({', '.join(sorted(architectures))})")
