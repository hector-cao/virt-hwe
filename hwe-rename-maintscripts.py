#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
from pathlib import Path

PACKAGE_RE = re.compile(r"^Package:\s*(\S+)\s*$")
SKIP_PACKAGE_PREFIX = "ubuntu-virt"


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


def find_rename_pairs(debian_dir: Path, base_packages: list[str]) -> list[tuple[Path, Path]]:
    pairs: list[tuple[Path, Path]] = []

    for package in base_packages:
        hwe_package = f"{package}-hwe"

        for source_path in sorted(debian_dir.glob(f"{package}.*")):
            if not source_path.is_file():
                continue

            suffix = source_path.name[len(package) :]
            target_path = debian_dir / f"{hwe_package}{suffix}"

            if target_path.exists():
                continue

            pairs.append((source_path, target_path))

    return pairs


def git_mv_pairs(rename_pairs: list[tuple[Path, Path]], debian_dir: Path) -> int:
    if not rename_pairs:
        print("[done] No files to rename")
        return 0

    for source_path, target_path in rename_pairs:
        print(f"[rename] {source_path.name} -> {target_path.name}")

        subprocess.run(
            ["git", "mv", "--", str(source_path), str(target_path)],
            cwd=debian_dir,
            check=True,
        )

    print(f"[done] Renamed {len(rename_pairs)} file(s)")

    return 0


def main() -> int:
    debian_dir = Path(__file__).resolve().parent
    control_path = debian_dir / "control"

    if not control_path.exists():
        print(f"[error] control file not found: {control_path}")
        return 1

    if not debian_dir.is_dir():
        print(f"[error] debian directory not found: {debian_dir}")
        return 1

    base_packages = collect_base_packages(control_path)
    rename_pairs = find_rename_pairs(debian_dir, base_packages)

    return git_mv_pairs(rename_pairs, debian_dir)


if __name__ == "__main__":
    raise SystemExit(main())
