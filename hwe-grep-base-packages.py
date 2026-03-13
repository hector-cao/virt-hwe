#!/usr/bin/env python3

from __future__ import annotations

import re
from pathlib import Path

PACKAGE_RE = re.compile(r"^Package:\s*(\S+)\s*$")
SKIP_PACKAGE_PREFIX = "ubuntu-virt"
SKIP_FILE_PATTERNS = ("*NEWS", "*changelog", "*TODO*", "*README*", "*LICENSE*", "*COPYING*", "*.1", "*install")


def collect_base_packages(control_path: Path) -> list[str]:
    packages: set[str] = set()

    for line in control_path.read_text(encoding="utf-8").splitlines():
        match = PACKAGE_RE.match(line)
        if not match:
            continue

        package = match.group(1)
        base_package = package[:-4] if package.endswith("-hwe") else package

        if base_package.startswith(SKIP_PACKAGE_PREFIX):
            continue

        packages.add(base_package)

    return sorted(packages)


def is_probably_text(path: Path) -> bool:
    try:
        raw = path.read_bytes()
    except OSError:
        return False

    return b"\x00" not in raw


def should_skip_file(path: Path) -> bool:
    for pattern in SKIP_FILE_PATTERNS:
        if path.match(pattern):
            return True
    return False


def find_occurrences(debian_dir: Path, base_packages: list[str]) -> dict[str, list[tuple[Path, int]]]:
    occurrences: dict[str, list[tuple[Path, int]]] = {pkg: [] for pkg in base_packages}

    if not base_packages:
        return occurrences

    alternation = "|".join(re.escape(pkg) for pkg in sorted(base_packages, key=len, reverse=True))
    token_re = re.compile(rf"(?<![A-Za-z0-9+.-])({alternation})(?![A-Za-z0-9+.-])")

    for path in sorted(debian_dir.rglob("*")):
        if not path.is_file() or not is_probably_text(path):
            continue

        if (debian_dir / "patches") in path.parents:
            continue

        if path in {debian_dir / "changelog", debian_dir / "control-in"}:
            continue

        if should_skip_file(path):
            continue

        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue

        for line_number, line in enumerate(lines, start=1):
            if line.startswith("#") or line.startswith("//") or line.startswith("*"):
                continue

            for match in token_re.finditer(line):
                package = match.group(1)
                occurrences[package].append((path, line_number))

    return occurrences


def print_occurrence_context(lines: list[str], hit_line: int) -> None:
    start = max(1, hit_line - 3)
    end = min(len(lines), hit_line + 3)

    for line_number in range(start, end + 1):
        marker = ">" if line_number == hit_line else " "
        print(f"    {marker} {line_number:5d}: {lines[line_number - 1]}")


def print_occurrences(debian_dir: Path, occurrences: dict[str, list[tuple[Path, int]]]) -> int:
    total = 0

    for package in sorted(occurrences):
        hits = occurrences[package]
        if not hits:
            continue

        print(f"[package] {package} ({len(hits)} hit(s))")

        grouped: dict[Path, list[int]] = {}
        for path, line_number in hits:
            grouped.setdefault(path, []).append(line_number)

        for path in sorted(grouped):
            rel = path.relative_to(debian_dir.parent)
            print(f"  [file] {rel}")

            try:
                lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                print("  [warn] Unable to read file for context")
                continue

            for line_number in sorted(grouped[path]):
                print(f"  - occurrence at line {line_number}")
                print_occurrence_context(lines, line_number)

        total += len(hits)

    if total == 0:
        print("[done] No base package occurrences found")
    else:
        print(f"[done] Found {total} occurrence(s)")

    return 0


def main() -> int:
    scripts_dir = Path(__file__).resolve().parent
    debian_dir = scripts_dir.parent
    control_path = debian_dir / "control"

    if not control_path.exists():
        print(f"[error] control file not found: {control_path}")
        return 1

    base_packages = collect_base_packages(control_path)
    occurrences = find_occurrences(debian_dir, base_packages)
    return print_occurrences(debian_dir, occurrences)


if __name__ == "__main__":
    raise SystemExit(main())
