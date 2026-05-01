#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./steamos-vm-lib.sh
source "$SCRIPT_DIR/steamos-vm-lib.sh"

install_quickemu

log "Loading downloadable OS catalog."
mapfile -t CATALOG_LINES < <(list_guest_catalog)
[[ "${#CATALOG_LINES[@]}" -gt 0 ]] || die "quickget did not return any downloadable guest systems."

declare -A SEEN_FAMILIES=()
declare -a FAMILY_LINES=()
declare -a FAMILY_LABELS=()
for line in "${CATALOG_LINES[@]}"; do
  IFS=$'\t' read -r display_name guest_os release option <<< "$line"
  family_key="${display_name}"$'\t'"${guest_os}"
  [[ -n "${SEEN_FAMILIES[$family_key]:-}" ]] && continue
  SEEN_FAMILIES["$family_key"]=1
  FAMILY_LINES+=("$family_key")
  FAMILY_LABELS+=("$display_name [$guest_os]")
done

prompt_select_index "Choose a guest OS family to download:" "${FAMILY_LABELS[@]}"
FAMILY_LINE="${FAMILY_LINES[$((SELECTED_INDEX - 1))]}"
IFS=$'\t' read -r DISPLAY_NAME GUEST_OS <<< "$FAMILY_LINE"

log "Loading releases for $DISPLAY_NAME."
declare -A SEEN_RELEASES=()
declare -a RELEASES=()
for line in "${CATALOG_LINES[@]}"; do
  IFS=$'\t' read -r display_name guest_os release option <<< "$line"
  [[ "$guest_os" == "$GUEST_OS" ]] || continue
  [[ -n "${SEEN_RELEASES[$release]:-}" ]] && continue
  SEEN_RELEASES["$release"]=1
  RELEASES+=("$release")
done
[[ "${#RELEASES[@]}" -gt 0 ]] || die "No releases found for $GUEST_OS."
prompt_select_index "Choose a release for $DISPLAY_NAME:" "${RELEASES[@]}"
RELEASE="${RELEASES[$((SELECTED_INDEX - 1))]}"

OPTION=""
log "Loading options for $DISPLAY_NAME $RELEASE."
declare -A SEEN_OPTIONS=()
declare -a OPTIONS=()
for line in "${CATALOG_LINES[@]}"; do
  IFS=$'\t' read -r display_name guest_os release option <<< "$line"
  [[ "$guest_os" == "$GUEST_OS" ]] || continue
  [[ "$release" == "$RELEASE" ]] || continue
  [[ -n "$option" ]] || continue
  [[ -n "${SEEN_OPTIONS[$option]:-}" ]] && continue
  SEEN_OPTIONS["$option"]=1
  OPTIONS+=("$option")
done
if [[ "${#OPTIONS[@]}" -gt 0 ]]; then
  prompt_select_index "Choose an option for $DISPLAY_NAME $RELEASE:" "${OPTIONS[@]}"
  OPTION="${OPTIONS[$((SELECTED_INDEX - 1))]}"
fi

INSTANCE_SLUG="$(build_instance_slug "$GUEST_OS" "$RELEASE" "$OPTION")"
INSTANCE_DIR="$VM_ROOT_DIR/$INSTANCE_SLUG"

if EXISTING_CONF="$(find_vm_config_in_dir "$INSTANCE_DIR")" && [[ -n "$EXISTING_CONF" ]]; then
  warn "VM already exists: $EXISTING_CONF"
  tune_vm_config_file "$EXISTING_CONF"
  log "Run '$SCRIPT_DIR/run-vm-distrobox.sh' to start it."
  exit 0
fi

mkdir -p "$INSTANCE_DIR"

if [[ -n "$OPTION" ]]; then
  log "Creating VM: $DISPLAY_NAME / $RELEASE / $OPTION"
else
  log "Creating VM: $DISPLAY_NAME / $RELEASE"
fi

run_quickget_selection "$INSTANCE_DIR" "$GUEST_OS" "$RELEASE" "$OPTION"

VM_CONF_PATH="$(find_vm_config_in_dir "$INSTANCE_DIR")"
[[ -n "$VM_CONF_PATH" ]] || die "quickget finished, but no VM config was created in $INSTANCE_DIR"

tune_vm_config_file "$VM_CONF_PATH"
log "Created VM config: $VM_CONF_PATH"
log "Next: $SCRIPT_DIR/run-vm-distrobox.sh"
