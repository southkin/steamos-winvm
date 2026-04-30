#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONTAINER_NAME="${CONTAINER_NAME:-steamos-winvm}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-quay.io/toolbx/ubuntu-toolbox:22.04}"
CONTAINER_HOME="${CONTAINER_HOME:-$HOME/.local/share/$CONTAINER_NAME/home}"
VM_DIR="${VM_DIR:-$HOME/VMs/quickemu}"
WINDOWS_VERSION="${WINDOWS_VERSION:-11}"
WINDOWS_LANGUAGE="${WINDOWS_LANGUAGE:-}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-sdl}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-4G}"
DISK_SIZE="${DISK_SIZE:-80G}"
VM_WIDTH="${VM_WIDTH:-1280}"
VM_HEIGHT="${VM_HEIGHT:-800}"
INSTALL_DISTROBOX="${INSTALL_DISTROBOX:-0}"
DISTROBOX_ROOTFUL="${DISTROBOX_ROOTFUL:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
VM_CONF_PREFIX="windows-${WINDOWS_VERSION}"

log() {
  printf '[steamos-winvm] %s\n' "$*"
}

warn() {
  printf '[steamos-winvm][warn] %s\n' "$*" >&2
}

die() {
  printf '[steamos-winvm][error] %s\n' "$*" >&2
  exit 1
}

quote() {
  printf '%q' "$1"
}

resolve_vm_conf_path() {
  local default_path="$VM_DIR/$VM_CONF_PREFIX.conf"
  if [[ -f "$default_path" ]]; then
    printf '%s\n' "$default_path"
    return 0
  fi

  local match
  match="$(find "$VM_DIR" -maxdepth 1 -type f -name "$VM_CONF_PREFIX*.conf" | sort | head -n 1)"
  if [[ -n "$match" ]]; then
    printf '%s\n' "$match"
    return 0
  fi

  printf '%s\n' "$default_path"
  return 1
}

resolve_vm_media_dir() {
  local vm_conf_path vm_conf_base
  vm_conf_path="$(resolve_vm_conf_path)"
  vm_conf_base="$(basename "$vm_conf_path" .conf)"
  printf '%s\n' "$VM_DIR/$vm_conf_base"
}

vm_windows_iso_exists() {
  local vm_media_dir
  vm_media_dir="$(resolve_vm_media_dir)"
  find "$vm_media_dir" -maxdepth 1 -type f -iname 'windows*.iso' | grep -q .
}

reset_vm_definition() {
  local vm_conf_path vm_media_dir
  vm_conf_path="$(resolve_vm_conf_path)"
  vm_media_dir="$(resolve_vm_media_dir)"

  if [[ -f "$vm_conf_path" ]]; then
    rm -f "$vm_conf_path"
  fi

  if [[ -d "$vm_media_dir" ]]; then
    rm -rf "$vm_media_dir"
  fi
}

run_quickget() {
  local q_vm_dir q_version q_language
  q_vm_dir="$(quote "$VM_DIR")"
  q_version="$(quote "$WINDOWS_VERSION")"

  mkdir -p "$VM_DIR"
  log "Creating Windows VM config and downloading Windows media with quickget."

  if [[ -n "$WINDOWS_LANGUAGE" ]]; then
    q_language="$(quote "$WINDOWS_LANGUAGE")"
    dbx_bash "mkdir -p $q_vm_dir && cd $q_vm_dir && quickget windows $q_version $q_language"
    if ! vm_windows_iso_exists; then
      warn "Language-specific Windows media for '$WINDOWS_LANGUAGE' did not produce an install ISO. Falling back to Quickemu default language."
      reset_vm_definition
      dbx_bash "mkdir -p $q_vm_dir && cd $q_vm_dir && quickget windows $q_version"
    fi
  else
    dbx_bash "mkdir -p $q_vm_dir && cd $q_vm_dir && quickget windows $q_version"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./setup-winvm-distrobox.sh [command]

Commands:
  all                 Check host, create distrobox, install Quickemu, create Windows VM, create desktop entry
  check               Check host prerequisites and print warnings
  setup               Create/update the distrobox and install Quickemu dependencies
  create              Download/create the Windows VM with quickget
  run                 Run the Windows VM
  desktop             Create a desktop launcher
  recreate            Remove the existing distrobox, then create it again as Ubuntu
  snapshot-create TAG Create a Quickemu snapshot, for example TAG=clean-install
  snapshot-apply TAG  Restore a Quickemu snapshot
  enter               Enter the distrobox shell
  help                Show this help

Common environment variables:
  WINDOWS_VERSION=11                 10 or 11
  WINDOWS_LANGUAGE=Korean            Passed to quickget; set empty to use Quickemu default
  VM_DIR=$HOME/VMs/quickemu          Where VM files are stored
  DISPLAY_BACKEND=sdl                sdl, gtk, spice, spice-app, none
  CPU_CORES=4 RAM_SIZE=4G DISK_SIZE=80G
  INSTALL_DISTROBOX=1                Install distrobox into ~/.local if missing
  DISTROBOX_ROOTFUL=1                Optional rootful distrobox mode; rootless is the default

Examples:
  ./setup-winvm-distrobox.sh all
  DISPLAY_BACKEND=spice ./setup-winvm-distrobox.sh run
  ./setup-winvm-distrobox.sh snapshot-create clean-install
EOF
}

validate_config() {
  case "$WINDOWS_VERSION" in
    10|11) ;;
    *) die "WINDOWS_VERSION must be 10 or 11." ;;
  esac
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
  validate_config
  install_distrobox_if_requested

  log "Container: $CONTAINER_NAME ($CONTAINER_IMAGE)"
  log "VM directory: $VM_DIR"
  log "Windows target: Windows $WINDOWS_VERSION, language: ${WINDOWS_LANGUAGE:-Quickemu default}"
  log "VM defaults: CPU=$CPU_CORES RAM=$RAM_SIZE disk=$DISK_SIZE display=$DISPLAY_BACKEND"
  log "Distrobox mode: $([[ "$DISTROBOX_ROOTFUL" == "1" ]] && printf 'rootful' || printf 'rootless')"

  if [[ -r /etc/os-release ]] && ! grep -qiE 'steamos|holo' /etc/os-release; then
    warn "This does not look like SteamOS. The script can still work on Linux, but the notes are SteamOS-focused."
  fi

  if [[ "$DISTROBOX_ROOTFUL" == "1" ]] && [[ -n "${FLATPAK_ID:-}" || -f /.flatpak-info ]]; then
    die "Rootful distrobox mode needs host sudo, but this terminal appears to be running inside Flatpak ($FLATPAK_ID). Run the script from SteamOS Konsole or another non-Flatpak host terminal."
  fi

  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1 && ! command -v lilipod >/dev/null 2>&1; then
    die "No supported container manager found. Distrobox needs podman, docker, or lilipod."
  fi

  if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm is missing. Windows will be extremely slow or may not start. Enable CPU virtualization in firmware if available."
  elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    warn "/dev/kvm exists but is not readable/writable by this user. Add the user to the kvm group and log out/reboot."
  else
    log "/dev/kvm is accessible."
  fi

  mkdir -p "$VM_DIR"
  local free_kb
  free_kb="$(df -Pk "$VM_DIR" | awk 'NR==2 {print $4}')"
  if [[ -n "$free_kb" && "$free_kb" =~ ^[0-9]+$ && "$free_kb" -lt 73400320 ]]; then
    warn "Less than about 70 GiB is free at $VM_DIR. Windows plus security modules can consume a lot of space."
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

dbx_rm() {
  local root_args=()
  [[ "$DISTROBOX_ROOTFUL" == "1" ]] && root_args+=(--root)
  distrobox rm "${root_args[@]}" "$@"
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
  log "Checking whether distrobox '$CONTAINER_NAME' already exists."

  if container_exists; then
    log "Distrobox '$CONTAINER_NAME' already exists."
    return 0
  fi

  if [[ "$DISTROBOX_ROOTFUL" == "1" ]] && container_exists_rootless; then
    die "A rootless distrobox named '$CONTAINER_NAME' already exists. Run './setup-winvm-distrobox.sh recreate' to rebuild it in rootful mode."
  fi

  if [[ "$DISTROBOX_ROOTFUL" != "1" ]] && container_exists_rootful; then
    die "A rootful distrobox named '$CONTAINER_NAME' already exists. Run './setup-winvm-distrobox.sh recreate' to rebuild it in rootless mode."
  fi

  mkdir -p "$CONTAINER_HOME" "$VM_DIR"

  local device_flags=""
  local init_packages="software-properties-common ca-certificates curl gnupg lsb-release qemu-system-x86 qemu-utils qemu-system-gui ovmf swtpm-tools genisoimage jq mesa-utils mtools pciutils procps python3 sed socat spice-client-gtk unzip usbutils util-linux uuid-runtime x11-xserver-utils xdg-user-dirs zsync"
  local init_hooks='apt-add-repository -y universe || true; apt-add-repository -y ppa:flexiondotorg/quickemu; apt-get update; apt-get install -y quickemu'
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

  local args=(--name "$CONTAINER_NAME" --image "$CONTAINER_IMAGE" --home "$CONTAINER_HOME" --volume "$VM_DIR:$VM_DIR:rw" --additional-packages "$init_packages" --init-hooks "$init_hooks")
  if [[ -n "$device_flags" ]]; then
    args+=(--additional-flags "$device_flags")
  fi

  log "Creating distrobox '$CONTAINER_NAME'. This can take a few minutes on first pull."
  DBX_NON_INTERACTIVE=1 dbx_create "${args[@]}"
}

dbx_bash() {
  ensure_container_ready
  dbx_enter "$CONTAINER_NAME" -- bash -lc "$1"
}

ensure_container_is_ubuntu() {
  ensure_container_ready

  local container_id
  container_id="$(dbx_bash 'source /etc/os-release 2>/dev/null || true; printf "%s:%s\n" "${ID:-unknown}" "${VERSION_ID:-unknown}"')"

  case "$container_id" in
    ubuntu:*)
      ;;
    *)
      die "Distrobox '$CONTAINER_NAME' exists but is not Ubuntu ($container_id). Remove it with 'distrobox rm $CONTAINER_NAME' or run './setup-winvm-distrobox.sh recreate'."
      ;;
  esac

  dbx_bash 'command -v apt-get >/dev/null 2>&1' || die "Distrobox '$CONTAINER_NAME' is Ubuntu, but apt-get is missing. Recreate the container with './setup-winvm-distrobox.sh recreate'."
}

install_quickemu() {
  create_container
  ensure_container_is_ubuntu

  log "Checking Quickemu tooling inside the distrobox."
  dbx_bash 'command -v quickemu >/dev/null 2>&1 && command -v quickget >/dev/null 2>&1' || die "Quickemu is missing from the distrobox. Run './setup-winvm-distrobox.sh recreate' to rebuild the container."
  dbx_bash 'quickemu --version || true; quickget --version || true'
}

tune_vm_config() {
  local vm_conf_path
  vm_conf_path="$(resolve_vm_conf_path)"
  [[ -f "$vm_conf_path" ]] || die "VM config not found: $vm_conf_path"

  local tmp
  tmp="$(mktemp)"
  awk '
    /^# BEGIN steamos-winvm defaults$/ {skip=1; next}
    /^# END steamos-winvm defaults$/ {skip=0; next}
    skip != 1 {print}
  ' "$vm_conf_path" > "$tmp"
  mv "$tmp" "$vm_conf_path"

  cat >> "$vm_conf_path" <<EOF

# BEGIN steamos-winvm defaults
cpu_cores="$CPU_CORES"
ram="$RAM_SIZE"
disk_size="$DISK_SIZE"
width="$VM_WIDTH"
height="$VM_HEIGHT"
# END steamos-winvm defaults
EOF

  log "Updated VM defaults in $vm_conf_path"
}

create_windows_vm() {
  install_quickemu

  local vm_conf_path
  vm_conf_path="$(resolve_vm_conf_path)"
  if [[ -f "$vm_conf_path" ]]; then
    log "VM config already exists: $vm_conf_path"
    if ! vm_windows_iso_exists; then
      warn "Windows install ISO is missing for the existing VM. Removing incomplete media and regenerating with quickget."
      reset_vm_definition
      run_quickget
      vm_conf_path="$(resolve_vm_conf_path)"
    fi
    tune_vm_config
    return 0
  fi

  run_quickget
  tune_vm_config
}

run_vm() {
  local vm_conf_path vm_conf_name
  vm_conf_path="$(resolve_vm_conf_path)"

  if [[ ! -f "$vm_conf_path" ]]; then
    warn "VM config does not exist yet; creating it first."
    create_windows_vm
    vm_conf_path="$(resolve_vm_conf_path)"
  fi

  local q_vm_dir q_conf q_display
  q_vm_dir="$(quote "$VM_DIR")"
  vm_conf_name="$(basename "$vm_conf_path")"
  q_conf="$(quote "$vm_conf_name")"
  q_display="$(quote "$DISPLAY_BACKEND")"

  log "Starting Windows VM. Close Windows normally before closing the VM window."
  dbx_bash "cd $q_vm_dir && quickemu --vm $q_conf --display $q_display"
}

create_desktop_entry() {
  check_host
  chmod +x "$SCRIPT_PATH"

  local app_dir="$HOME/.local/share/applications"
  local desktop_file="$app_dir/steamos-winvm.desktop"
  mkdir -p "$app_dir"

  cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Windows VM (Distrobox)
Comment=Run the Quickemu Windows VM prepared for SteamOS
Exec=$SCRIPT_PATH run
Terminal=false
Categories=System;Emulator;
EOF

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$app_dir" >/dev/null 2>&1 || true
  fi

  log "Created desktop launcher: $desktop_file"
}

snapshot_create() {
  local tag="${1:-}"
  [[ -n "$tag" ]] || die "snapshot-create needs a tag, for example: snapshot-create clean-install"
  local vm_conf_path
  vm_conf_path="$(resolve_vm_conf_path)"
  [[ -f "$vm_conf_path" ]] || die "VM config not found: $vm_conf_path"

  local q_vm_dir q_conf q_tag
  q_vm_dir="$(quote "$VM_DIR")"
  q_conf="$(quote "$(basename "$vm_conf_path")")"
  q_tag="$(quote "$tag")"

  dbx_bash "cd $q_vm_dir && quickemu --vm $q_conf --snapshot create $q_tag"
}

snapshot_apply() {
  local tag="${1:-}"
  [[ -n "$tag" ]] || die "snapshot-apply needs a tag, for example: snapshot-apply clean-install"
  local vm_conf_path
  vm_conf_path="$(resolve_vm_conf_path)"
  [[ -f "$vm_conf_path" ]] || die "VM config not found: $vm_conf_path"

  local q_vm_dir q_conf q_tag
  q_vm_dir="$(quote "$VM_DIR")"
  q_conf="$(quote "$(basename "$vm_conf_path")")"
  q_tag="$(quote "$tag")"

  dbx_bash "cd $q_vm_dir && quickemu --vm $q_conf --snapshot apply $q_tag"
}

enter_container() {
  create_container
  dbx_enter "$CONTAINER_NAME"
}

remove_container_variants() {
  if container_exists_rootless; then
    warn "Removing existing rootless distrobox '$CONTAINER_NAME'."
    distrobox rm --force "$CONTAINER_NAME"
  fi

  if container_exists_rootful; then
    warn "Removing existing rootful distrobox '$CONTAINER_NAME'."
    distrobox rm --root --force "$CONTAINER_NAME"
  fi
}

recreate_container() {
  check_host
  remove_container_variants
  create_container
}

cmd="${1:-all}"
shift || true

case "$cmd" in
  all)
    create_windows_vm
    create_desktop_entry
    log "Done. Run './setup-winvm-distrobox.sh run' to install/start Windows."
    ;;
  check)
    check_host
    ;;
  setup)
    install_quickemu
    ;;
  create)
    create_windows_vm
    ;;
  run)
    run_vm
    ;;
  desktop)
    create_desktop_entry
    ;;
  recreate)
    recreate_container
    ;;
  snapshot-create)
    snapshot_create "${1:-}"
    ;;
  snapshot-apply)
    snapshot_apply "${1:-}"
    ;;
  enter)
    enter_container
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $cmd"
    ;;
esac
