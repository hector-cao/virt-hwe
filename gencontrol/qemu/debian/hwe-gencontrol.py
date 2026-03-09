#!/usr/bin/env python3
"""Append a -hwe suffix to package names in debian/<pkg>/ files.

For every package returned by dh_listpackages, this script rewrites all
standalone occurrences of "<pkg>" in files under debian/<pkg>/ to
"<pkg>-hwe".
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def log(step: str, message: str) -> None:
    """Print a structured log line."""
    print(f"[hwe-gencontrol] {step}: {message}")


def list_packages(workdir: Path) -> list[str]:
    """Return package names from dh_listpackages."""
    log("packages", f"running dh_listpackages in {workdir}")
    result = subprocess.run(
        ["dh_listpackages"],
        check=True,
        capture_output=True,
        text=True,
        cwd=workdir,
    )
    packages = [pkg for pkg in result.stdout.split() if pkg]
    log("packages", f"dh_listpackages returned {len(packages)} package(s)")
    return packages


def rewrite_package_folder(
    package: str, repo_root: Path, base_packages: list[str]
) -> tuple[bool, str]:
    """Rewrite standalone occurrences in all files under debian/<package>/.

    Returns (changed, message).
    """
    package_dir = repo_root / "debian" / package
    log("package", f"{package}: checking {package_dir}")
    if not package_dir.exists() or not package_dir.is_dir():
        log("package", f"{package}: package directory is missing")
        return False, f"skip {package}: missing {package_dir}"

    replacements_map = [(base, f"{base}-hwe") for base in dict.fromkeys(base_packages)]
    log(
        "package",
        f"{package}: applying {len(replacements_map)} package replacement mapping(s)",
    )

    # Match full Debian package name tokens only.
    # This avoids touching longer names that merely contain package names.
    patterns = [
        (
            src,
            dst,
            re.compile(rf"(?<![a-z0-9+.-]){re.escape(src)}(?![a-z0-9+.-])"),
        )
        for src, dst in replacements_map
    ]
    changed_files = 0
    total_replacements = 0

    for file_path in sorted(package_dir.rglob("*")):
        if not file_path.is_file():
            continue
        if file_path.name in {"md5sums", "conffiles"}:
            log("file", f"{package}: skip metadata file {file_path.relative_to(repo_root)}")
            continue

        rel = file_path.relative_to(repo_root)
        log("file", f"{package}: reading {rel}")
        try:
            content = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            log("file", f"{package}: skip non-text file {rel}")
            continue

        updated = content
        replacements = 0
        for src, dst, pattern in patterns:
            updated, count = pattern.subn(dst, updated)
            if count:
                log("file", f"{package}: replaced {count} occurrence(s) of {src} in {rel}")
                replacements += count

        if replacements == 0:
            log("file", f"{package}: no match in {rel}")
            continue

        file_path.write_text(updated, encoding="utf-8")
        changed_files += 1
        total_replacements += replacements
        log("file", f"{package}: updated {rel} ({replacements} replacement(s))")

    if total_replacements == 0:
        log("package", f"{package}: no standalone occurrences found in any file")
        return False, f"skip {package}: no matching occurrences"

    return (
        True,
        f"updated folder {package} "
        f"({total_replacements} replacements in {changed_files} file(s))",
    )


def main() -> int:
    # Run from qemu/ (parent of debian/) so dh_listpackages sees debian/rules.
    repo_root = Path(__file__).resolve().parent.parent
    log("start", f"repo root resolved to {repo_root}")

    try:
        packages = list_packages(repo_root)
    except subprocess.CalledProcessError as exc:
        print(f"failed to run dh_listpackages: {exc}", file=sys.stderr)
        log("error", "unable to list packages")
        return 1

    if not packages:
        log("done", "no packages returned by dh_listpackages")
        return 0

    log("start", "beginning per-package folder rewrite")
    changed = 0
    for package in packages:
        log("package", f"{package}: begin")
        did_change, message = rewrite_package_folder(package, repo_root, packages)
        log("result", message)
        if did_change:
            changed += 1

    log("done", f"{changed}/{len(packages)} package folders updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
