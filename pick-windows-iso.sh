#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/setup-winvm-distrobox.sh"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Downloads}"
RUN_AFTER_IMPORT="${RUN_AFTER_IMPORT:-0}"

die() {
  printf '[pick-windows-iso][error] %s\n' "$*" >&2
  exit 1
}

[[ -x "$MAIN_SCRIPT" ]] || die "Main script not found or not executable: $MAIN_SCRIPT"
[[ -d "$DOWNLOADS_DIR" ]] || die "Downloads directory not found: $DOWNLOADS_DIR"

mapfile -d '' ISO_FILES < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f \( -iname '*.iso' -o -iname '*.ISO' \) -print0 | sort -z)

if [[ "${#ISO_FILES[@]}" -eq 0 ]]; then
  die "No ISO files found in $DOWNLOADS_DIR"
fi

printf 'ISO files in %s:\n' "$DOWNLOADS_DIR"
PS3=$'Select an ISO number and press Enter: '

select ISO_PATH in "${ISO_FILES[@]}"; do
  [[ -n "${ISO_PATH:-}" ]] || {
    printf 'Invalid selection.\n' >&2
    continue
  }

  "$MAIN_SCRIPT" import-iso "$ISO_PATH"

  if [[ "$RUN_AFTER_IMPORT" == "1" ]]; then
    "$MAIN_SCRIPT" run
  else
    printf '[pick-windows-iso] Imported %s\n' "$ISO_PATH"
    printf '[pick-windows-iso] Next: %s run\n' "$MAIN_SCRIPT"
  fi
  break
done
