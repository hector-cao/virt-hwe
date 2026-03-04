#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---pre}"
PENDING_FILE="${APT_QEMU_PENDING_FILE:-/tmp/apt-qemu-counterparts.pending}"
AUTOFIX_LOG="${APT_QEMU_AUTOFIX_LOG:-/tmp/apt-qemu-counterparts.log}"

debug() {
  echo "[apt-qemu-hook] $*" >&2
}

contains_word() {
  local needle="$1"
  shift
  local item=""
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

is_hwe_pkg() {
  case "$1" in
    *-hwe) return 0 ;;
    *) return 1 ;;
  esac
}

write_sorted_unique() {
  local file_path="$1"
  shift
  mkdir -p "$(dirname "$file_path")"
  if [ "$#" -eq 0 ]; then
    : > "$file_path"
    return 0
  fi
  printf '%s\n' "$@" | awk 'NF' | sort -u > "$file_path"
}

collect_planned_qemu_from_stdin() {
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN

  debug "reading planned package archives from stdin"

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    base="$(basename "$line")"
    case "$base" in
      *.deb)
        pkg="${base%%_*}"
        case "$pkg" in
          qemu*)
            debug "planned qemu package: $pkg"
            echo "$pkg" >> "$tmp_file"
            ;;
        esac
        ;;
    esac
  done

  if [ -s "$tmp_file" ]; then
    debug "planned qemu package list is not empty"
    sort -u "$tmp_file"
  else
    debug "no planned qemu packages found in current transaction"
  fi
}

collect_installed_qemu() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
    | awk '$2 == "installed" && $1 ~ /^qemu[[:alnum:]+.-]*$/ { print $1 }' \
    | sort -u
}

pre_mode() {
  local -a planned_qemu=()
  local -a installed_qemu=()
  local -a missing=()

  mapfile -t planned_qemu < <(collect_planned_qemu_from_stdin)
  debug "pre mode planned_qemu_count=${#planned_qemu[@]}"

  if [ "${APT_QEMU_HOOK_AUTOFIX:-0}" = "1" ]; then
    debug "autofix recursion guard active, clearing pending and exiting pre mode"
    : > "$PENDING_FILE"
    return 0
  fi

  if [ "${#planned_qemu[@]}" -eq 0 ]; then
    debug "no qemu packages planned, clearing pending file"
    : > "$PENDING_FILE"
    return 0
  fi

  mapfile -t installed_qemu < <(collect_installed_qemu)
  debug "installed_qemu_count=${#installed_qemu[@]}"

  local planned_has_base=0
  local planned_has_hwe=0
  local installed_has_base=0
  local installed_has_hwe=0

  local pkg=""

  for pkg in "${planned_qemu[@]}"; do
    if is_hwe_pkg "$pkg"; then
      planned_has_hwe=1
    else
      planned_has_base=1
    fi
  done

  for pkg in "${installed_qemu[@]}"; do
    if is_hwe_pkg "$pkg"; then
      installed_has_hwe=1
    else
      installed_has_base=1
    fi
  done

  local target_variant="none"
  if [ "$planned_has_hwe" -eq 1 ] && [ "$planned_has_base" -eq 0 ] && [ "$installed_has_base" -eq 1 ]; then
    target_variant="hwe"
  elif [ "$planned_has_base" -eq 1 ] && [ "$planned_has_hwe" -eq 0 ] && [ "$installed_has_hwe" -eq 1 ]; then
    target_variant="base"
  fi

  debug "target_variant=$target_variant"

  if [ "$target_variant" = "none" ]; then
    debug "no variant switch detected, clearing pending file"
    : > "$PENDING_FILE"
    return 0
  fi

  for pkg in "${installed_qemu[@]}"; do
    if [ "$target_variant" = "hwe" ]; then
      if is_hwe_pkg "$pkg"; then
        continue
      fi
      counterpart="${pkg}-hwe"
    else
      if ! is_hwe_pkg "$pkg"; then
        continue
      fi
      counterpart="${pkg%-hwe}"
    fi

    if contains_word "$counterpart" "${planned_qemu[@]}"; then
      debug "skip counterpart already planned: $counterpart"
      continue
    fi
    if contains_word "$counterpart" "${installed_qemu[@]}"; then
      debug "skip counterpart already installed: $counterpart"
      continue
    fi
    debug "queue missing counterpart: $counterpart"
    missing+=("$counterpart")
  done

  write_sorted_unique "$PENDING_FILE" "${missing[@]}"
  debug "pending counterparts written to $PENDING_FILE (count=${#missing[@]})"
}

post_mode() {
  if [ "${APT_QEMU_HOOK_AUTOFIX:-0}" = "1" ]; then
    debug "autofix recursion guard active, skipping post mode"
    return 0
  fi

  if [ ! -s "$PENDING_FILE" ]; then
    debug "pending file is empty or absent, nothing to install"
    return 0
  fi

  local -a missing=()
  mapfile -t missing < "$PENDING_FILE"
  : > "$PENDING_FILE"

  if [ "${#missing[@]}" -eq 0 ]; then
    debug "pending file had no entries after read"
    return 0
  fi

  debug "scheduling single apt-get install for counterparts after lock release: ${missing[*]}"
  debug "autofix log: $AUTOFIX_LOG"

  (
    while \
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
      sleep 1
    done

    if DEBIAN_FRONTEND=noninteractive APT_QEMU_HOOK_AUTOFIX=1 \
      apt-get install -y "${missing[@]}"; then
      echo "[apt-qemu-hook] counterpart install succeeded: ${missing[*]}"
      exit 0
    fi

    echo "[apt-qemu-hook] counterpart install failed: ${missing[*]}"
    exit 1
  ) >>"$AUTOFIX_LOG" 2>&1 &
}

case "$MODE" in
  --pre)
    pre_mode
    ;;
  --post)
    post_mode
    ;;
  *)
    echo "Error: unknown mode '$MODE' (use --pre or --post)" >&2
    exit 1
    ;;
esac
