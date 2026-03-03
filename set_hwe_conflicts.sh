#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-./extracted}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--root-dir DIR] [--dry-run]

Set Conflicts and Replaces in extracted Debian control files for package pairs:
  - package       conflicts/replaces package-hwe
  - package-hwe   conflicts/replaces package

The script updates files under:
  <root-dir>/<package>/<arch>/control/control

Options:
  --root-dir DIR  Root extraction directory (default: ./extracted)
  --dry-run       Show planned changes without writing files
  -h, --help      Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root-dir)
      ROOT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$ROOT_DIR" ]; then
  echo "Error: root directory not found: $ROOT_DIR" >&2
  exit 1
fi

updated=0
scanned=0

update_fields() {
  local file_path="$1"
  local counterpart="$2"
  local temp_file

  temp_file="$(mktemp)"

  awk -v counterpart="${counterpart}" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function has_item(list, item,    n, i, parts) {
      if (trim(list) == "") {
        return 0
      }
      n = split(list, parts, ",")
      for (i = 1; i <= n; i++) {
        if (trim(parts[i]) == item) {
          return 1
        }
      }
      return 0
    }
    function append_item(list, item) {
      list = trim(list)
      if (list == "") {
        return item
      }
      if (has_item(list, item)) {
        return list
      }
      return list ", " item
    }
    {
      lines[NR] = $0
    }
    END {
      found_conflicts = 0
      found_replaces = 0

      for (i = 1; i <= NR; i++) {
        line = lines[i]

        if (line ~ /^Conflicts:[[:space:]]*/) {
          value = substr(line, index(line, ":") + 1)
          while (i + 1 <= NR && lines[i + 1] ~ /^[[:space:]]/) {
            i++
            value = value " " trim(lines[i])
          }
          value = append_item(value, counterpart)
          print "Conflicts: " value
          found_conflicts = 1
          continue
        }

        if (line ~ /^Replaces:[[:space:]]*/) {
          value = substr(line, index(line, ":") + 1)
          while (i + 1 <= NR && lines[i + 1] ~ /^[[:space:]]/) {
            i++
            value = value " " trim(lines[i])
          }
          value = append_item(value, counterpart)
          print "Replaces: " value
          found_replaces = 1
          continue
        }

        if (line ~ /^Section:[[:space:]]*/) {
          if (!found_conflicts) {
            print "Conflicts: " counterpart
            found_conflicts = 1
          }
          if (!found_replaces) {
            print "Replaces: " counterpart
            found_replaces = 1
          }
        }

        print line
      }

      if (!found_conflicts) {
        print "Conflicts: " counterpart
      }
      if (!found_replaces) {
        print "Replaces: " counterpart
      }
    }
  ' "$file_path" > "$temp_file"

  if cmp -s "$file_path" "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    rm -f "$temp_file"
    echo "Would update: $file_path -> Conflicts/Replaces: $counterpart"
    return 0
  fi

  mv "$temp_file" "$file_path"
  echo "Updated: $file_path -> Conflicts/Replaces: $counterpart"
  return 0
}

while IFS= read -r -d '' control_file; do
  scanned=$((scanned + 1))

  package_name="$(basename "$(dirname "$(dirname "$(dirname "$control_file")")")")"
  if [[ "$package_name" == *-hwe ]]; then
    counterpart="${package_name%-hwe}"
  else
    counterpart="${package_name}-hwe"
  fi

  if update_fields "$control_file" "$counterpart"; then
    updated=$((updated + 1))
  fi
done < <(find "$ROOT_DIR" -type f -path "$ROOT_DIR/*/*/control/control" -print0)

echo "Scanned control files: $scanned"
echo "Updated control files: $updated"
