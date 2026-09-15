#!/usr/bin/env python3
"""Copy the app sources and strip `#Preview` blocks.

The Command Line Tools toolchain ships no PreviewsMacros plugin, so any file
containing `#Preview { … }` aborts type-checking. Xcode expands the macro
normally; this copy step only exists so the harness can build without Xcode.
"""
import os
import shutil
import sys


def strip_previews(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].lstrip().startswith("#Preview"):
            depth, started = 0, False
            while i < len(lines):
                for char in lines[i]:
                    if char == "{":
                        depth += 1
                        started = True
                    elif char == "}":
                        depth -= 1
                i += 1
                if started and depth <= 0:
                    break
            continue
        out.append(lines[i])
        i += 1
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))


def main():
    if len(sys.argv) != 3:
        print("usage: strippreview.py <source dir> <destination dir>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    for root, _, files in os.walk(dst):
        for name in files:
            if name.endswith(".swift"):
                strip_previews(os.path.join(root, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
