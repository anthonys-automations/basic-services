#!/usr/bin/env python3
"""Make every modifier key send one keysym regardless of the keymap section.

xrdp looks a key up in the section that matches the Shift, AltGr and Caps Lock
state at the moment of each event, and the Xvnc backend forwards the keysym
without pairing a release with its press. The shipped keymaps give left Alt
ISO_Next_Group or Meta_L under Shift, so Alt pressed alone and released while
Shift is held never reaches Xvnc as released, and Alt stays down.
"""
import re
import sys

MODIFIERS = set(range(0xFFE1, 0xFFEF)) | {0xFE03, 0xFF7E}
ENTRY = re.compile(r"^(Key\d+)=(\d+:\d+)(\r?\n?)$")


def normalize(text):
    lines = text.splitlines(keepends=True)
    base = {}
    section = None
    for line in lines:
        if line.startswith("["):
            section = line.strip()
        elif section == "[noshift]" and (match := ENTRY.match(line)):
            if int(match[2].split(":")[0]) in MODIFIERS:
                base[match[1]] = match[2]
    changed = 0
    for index, line in enumerate(lines):
        match = ENTRY.match(line)
        if match and match[1] in base and match[2] != base[match[1]]:
            lines[index] = f"{match[1]}={base[match[1]]}{match[3]}"
            changed += 1
    return "".join(lines), changed


def main(paths):
    total = 0
    for path in paths:
        with open(path, newline="") as handle:
            text, changed = normalize(handle.read())
        with open(path, "w", newline="") as handle:
            handle.write(text)
        total += changed
    print(f"normalized {total} modifier entries in {len(paths)} keymaps")


if __name__ == "__main__":
    main(sys.argv[1:])
