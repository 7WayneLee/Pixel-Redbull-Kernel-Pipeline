#!/usr/bin/env python3
"""Adapt Next 1.1.1 to the existing 4.19 seccomp structure."""
from pathlib import Path
import argparse
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--kernel-dir", type=Path, required=True)
args = parser.parse_args()
root = args.kernel_dir
header = root / "include/linux/seccomp.h"
original = header.read_bytes()
if b"filter_count" in original:
    print("Stock seccomp already has filter_count; no adapter needed")
else:
    makefile = root / "KernelSU-Next/kernel/Makefile"
    core = root / "KernelSU-Next/kernel/core_hook.c"
    make_text = makefile.read_text()
    pattern = r'^ifneq[^\n]*filter_count[^\n]*\n.*?^endif\n'
    matches = list(re.finditer(pattern, make_text, re.M | re.S))
    if len(matches) != 1:
        raise SystemExit("Unexpected Next seccomp backport block; review before building")
    match = matches[0]
    if "include/linux/seccomp.h" not in match.group() or "patching struct seccomp" not in match.group():
        raise SystemExit("Unexpected backport block contents")
    core_text = core.read_text()
    reset = "atomic_set(&current->seccomp.filter_count, 0);"
    if core_text.count(reset) != 1:
        raise SystemExit("Unexpected Next seccomp reset; review before building")
    # Older seccomp implementations have no counter; preserve the shipped
    # structure and omit only the reset of the nonexistent counter.
    makefile.write_text(make_text[:match.start()] + make_text[match.end():])
    core.write_text(core_text.replace(reset, "/* Stock 4.19 has no filter_count to reset. */"))
    if header.read_bytes() != original:
        raise SystemExit("Stock seccomp header was modified unexpectedly")
    print("Next adapted to stock seccomp without changing the kernel header")
