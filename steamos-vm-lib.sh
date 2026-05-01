#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONTAINER_NAME="${CONTAINER_NAME:-steamos-winvm}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-quay.io/toolbx/ubuntu-toolbox:22.04}"
CONTAINER_HOME="${CONTAINER_HOME:-$HOME/.local/share/$CONTAINER_NAME/home}"
VM_ROOT_DIR="${VM_ROOT_DIR:-$HOME/VMs/quickemu}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-sdl}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-4G}"
DISK_SIZE="${DISK_SIZE:-80G}"
VM_WIDTH="${VM_WIDTH:-1280}"
VM_HEIGHT="${VM_HEIGHT:-800}"
INSTALL_DISTROBOX="${INSTALL_DISTROBOX:-0}"
DISTROBOX_ROOTFUL="${DISTROBOX_ROOTFUL:-0}"

log() {
  printf '[steamos-vm] %s\n' "$*"
}

warn() {
  printf '[steamos-vm][warn] %s\n' "$*" >&2
}

die() {
  printf '[steamos-vm][error] %s\n' "$*" >&2
  exit 1
}

quote() {
  printf '%q' "$1"
}

sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' /' '--' \
    | tr -d '()[]' \
    | tr -cs 'a-z0-9._-' '-'
}

install_distrobox_if_requested() {
  if [[ -x "$HOME/.local/bin/distrobox" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if [[ "$INSTALL_DISTROBOX" == "1" ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is required to install distrobox."
    log "Installing or updating distrobox into ~/.local using the upstream installer."
    curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix "$HOME/.local"
    export PATH="$HOME/.local/bin:$PATH"
    command -v distrobox >/dev/null 2>&1 || die "distrobox install finished, but distrobox is still not in PATH. Add ~/.local/bin to PATH and rerun."
    return 0
  fi

  command -v distrobox >/dev/null 2>&1 || die "distrobox command not found. On SteamOS 3.5+ it is usually preinstalled. To try a user-local install, rerun with INSTALL_DISTROBOX=1."
}

check_host() {
  install_distrobox_if_requested

  log "Container: $CONTAINER_NAME ($CONTAINER_IMAGE)"
  log "VM root: $VM_ROOT_DIR"
  log "VM defaults: CPU=$CPU_CORES RAM=$RAM_SIZE disk=$DISK_SIZE display=$DISPLAY_BACKEND"
  log "Distrobox mode: $([[ "$DISTROBOX_ROOTFUL" == "1" ]] && printf 'rootful' || printf 'rootless')"

  if [[ -r /etc/os-release ]] && ! grep -qiE 'steamos|holo' /etc/os-release; then
    warn "This does not look like SteamOS. The scripts can still work on Linux, but the notes are SteamOS-focused."
  fi

  if [[ "$DISTROBOX_ROOTFUL" == "1" ]] && [[ -n "${FLATPAK_ID:-}" || -f /.flatpak-info ]]; then
    die "Rootful distrobox mode needs host sudo, but this terminal appears to be running inside Flatpak ($FLATPAK_ID). Run the script from SteamOS Konsole or another non-Flatpak host terminal."
  fi

  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1 && ! command -v lilipod >/dev/null 2>&1; then
    die "No supported container manager found. Distrobox needs podman, docker, or lilipod."
  fi

  if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm is missing. VM performance will be poor or the guest may not start. Enable CPU virtualization in firmware if available."
  elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    warn "/dev/kvm exists but is not readable/writable by this user. Add the user to the kvm group and log out/reboot."
  else
    log "/dev/kvm is accessible."
  fi

  mkdir -p "$VM_ROOT_DIR"
  local free_kb
  free_kb="$(df -Pk "$VM_ROOT_DIR" | awk 'NR==2 {print $4}')"
  if [[ -n "$free_kb" && "$free_kb" =~ ^[0-9]+$ && "$free_kb" -lt 73400320 ]]; then
    warn "Less than about 70 GiB is free at $VM_ROOT_DIR. Large guests may run out of space."
  fi

  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    warn "No DISPLAY/WAYLAND_DISPLAY found. Run this from SteamOS Desktop Mode for a visible VM window."
  fi
}

container_exists_rootless() {
  distrobox list 2>/dev/null | grep -Fq "$CONTAINER_NAME"
}

container_exists_rootful() {
  distrobox list --root 2>/dev/null | grep -Fq "$CONTAINER_NAME"
}

container_exists() {
  if [[ "$DISTROBOX_ROOTFUL" == "1" ]]; then
    container_exists_rootful
  else
    container_exists_rootless
  fi
}

dbx_create() {
  local root_args=()
  [[ "$DISTROBOX_ROOTFUL" == "1" ]] && root_args+=(--root)
  distrobox create "${root_args[@]}" "$@"
}

dbx_enter() {
  local root_args=()
  [[ "$DISTROBOX_ROOTFUL" == "1" ]] && root_args+=(--root)
  distrobox enter "${root_args[@]}" "$@"
}

container_ready() {
  container_exists && dbx_enter "$CONTAINER_NAME" -- true >/dev/null 2>&1
}

ensure_container_ready() {
  if container_ready; then
    return 0
  fi

  if container_exists; then
    if [[ "$DISTROBOX_ROOTFUL" == "1" ]]; then
      log "Rootful distrobox needs a first interactive enter to finish setup."
      log "When the container shell opens, complete any password prompt, then run 'exit' to continue."
    else
      log "The distrobox needs a first interactive enter to finish setup."
      log "When the container shell opens, wait for the prompt, then run 'exit' to continue."
    fi
    dbx_enter "$CONTAINER_NAME"
  fi

  if [[ "$DISTROBOX_ROOTFUL" == "1" ]]; then
    container_ready || die "Distrobox '$CONTAINER_NAME' is not ready. Execute 'distrobox enter --root $CONTAINER_NAME' once, exit, then rerun the script."
  else
    container_ready || die "Distrobox '$CONTAINER_NAME' is not ready. Execute 'distrobox enter $CONTAINER_NAME' once, exit, then rerun the script."
  fi
}

create_container() {
  check_host

  if container_exists; then
    log "Distrobox '$CONTAINER_NAME' already exists."
    return 0
  fi

  mkdir -p "$CONTAINER_HOME" "$VM_ROOT_DIR"

  local device_flags=""
  local init_packages="software-properties-common ca-certificates curl gnupg lsb-release qemu-system-x86 qemu-utils qemu-system-gui ovmf swtpm-tools genisoimage jq mesa-utils mtools pciutils procps python3 sed socat spice-client-gtk unzip usbutils util-linux uuid-runtime x11-xserver-utils xdg-user-dirs zsync"
  local devices=()
  local dev

  if [[ "$DISTROBOX_ROOTFUL" == "1" ]]; then
    devices=(/dev/kvm /dev/net/tun /dev/vhost-net)
  else
    devices=(/dev/kvm)
  fi

  for dev in "${devices[@]}"; do
    if [[ -e "$dev" ]]; then
      device_flags="${device_flags:+$device_flags }--device $dev"
    fi
  done

  local args=(--name "$CONTAINER_NAME" --image "$CONTAINER_IMAGE" --home "$CONTAINER_HOME" --volume "$VM_ROOT_DIR:$VM_ROOT_DIR:rw" --additional-packages "$init_packages")
  if [[ -n "$device_flags" ]]; then
    args+=(--additional-flags "$device_flags")
  fi

  log "Creating distrobox '$CONTAINER_NAME'. This can take a few minutes on first pull."
  DBX_NON_INTERACTIVE=1 dbx_create "${args[@]}"
}

dbx_bash() {
  ensure_container_ready
  dbx_enter "$CONTAINER_NAME" -- bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; $1"
}

ensure_container_is_ubuntu() {
  ensure_container_ready

  local container_id
  container_id="$(dbx_bash 'source /etc/os-release 2>/dev/null || true; printf "%s:%s\n" "${ID:-unknown}" "${VERSION_ID:-unknown}"')"

  case "$container_id" in
    ubuntu:*)
      ;;
    *)
      die "Distrobox '$CONTAINER_NAME' exists but is not Ubuntu ($container_id). Recreate it with image '$CONTAINER_IMAGE'."
      ;;
  esac

  dbx_bash 'command -v apt-get >/dev/null 2>&1' || die "Distrobox '$CONTAINER_NAME' is Ubuntu, but apt-get is missing. Recreate the container."
}

install_quickemu_userland() {
  log "Installing Quickemu into ~/.local/bin inside the distrobox."
  dbx_bash '
    set -Eeuo pipefail
    mkdir -p "$HOME/.local/bin"
    tag="$(curl -fsSL https://api.github.com/repos/quickemu-project/quickemu/releases/latest | jq -r .tag_name 2>/dev/null || true)"
    if [[ -z "$tag" || "$tag" == "null" ]]; then
      tag="master"
    fi
    for tool in quickemu quickget quickreport; do
      curl -fsSL "https://raw.githubusercontent.com/quickemu-project/quickemu/${tag}/${tool}" -o "$HOME/.local/bin/${tool}"
      chmod +x "$HOME/.local/bin/${tool}"
    done
  '
}

install_quickemu() {
  create_container
  ensure_container_is_ubuntu

  log "Checking Quickemu tooling inside the distrobox."
  if ! dbx_bash 'command -v quickemu >/dev/null 2>&1 && command -v quickget >/dev/null 2>&1'; then
    install_quickemu_userland
    dbx_bash 'command -v quickemu >/dev/null 2>&1 && command -v quickget >/dev/null 2>&1' || die "Quickemu installation inside the distrobox failed."
  fi
}

prompt_select_index() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local choice
  local i=1

  [[ "${#options[@]}" -gt 0 ]] || die "No selectable items available for: $prompt"

  printf '%s\n' "$prompt"
  for choice in "${options[@]}"; do
    printf '  %d. %s\n' "$i" "$choice"
    ((i++))
  done

  while true; do
    printf 'Select number: '
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] || {
      printf 'Invalid selection.\n' >&2
      continue
    }
    if (( choice >= 1 && choice <= ${#options[@]} )); then
      SELECTED_INDEX="$choice"
      return 0
    fi
    printf 'Invalid selection.\n' >&2
  done
}

list_guest_families() {
  dbx_bash "quickget --list-json | jq -r '.[] | [.\"Display Name\", .OS] | @tsv' | sort -u"
}

list_guest_catalog() {
  dbx_bash "quickget --list-json | jq -r '.[] | [.\"Display Name\", .OS, .Release, .Option] | @tsv'"
}

list_guest_releases() {
  local guest_os="$1"
  local q_guest_os
  q_guest_os="$(quote "$guest_os")"
  dbx_bash "quickget --list-json | jq -r --arg os $q_guest_os '.[] | select(.OS == \$os) | .Release' | sort -u"
}

list_guest_options() {
  local guest_os="$1"
  local release="$2"
  local q_guest_os q_release
  q_guest_os="$(quote "$guest_os")"
  q_release="$(quote "$release")"
  dbx_bash "quickget --list-json | jq -r --arg os $q_guest_os --arg release $q_release '.[] | select(.OS == \$os and .Release == \$release and .Option != \"\") | .Option' | sort -u"
}

build_instance_slug() {
  local guest_os="$1"
  local release="$2"
  local option="${3:-}"
  local slug="${guest_os}-${release}"

  if [[ -n "$option" ]]; then
    slug="${slug}-${option}"
  fi

  sanitize_slug "$slug"
  printf '\n'
}

run_quickget_selection() {
  local instance_dir="$1"
  local guest_os="$2"
  local release="$3"
  local option="${4:-}"
  local q_instance_dir q_guest_os q_release q_option

  q_instance_dir="$(quote "$instance_dir")"
  q_guest_os="$(quote "$guest_os")"
  q_release="$(quote "$release")"

  if [[ -n "$option" ]]; then
    q_option="$(quote "$option")"
    dbx_bash "mkdir -p $q_instance_dir && cd $q_instance_dir && quickget $q_guest_os $q_release $q_option"
  else
    dbx_bash "mkdir -p $q_instance_dir && cd $q_instance_dir && quickget $q_guest_os $q_release"
  fi
}

find_vm_config_in_dir() {
  local instance_dir="$1"
  [[ -d "$instance_dir" ]] || return 1
  find "$instance_dir" -maxdepth 1 -type f -name '*.conf' | sort | head -n 1
}

tune_vm_config_file() {
  local vm_conf_path="$1"
  [[ -f "$vm_conf_path" ]] || die "VM config not found: $vm_conf_path"

  local tmp
  tmp="$(mktemp)"
  awk '
    /^# BEGIN steamos-vm defaults$/ {skip=1; next}
    /^# END steamos-vm defaults$/ {skip=0; next}
    skip != 1 {print}
  ' "$vm_conf_path" > "$tmp"
  mv "$tmp" "$vm_conf_path"

  cat >> "$vm_conf_path" <<EOF

# BEGIN steamos-vm defaults
cpu_cores="$CPU_CORES"
ram="$RAM_SIZE"
disk_size="$DISK_SIZE"
width="$VM_WIDTH"
height="$VM_HEIGHT"
# END steamos-vm defaults
EOF

  log "Updated VM defaults in $vm_conf_path"
}

list_vm_configs() {
  [[ -d "$VM_ROOT_DIR" ]] || return 1
  find "$VM_ROOT_DIR" -maxdepth 2 -type f -name '*.conf' | sort
}

run_vm_config() {
  local vm_conf_path="$1"
  [[ -f "$vm_conf_path" ]] || die "VM config not found: $vm_conf_path"

  local vm_dir vm_conf_name q_vm_dir q_vm_conf q_display
  vm_dir="$(dirname "$vm_conf_path")"
  vm_conf_name="$(basename "$vm_conf_path")"
  q_vm_dir="$(quote "$vm_dir")"
  q_vm_conf="$(quote "$vm_conf_name")"
  q_display="$(quote "$DISPLAY_BACKEND")"

  log "Starting VM: ${vm_conf_name%.conf}"
  dbx_bash "cd $q_vm_dir && quickemu --vm $q_vm_conf --display $q_display"
}
