#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
from pathlib import Path


PACKAGE_RE = re.compile(r"^Package:\s*(\S+)\s*$")


def split_stanzas(lines: list[str]) -> list[list[str]]:
    stanzas: list[list[str]] = []
    current: list[str] = []

    for line in lines:
        if line.strip() == "":
            if current:
                stanzas.append(current)
                current = []
            stanzas.append([line])
            continue
        current.append(line)

    if current:
        stanzas.append(current)

    return stanzas


def find_package_name(stanza: list[str]) -> str | None:
    for line in stanza:
        match = PACKAGE_RE.match(line)
        if match:
            return match.group(1)
    return None


def find_field_block(stanza: list[str], field: str) -> tuple[int, int] | None:
    header = f"{field}:"
    for i, line in enumerate(stanza):
        if line.startswith(header):
            end = i + 1
            while end < len(stanza) and stanza[end].startswith((" ", "\t")):
                end += 1
            return i, end
    return None


def field_has_token(stanza: list[str], field: str, token: str) -> bool:
    block = find_field_block(stanza, field)
    if not block:
        return False

    start, end = block
    raw_value_lines = [stanza[start].split(":", 1)[1]] + stanza[start + 1 : end]
    value_lines: list[str] = []
    for line in raw_value_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        value_lines.append(line)
    text = "\n".join(value_lines)

    token_re = re.compile(rf"(?<![A-Za-z0-9+.-]){re.escape(token)}(?![A-Za-z0-9+.-])")
    return token_re.search(text) is not None


def append_to_existing_field(stanza: list[str], field: str, token: str) -> None:
    block = find_field_block(stanza, field)
    if not block:
        raise ValueError(f"Field '{field}' not found")

    start, end = block
    last_relation_line: int | None = None
    for idx in range(end - 1, start, -1):
        stripped = stanza[idx].strip()
        if stripped and not stripped.startswith("#"):
            last_relation_line = idx
            break

    inline_value = stanza[start].split(":", 1)[1].strip()

    if last_relation_line is not None:
        if not stanza[last_relation_line].rstrip().endswith(","):
            stanza[last_relation_line] = stanza[last_relation_line] + ","
    elif inline_value and inline_value != ",":
        if not stanza[start].rstrip().endswith(","):
            stanza[start] = stanza[start] + ","

    stanza.insert(end, f" {token}")


def insert_new_field(stanza: list[str], field: str, token: str) -> None:
    description_index = next((i for i, line in enumerate(stanza) if line.startswith("Description:")), None)
    new_line = f"{field}: {token}"

    if description_index is None:
        stanza.append(new_line)
    else:
        stanza.insert(description_index, new_line)


def ensure_field_token(stanza: list[str], field: str, token: str) -> None:
    if field_has_token(stanza, field, token):
        return

    if find_field_block(stanza, field):
        append_to_existing_field(stanza, field, token)
    else:
        insert_new_field(stanza, field, token)


def process_control_text(text: str) -> str:
    lines = text.splitlines()
    stanzas = split_stanzas(lines)

    for stanza in stanzas:
        if not stanza or stanza[0].strip() == "":
            continue

        package = find_package_name(stanza)
        if package is None:
            continue

        ensure_field_token(stanza, "Replaces", f"{package}-hwe")
        ensure_field_token(stanza, "Depends", "ubuntu-virt")

    output_lines: list[str] = []
    for stanza in stanzas:
        output_lines.extend(stanza)

    return "\n".join(output_lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "For each Package stanza in debian/control, ensure "
            "Depends: ubuntu-virt and Replaces: <package>-hwe are present."
        )
    )
    parser.add_argument(
        "control_file",
        nargs="?",
        default="debian/control",
        help="Path to control file (default: debian/control)",
    )

    args = parser.parse_args()
    path = Path(args.control_file)

    original = path.read_text(encoding="utf-8")
    updated = process_control_text(original)

    if updated != original:
        path.write_text(updated, encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
