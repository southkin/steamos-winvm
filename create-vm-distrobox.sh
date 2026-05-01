#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./steamos-vm-lib.sh
source "$SCRIPT_DIR/steamos-vm-lib.sh"

CATALOG_CONTAINER_NAME="${CATALOG_CONTAINER_NAME:-steamos-winvm-catalog}"

pick_file_from_list() {
  local prompt="$1"
  shift
  local -a files=("$@")
  local -a labels=()
  local path

  [[ "${#files[@]}" -gt 0 ]] || die "No files available for: $prompt"

  for path in "${files[@]}"; do
    labels+=("$(basename "$path")")
  done

  prompt_select_index "$prompt" "${labels[@]}"
  SELECTED_FILE="${files[$((SELECTED_INDEX - 1))]}"
}

find_windows_iso_candidates() {
  find "$HOME/Downloads" -maxdepth 1 -type f \( -iname '*windows*.iso' -o -iname 'win*.iso' \) ! -iname 'virtio-win*.iso' | sort
}

find_virtio_iso_candidates() {
  find "$HOME/Downloads" -maxdepth 1 -type f -iname 'virtio-win*.iso' | sort
}

create_manual_windows_config() {
  local instance_dir="$1"
  local release="$2"
  local windows_iso_name="$3"
  local virtio_iso_name="$4"
  local vm_conf_path quickemu_path

  quickemu_path="$(quickemu_path_in_container)"
  vm_conf_path="$instance_dir/$(basename "$instance_dir").conf"

  cat > "$vm_conf_path" <<EOF
#!$quickemu_path --vm
guest_os="windows"
disk_img="$instance_dir/disk.qcow2"
iso="$instance_dir/$windows_iso_name"
fixed_iso="$instance_dir/$virtio_iso_name"
EOF

  chmod u+x "$vm_conf_path"
}

handle_windows_manual_fallback() {
  local instance_dir="$1"
  local release="$2"
  local windows_target="windows-$release.iso"
  local virtio_target="virtio-win.iso"
  local existing_windows_iso existing_virtio_iso
  local -a windows_candidates=()
  local -a virtio_candidates=()

  warn "Automatic Windows download failed. Falling back to manually downloaded ISOs in ~/Downloads."

  existing_windows_iso="$(find "$instance_dir" -maxdepth 1 -type f \( -iname '*windows*.iso' -o -iname 'win*.iso' \) ! -iname 'virtio-win*.iso' | sort | head -n 1)"
  if [[ -n "$existing_windows_iso" ]]; then
    windows_target="$(basename "$existing_windows_iso")"
  else
    mapfile -t windows_candidates < <(find_windows_iso_candidates)
    [[ "${#windows_candidates[@]}" -gt 0 ]] || die "No Windows ISO found in ~/Downloads. Download it in a browser, then rerun."
    pick_file_from_list "Choose a manually downloaded Windows ISO:" "${windows_candidates[@]}"
    cp -f "$SELECTED_FILE" "$instance_dir/$windows_target"
  fi

  existing_virtio_iso="$(find "$instance_dir" -maxdepth 1 -type f -iname 'virtio-win*.iso' | sort | head -n 1)"
  if [[ -n "$existing_virtio_iso" ]]; then
    virtio_target="$(basename "$existing_virtio_iso")"
  else
    mapfile -t virtio_candidates < <(find_virtio_iso_candidates)
    [[ "${#virtio_candidates[@]}" -gt 0 ]] || die "No virtio-win ISO found in ~/Downloads. Download it manually, then rerun."
    pick_file_from_list "Choose a manually downloaded VirtIO ISO:" "${virtio_candidates[@]}"
    cp -f "$SELECTED_FILE" "$instance_dir/$virtio_target"
  fi

  create_manual_windows_config "$instance_dir" "$release" "$windows_target" "$virtio_target"
}

set_container_context "$CATALOG_CONTAINER_NAME"
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
INSTANCE_CONTAINER_NAME="$(build_container_name "$INSTANCE_SLUG")"

set_container_context "$INSTANCE_CONTAINER_NAME"
install_quickemu

if EXISTING_CONF="$(find_vm_config_in_dir "$INSTANCE_DIR")" && [[ -n "$EXISTING_CONF" ]]; then
  warn "VM already exists: $EXISTING_CONF"
  tune_vm_config_file "$EXISTING_CONF"
  write_vm_metadata "$INSTANCE_DIR" "$EXISTING_CONF" "$DISPLAY_NAME" "$GUEST_OS" "$RELEASE" "$OPTION"
  log "Run '$SCRIPT_DIR/run-vm-distrobox.sh' to start it."
  exit 0
fi

mkdir -p "$INSTANCE_DIR"

if [[ -n "$OPTION" ]]; then
  log "Creating VM: $DISPLAY_NAME / $RELEASE / $OPTION"
else
  log "Creating VM: $DISPLAY_NAME / $RELEASE"
fi

if ! run_quickget_selection "$INSTANCE_DIR" "$GUEST_OS" "$RELEASE" "$OPTION"; then
  if [[ "$GUEST_OS" == "windows" ]]; then
    handle_windows_manual_fallback "$INSTANCE_DIR" "$RELEASE"
  else
    die "quickget failed while creating $INSTANCE_SLUG"
  fi
fi

VM_CONF_PATH="$(find_vm_config_in_dir "$INSTANCE_DIR")"
[[ -n "$VM_CONF_PATH" ]] || die "No VM config was created in $INSTANCE_DIR"

tune_vm_config_file "$VM_CONF_PATH"
write_vm_metadata "$INSTANCE_DIR" "$VM_CONF_PATH" "$DISPLAY_NAME" "$GUEST_OS" "$RELEASE" "$OPTION"
log "Created VM config: $VM_CONF_PATH"
log "Container: $INSTANCE_CONTAINER_NAME"
log "Next: $SCRIPT_DIR/run-vm-distrobox.sh"
