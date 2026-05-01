#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./steamos-vm-lib.sh
source "$SCRIPT_DIR/steamos-vm-lib.sh"

install_quickemu

mapfile -t VM_CONFIGS < <(list_vm_configs)
[[ "${#VM_CONFIGS[@]}" -gt 0 ]] || die "No VM configs were found under $VM_ROOT_DIR. Run '$SCRIPT_DIR/create-vm-distrobox.sh' first."

declare -a VM_LABELS=()
for vm_conf_path in "${VM_CONFIGS[@]}"; do
  VM_LABELS+=("$(basename "${vm_conf_path%.conf}")")
done

prompt_select_index "Choose a VM to run:" "${VM_LABELS[@]}"
VM_CONF_PATH="${VM_CONFIGS[$((SELECTED_INDEX - 1))]}"

run_vm_config "$VM_CONF_PATH"
