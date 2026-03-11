#!/usr/bin/env python3

import pathlib
import sys


def parse_control_paragraph(text: str):
    fields = []
    current_name = None
    current_value_lines = []

    for raw_line in text.splitlines():
        if not raw_line.strip():
            continue

        if raw_line[0].isspace():
            if current_name is None:
                raise ValueError("Unexpected continuation line in control file")
            current_value_lines.append(raw_line)
            continue

        if current_name is not None:
            fields.append((current_name, "\n".join(current_value_lines)))

        if ":" not in raw_line:
            raise ValueError(f"Invalid control line: {raw_line}")

        current_name, value = raw_line.split(":", 1)
        current_name = current_name.strip()
        current_value_lines = [value.lstrip()]

    if current_name is not None:
        fields.append((current_name, "\n".join(current_value_lines)))

    return fields


def find_field_index(fields, name: str):
    name_lower = name.lower()
    for idx, (field_name, _) in enumerate(fields):
        if field_name.lower() == name_lower:
            return idx
    return None


def split_relations(value: str):
    if not value.strip():
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def serialize_paragraph(fields):
    return "\n".join(f"{name}: {value}" for name, value in fields) + "\n"


def update_control_file(control_path: pathlib.Path):
    original = control_path.read_text(encoding="utf-8")
    fields = parse_control_paragraph(original)

    package_idx = find_field_index(fields, "Package")
    if package_idx is None:
        raise ValueError(f"No Package field in {control_path}")

    package_name = fields[package_idx][1].strip()

    depends_idx = find_field_index(fields, "Depends")
    if depends_idx is None:
        depends_value = "ubuntu-virt"
        fields.append(("Depends", depends_value))
    else:
        depends_items = split_relations(fields[depends_idx][1])
        if "ubuntu-virt" not in depends_items:
            depends_items.insert(0, "ubuntu-virt")
        fields[depends_idx] = (fields[depends_idx][0], ", ".join(depends_items))

    replaces_idx = find_field_index(fields, "Replaces")
    hwe_pkg = f"{package_name}-hwe"
    if replaces_idx is None:
        fields.append(("Replaces", hwe_pkg))
    else:
        replaces_items = split_relations(fields[replaces_idx][1])
        if hwe_pkg not in replaces_items:
            replaces_items.append(hwe_pkg)
        fields[replaces_idx] = (fields[replaces_idx][0], ", ".join(replaces_items))

    updated = serialize_paragraph(fields)
    if updated != original:
        control_path.write_text(updated, encoding="utf-8")
        return True

    return False


def main():
    root = pathlib.Path("debian")
    control_files = sorted(root.glob("*/DEBIAN/control"))

    changed = 0
    for control_file in control_files:
        if update_control_file(control_file):
            changed += 1

    print(f"hwe-gencontrol: updated {changed} control file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
