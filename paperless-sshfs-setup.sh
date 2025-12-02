#!/usr/bin/env bash
# paperless-sshfs-setup.sh
# SSHFS setup for Paperless NGX in a Proxmox LXC
# tested with Debian-based containers

set -Eeuo pipefail

trap 'catch $LINENO "$BASH_COMMAND"' SIGINT SIGTERM ERR

# --- Logging / colors ---

CLR='' GREEN='' CYAN='' YELLOW='' RED=''

setup_colours() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    CLR='\033[0m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
  fi
}
setup_colours

msg_info() {
  echo -e "${CYAN}${1-}${CLR}"
}

msg_ok() {
  echo -e "${GREEN}${1-}${CLR}"
}

msg_warn() {
  echo -e "${YELLOW}${1-}${CLR}"
}

msg_err() {
  echo -e "${RED}${1-}${CLR}" >&2
}

die() {
  local err="$1"
  local code="${2-1}"
  msg_err "$err"
  exit "$code"
}

catch() {
  local code=$?
  local line="$1"
  local command="$2"
  msg_err "Error in line $line (exit code $code) while executing: $command"
  exit "$code"
}

# --- Input helper ---

get_input() {
  local prompt="$1"
  local default="$2"
  local user_input

  read -rp "$prompt (default: $default): " user_input
  if [[ -z "$user_input" ]]; then
    user_input="$default"
  fi
  echo "$user_input"
}

# --- Default config for Paperless ---

# REMOTE_PATH: path on the SSH host where Paperless data should be stored
# LOCAL_MOUNT: mountpoint in the LXC (written to /etc/fstab)
# SSH_KEY_PATH: private SSH key inside the container (created if missing)

declare -g -A CONFIG=(
  [REMOTE_USER]="paperless"
  [REMOTE_HOST]="192.168.1.10"
  [REMOTE_PATH]="/srv/paperless_data"
  [LOCAL_MOUNT]="/mnt/paperless_data"
  [SSH_KEY_PATH]="/root/.ssh/id_rsa_paperless_share"
)

# Paperless subfolders (under LOCAL_MOUNT)
PAPERLESS_CONSUME="consume"
PAPERLESS_DATA="data"
PAPERLESS_MEDIA="media"
PAPERLESS_TRASH="trash"

# --- Main function ---

setup_sshfs_for_paperless() {
  # 0) Root and OS check
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root."
  fi

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
      die "This script is intended for Debian-based containers. Detected: $NAME"
    fi
  else
    die "Unable to read /etc/os-release – OS detection failed."
  fi

  # 1) FUSE check (Proxmox: Container → Options → Features → fuse)
  msg_info "Checking FUSE support (Proxmox LXC feature 'fuse')."
  fuse_enabled=$(get_input "Is FUSE enabled in the container? (y/n)" "y")
  if [[ "$fuse_enabled" != "y" && "$fuse_enabled" != "Y" ]]; then
    die "Please enable FUSE in the Proxmox container and run the script again."
  fi

  # 2) Adjust configuration
  msg_info "SSHFS configuration parameters:"
  adjust_config=$(get_input "Modify default values? (y/n)" "y")
  if [[ "$adjust_config" == "y" || "$adjust_config" == "Y" ]]; then
    for key in "${!CONFIG[@]}"; do
      CONFIG[$key]=$(get_input "Value for ${key}" "${CONFIG[$key]}")
    done
  fi

  msg_info "Using configuration:"
  for key in "${!CONFIG[@]}"; do
    echo "  $key: ${CONFIG[$key]}"
  done

  proceed=$(get_input "Proceed with this configuration? (y/n)" "y")
  if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
    die "Aborted. No changes were made."
  fi

  # 3) Install SSHFS
  msg_info "Checking/installing sshfs..."
  if ! command -v sshfs >/dev/null 2>&1; then
    apt update
    apt install -y sshfs
    msg_ok "sshfs installed."
  else
    msg_ok "sshfs already installed."
  fi

  # 4) Generate SSH key
  msg_info "Checking/creating SSH key for the connection..."
  ssh_key="${CONFIG[SSH_KEY_PATH]}"
  ssh_dir=$(dirname "$ssh_key")
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [[ ! -f "$ssh_key" ]]; then
    ssh-keygen -t rsa -b 4096 -f "$ssh_key" -N ""
    msg_ok "SSH key created: $ssh_key"
  else
    msg_info "SSH key already exists: $ssh_key"
  fi

  # 5) Copy public key to remote host (optional but recommended)
  msg_info "Copying public key to SSH host (for passwordless authentication)..."
  copy_ssh_key=$(get_input "Transfer public key automatically using ssh-copy-id? (y/n)" "y")
  if [[ "$copy_ssh_key" == "y" || "$copy_ssh_key" == "Y" ]]; then
    remote_user="${CONFIG[REMOTE_USER]}"
    remote_host="${CONFIG[REMOTE_HOST]}"
    ssh-copy-id -i "${ssh_key}.pub" "${remote_user}@${remote_host}"
    msg_ok "Public key transferred (unless an error was shown)."
  else
    msg_warn "Skipping ssh-copy-id. Ensure the public key is present on the remote host in ~/.ssh/authorized_keys."
  fi

  # 6) Create local mountpoint
  local_mount="${CONFIG[LOCAL_MOUNT]}"
  msg_info "Creating local mountpoint: ${local_mount}"
  mkdir -p "$local_mount"
  chmod 755 "$local_mount"
  msg_ok "Mountpoint ready."

  # 7) Create /etc/fstab entry
  msg_info "Configuring /etc/fstab for SSHFS..."
  remote_user="${CONFIG[REMOTE_USER]}"
  remote_host="${CONFIG[REMOTE_HOST]}"
  remote_path="${CONFIG[REMOTE_PATH]}"

  # The line we want to add
  fstab_line="sshfs#${remote_user}@${remote_host}:${remote_path} ${local_mount} fuse defaults,_netdev,allow_other,IdentityFile=${ssh_key} 0 0"

  if grep -Fq "${fstab_line}" /etc/fstab; then
    msg_info "Identical SSHFS entry already exists in /etc/fstab."
  else
    cp /etc/fstab /etc/fstab.bak
    echo "$fstab_line" >> /etc/fstab
    msg_ok "SSHFS entry added to /etc/fstab."
  fi

  # 8) Mount filesystem
  msg_info "Trying to mount all /etc/fstab entries (including SSHFS)..."
  mount -a || die "mount -a failed. Please check /etc/fstab."

  if mountpoint -q "$local_mount"; then
    msg_ok "SSHFS successfully mounted at: $local_mount"
  else
    msg_err "SSHFS does not appear to be mounted. mountpoint check failed."
  fi

  # 9) Create Paperless directories on the share
  msg_info "Creating Paperless subfolders on the share (if missing)..."

  mkdir -p \
    "${local_mount}/${PAPERLESS_CONSUME}" \
    "${local_mount}/${PAPERLESS_DATA}" \
    "${local_mount}/${PAPERLESS_MEDIA}" \
    "${local_mount}/${PAPERLESS_TRASH}"

  msg_ok "Directories created or already present:"
  echo "  ${local_mount}/${PAPERLESS_CONSUME}"
  echo "  ${local_mount}/${PAPERLESS_DATA}"
  echo "  ${local_mount}/${PAPERLESS_MEDIA}"
  echo "  ${local_mount}/${PAPERLESS_TRASH}"

  # 10) Paperless configuration hint
  echo
  msg_info "Add the following values to your Paperless configuration (e.g. .env or docker-compose):"
  echo
  echo "  PAPERLESS_CONSUMPTION_DIR=${local_mount}/${PAPERLESS_CONSUME}"
  echo "  PAPERLESS_DATA_DIR=${local_mount}/${PAPERLESS_DATA}"
  echo "  PAPERLESS_MEDIA_ROOT=${local_mount}/${PAPERLESS_MEDIA}"
  echo "  PAPERLESS_EMPTY_TRASH_DIR=${local_mount}/${PAPERLESS_TRASH}"
  echo
  msg_ok "SSHFS setup for Paperless NGX completed."
}

# --- Entry point ---

setup_sshfs_for_paperless
