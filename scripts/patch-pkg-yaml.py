#!/usr/bin/env python3
"""
Rewrites the sbc-raspberrypi artifacts/dtb/raspberrypi/pkg.yaml patch loop
to be forward-aware: applies patches that aren't yet present, skips patches
already in the source tree, and fails only on genuine context drift.

Works with both mainline and RPi vendor kernels.
"""
import sys

filename = sys.argv[1] if len(sys.argv) > 1 else "artifacts/dtb/raspberrypi/pkg.yaml"

OLD = '          patch -p1 < $patch || (echo "Failed to apply patch $patch" && exit 1)'

NEW = (
    '          if patch -p1 --dry-run < $patch > /dev/null 2>&1; then\n'
    '            patch -p1 < $patch\n'
    '          elif patch -p1 --dry-run -R < $patch > /dev/null 2>&1; then\n'
    '            echo "(already applied, skipping)"\n'
    '          else\n'
    '            echo "Failed to apply patch $patch" && exit 1\n'
    '          fi'
)

content = open(filename).read()
if OLD not in content:
    print(f"ERROR: target line not found in {filename}", file=sys.stderr)
    sys.exit(1)

open(filename, "w").write(content.replace(OLD, NEW, 1))
print(f"Updated {filename}: patch loop is now forward-aware")
