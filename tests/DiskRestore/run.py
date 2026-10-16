#!/usr/bin/env python3
"""Compile and run the disk restore service fixtures with a bundled qemu-img."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} /path/to/qemu-img")
qemu_img = pathlib.Path(sys.argv[1]).resolve()
if not qemu_img.is_file():
    raise SystemExit(f"qemu-img not found: {qemu_img}")

with tempfile.TemporaryDirectory(prefix="poweremu-disk-restore-test-") as build_dir:
    binary = pathlib.Path(build_dir) / "DiskRestoreTests"
    subprocess.run([
        "swiftc", "-parse-as-library",
        str(root / "app/Sources/PowerEmu/DiskRestore.swift"),
        str(root / "tests/DiskRestore/main.swift"),
        "-o", str(binary),
    ], check=True, cwd=root)
    subprocess.run([str(binary), str(qemu_img)], check=True, cwd=root)
