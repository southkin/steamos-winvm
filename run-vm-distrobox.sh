#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./steamos-vm-lib.sh
source "$SCRIPT_DIR/steamos-vm-lib.sh"

declare -a ENTRY_LABELS=()
declare -a ENTRY_METADATA=()

mapfile -t METADATA_FILES < <(list_vm_metadata_files)
for metadata_path in "${METADATA_FILES[@]}"; do
  unset container_name vm_conf_path display_name guest_os release option
  # shellcheck source=/dev/null
  source "$metadata_path"
  [[ -n "${vm_conf_path:-}" && -f "$vm_conf_path" ]] || continue
  label="$(basename "${vm_conf_path%.conf}")"
  ENTRY_LABELS+=("$label [$container_name]")
  ENTRY_METADATA+=("$metadata_path")
done

if [[ "${#ENTRY_METADATA[@]}" -eq 0 ]]; then
  mapfile -t VM_CONFIGS < <(list_vm_configs)
  [[ "${#VM_CONFIGS[@]}" -gt 0 ]] || die "No VM configs were found under $VM_ROOT_DIR. Run '$SCRIPT_DIR/create-vm-distrobox.sh' first."
  for vm_conf_path in "${VM_CONFIGS[@]}"; do
    ENTRY_LABELS+=("$(basename "${vm_conf_path%.conf}") [steamos-winvm]")
    ENTRY_METADATA+=("$vm_conf_path")
  done
fi

prompt_select_index "Choose a VM to run:" "${ENTRY_LABELS[@]}"
SELECTED_ENTRY="${ENTRY_METADATA[$((SELECTED_INDEX - 1))]}"

if [[ "$SELECTED_ENTRY" == *.env ]]; then
  unset container_name vm_conf_path display_name guest_os release option
  # shellcheck source=/dev/null
  source "$SELECTED_ENTRY"
  set_container_context "${container_name:-steamos-winvm}"
  install_quickemu
  run_vm_config "$vm_conf_path"
else
  set_container_context "steamos-winvm"
  install_quickemu
  run_vm_config "$SELECTED_ENTRY"
fi
