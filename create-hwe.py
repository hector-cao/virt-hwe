#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Callable


PACKAGE_RE = re.compile(r"^Package:\s*(\S+)\s*$")
SOURCE_RE = re.compile(r"^Source:\s*(\S+)\s*$", re.MULTILINE)
SKIP_PACKAGE_PREFIX = "ubuntu-virt"
RENAMABLE_FIELDS = (
    "Depends",
    "Pre-Depends",
    "Recommends",
    "Suggests",
    "Enhances",
    "Breaks",
    "Conflicts",
    "Replaces",
    "Provides",
)


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


def update_package_name(stanza: list[str], new_package: str) -> bool:
    for index, line in enumerate(stanza):
        if PACKAGE_RE.match(line):
            previous_line = stanza[index]
            stanza[index] = f"Package: {new_package}"
            return previous_line != stanza[index]
    return False


def find_field_block(stanza: list[str], field: str) -> tuple[int, int] | None:
    header = f"{field}:"
    for i, line in enumerate(stanza):
        if line.startswith(header):
            end = i + 1
            while end < len(stanza) and stanza[end].startswith((" ", "\t")):
                end += 1
            return i, end
    return None


def rename_package_words(text: str, mapping: dict[str, str]) -> str:
    updated = text
    for package_name in sorted(mapping, key=len, reverse=True):
        replacement = mapping[package_name]
        token_re = re.compile(rf"(?<![A-Za-z0-9+.-]){re.escape(package_name)}(?![A-Za-z0-9+.-])")
        updated = token_re.sub(replacement, updated)
    return updated


def rename_stanza_field_packages(stanza: list[str], mapping: dict[str, str]) -> int:
    if not mapping:
        return 0

    changed_lines = 0

    for field in RENAMABLE_FIELDS:
        block = find_field_block(stanza, field)
        if not block:
            continue

        start, end = block
        for line_index in range(start, end):
            line = stanza[line_index]

            if line_index == start:
                prefix, value = line.split(":", 1)
                updated_line = f"{prefix}:{rename_package_words(value, mapping)}"
                if updated_line != stanza[line_index]:
                    changed_lines += 1
                stanza[line_index] = updated_line
                continue

            leading_len = len(line) - len(line.lstrip(" \t"))
            leading = line[:leading_len]
            payload = line[leading_len:]
            if payload.lstrip().startswith("#"):
                continue
            updated_line = f"{leading}{rename_package_words(payload, mapping)}"
            if updated_line != stanza[line_index]:
                changed_lines += 1
            stanza[line_index] = updated_line

    return changed_lines


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


def ensure_field_token(stanza: list[str], field: str, token: str) -> bool:
    if field_has_token(stanza, field, token):
        return False

    if find_field_block(stanza, field):
        append_to_existing_field(stanza, field, token)
    else:
        insert_new_field(stanza, field, token)

    return True


def process_control_text(text: str, log: Callable[[str], None] | None = None) -> str:
    if log is None:
        log = lambda _message: None

    lines = text.splitlines()
    stanzas = split_stanzas(lines)

    # Step 1: build package list.
    log("[step 1/4] Building package list")
    package_list: set[str] = set()
    for stanza in stanzas:
        if not stanza or stanza[0].strip() == "":
            continue

        package = find_package_name(stanza)
        if package is None:
            continue

        if package.startswith(SKIP_PACKAGE_PREFIX):
            log(f"[step 1/4] Skipping package with prefix '{SKIP_PACKAGE_PREFIX}': {package}")
            continue

        if package.endswith("-hwe"):
            raise ValueError(f"Package '{package}' already has -hwe suffix")

        base_package = package[:-4] if package.endswith("-hwe") else package
        package_list.add(base_package)

    hwe_mapping = {package: f"{package}-hwe" for package in package_list}
    log(f"[step 1/4] Found {len(package_list)} packages")

    log("[step 2/4] Renaming matched package names to -hwe counterparts")
    processed_packages = 0

    for stanza in stanzas:
        if not stanza or stanza[0].strip() == "":
            continue

        package = find_package_name(stanza)
        if package is None:
            continue

        if package.startswith(SKIP_PACKAGE_PREFIX):
            log(f"[package] Skipping package with prefix '{SKIP_PACKAGE_PREFIX}': {package}")
            continue

        base_package = package[:-4] if package.endswith("-hwe") else package
        hwe_package = f"{base_package}-hwe"
        processed_packages += 1
        log(f"[package] {base_package} -> {hwe_package}")

        # Step 2: rename matched package words to -hwe counterpart.
        renamed_lines = rename_stanza_field_packages(stanza, hwe_mapping)
        if renamed_lines > 0:
            log(f"  [rename] Updated {renamed_lines} relation line(s)")

        package_renamed = update_package_name(stanza, hwe_package)
        if package_renamed:
            log("  [rename] Updated Package field")

        # Step 3: add requested relationship tokens.
        log("[step 3/4] Ensuring relation fields")
        if ensure_field_token(stanza, "Conflicts", "ubuntu-virt"):
            log("  [field] Added Conflicts: ubuntu-virt")
        if ensure_field_token(stanza, "Provides", "ubuntu-virt-hwe"):
            log("  [field] Added Provides: ubuntu-virt-hwe")
        if ensure_field_token(stanza, "Replaces", base_package):
            log(f"  [field] Added Replaces: {base_package}")
        if ensure_field_token(stanza, "Provides", base_package):
            log(f"  [field] Added Provides: {base_package}")

    output_lines: list[str] = []
    for stanza in stanzas:
        output_lines.extend(stanza)

    output = "\n".join(output_lines) + "\n"

    log("[step 4/4] Renaming source package to -hwe counterpart")
    source_match = SOURCE_RE.search(output)
    if source_match is None:
        log("[step 4/4] No source package rename needed")
    else:
        source = source_match.group(1)
        if source.endswith("-hwe"):
            raise ValueError(f"Source package '{source}' already has -hwe suffix")

        output = SOURCE_RE.sub(f"Source: {source}-hwe", output, count=1)
        log(f"[source] {source} -> {source}-hwe")

    log(f"[done] Processed {processed_packages} package stanza(s)")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "For each Package stanza in debian/control, rename package to <name>-hwe "
            "and ensure Conflicts includes ubuntu-virt and <name>, Provides includes "
            "ubuntu-virt-hwe, and Replaces includes <name>, then rename Source to "
            "<source>-hwe."
        )
    )
    parser.add_argument(
        "control_file",
        nargs="?",
        default="debian/control",
        help="Path to control file (default: debian/control)",
    )
    parser.add_argument(
        "-o",
        "--output",
        dest="output_file",
        help="Write transformed output to this file (default: overwrite control_file)",
    )

    args = parser.parse_args()
    input_path = Path(args.control_file)
    output_path = Path(args.output_file) if args.output_file else input_path

    original = input_path.read_text(encoding="utf-8")
    try:
        updated = process_control_text(original, log=print)
    except ValueError as error:
        print(f"[error] {error}")
        return 1

    if output_path == input_path:
        if updated != original:
            output_path.write_text(updated, encoding="utf-8")
            print(f"[write] Updated {output_path}")
        else:
            print(f"[write] No changes needed for {output_path}")
    else:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(updated, encoding="utf-8")
        if updated != original:
            print(f"[write] Wrote transformed content to {output_path}")
        else:
            print(f"[write] Wrote unchanged content to {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
