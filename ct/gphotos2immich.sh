#!/usr/bin/env bash
# gPhotos2Immich LXC, in the style of the tteck Proxmox VE helper scripts.
# Run on the Proxmox host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/sonofwatt/gphotos2immich-lxc/main/ct/gphotos2immich.sh)"
# or from a checkout:  bash ct/gphotos2immich.sh
#
# Creates an unprivileged Debian 13 container, builds gPhotos2Immich from
# source (no Docker) and runs it as a systemd service that copies a Google
# Photos shared album into Immich on a schedule.
#
# The install script comes from install/ next to this file when run from a
# checkout, otherwise from REPO_RAW.

set -Eeuo pipefail

APP="gPhotos2Immich"
NSAPP="gphotos2immich"
GPI_VERSION="${GPI_VERSION:-v1.7.4}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/sonofwatt/gphotos2immich-lxc/main}"
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
INSTALL_SCRIPT="${SCRIPT_DIR:+${SCRIPT_DIR}/../install/${NSAPP}-install.sh}"

# Defaults (Advanced settings can change all of these)
var_cpu="1"
var_ram="512"
var_swap="512"
var_disk="4"
var_bridge="vmbr0"
var_hostname="${NSAPP}"
var_album_url=""
var_album_name="" # blank: use the Google album's own title
var_interval="1h"
var_skip_videos="true"

# ---------- look and feel ----------
YW=$'\033[33m'; BL=$'\033[36m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'
CL=$'\033[m'; BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

header_info() {
  clear 2>/dev/null || true
  cat <<"EOF"
        ____  __          __      ___   ____                    _      __
  ___ _/ __ \/ /_  ____  / /_____|__ \ /  _/___ ___  ____ ___  (_)____/ /_
 / _ `/ /_/ / __ \/ __ \/ __/ __ \_/ / / // __ `__ \/ __ `__ \/ / ___/ __ \
/ (_| / ____/ / / / /_/ / /_/ /_/ / __/_/ // / / / / / / / / / / / /__/ / / /
\__, /_/   /_/ /_/\____/\__/\____/____/___/_/ /_/ /_/_/ /_/ /_/_/\___/_/ /_/
/____/
EOF
}

msg_info() { printf " %s %s..." "${HOLD}" "${YW}$1${CL}"; }
msg_ok() { printf "${BFR} %s %s\n" "${CM}" "${GN}$1${CL}"; }
msg_error() { printf "${BFR} %s %s\n" "${CROSS}" "${RD}$1${CL}"; }

error_handler() {
  local exit_code=$? line=$1 cmd=$2
  if [[ ${exit_code} -eq 130 ]]; then
    echo -e "\n${YW}Cancelled. Nothing was created.${CL}"; exit 0
  fi
  msg_error "Line ${line}, exit ${exit_code}: ${cmd}"
  [[ -n "${STAGE_DIR:-}" ]] && rm -rf "${STAGE_DIR}"
  exit "${exit_code}"
}
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

# ---------- checks ----------
preflight() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Run this as root on the Proxmox host"; exit 1
  fi
  if ! command -v pct >/dev/null 2>&1; then
    msg_error "pct not found. This script must run on a Proxmox VE host"; exit 1
  fi
  command -v curl >/dev/null 2>&1 || { msg_error "curl is required"; exit 1; }
  command -v whiptail >/dev/null 2>&1 || { msg_error "whiptail is required"; exit 1; }
}

# ---------- prompts ----------
ask() { # ask <title> <prompt> <default>
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "$1" \
    --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3 || cancelled
}

# Prompts run in $( ), so cancelling exits the subshell with 130 and the ERR
# trap turns that into a clean exit.
cancelled() { exit 130; }

pick_storage() { # pick_storage <content> <title>
  local content=$1 title=$2 menu=() line
  while read -r line; do
    local name type avail
    name=$(awk '{print $1}' <<<"${line}")
    type=$(awk '{print $2}' <<<"${line}")
    avail=$(awk '{printf "%.1fG", $6/1024/1024}' <<<"${line}")
    menu+=("${name}" "${type}, ${avail} free" "OFF")
  done < <(pvesm status -content "${content}" | awk 'NR>1 && $3=="active"')
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No active storage holds '${content}'"; exit 1
  elif [[ ${#menu[@]} -eq 3 ]]; then
    echo "${menu[0]}"
  else
    menu[2]="ON"
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "${title}" \
      --radiolist "Choose storage for ${content}:" 16 60 6 "${menu[@]}" 3>&1 1>&2 2>&3 || cancelled
  fi
}

settings() {
  CTID=$(pvesh get /cluster/nextid)
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} LXC" \
    --yesno "Use default settings?\n\n  ${var_cpu} CPU, ${var_ram} MB RAM, ${var_disk} GB disk\n  Debian 13, unprivileged, DHCP on ${var_bridge}\n  Album checked every ${var_interval}, photos only" 14 64; then
    ADVANCED=0
  else
    ADVANCED=1
  fi

  if [[ ${ADVANCED} -eq 1 ]]; then
    CTID=$(ask "Container ID" "Container ID:" "${CTID}")
    var_hostname=$(ask "Hostname" "Hostname:" "${var_hostname}")
    var_cpu=$(ask "CPU" "CPU cores:" "${var_cpu}")
    var_ram=$(ask "RAM" "RAM in MB:" "${var_ram}")
    var_disk=$(ask "Disk" "Disk size in GB:" "${var_disk}")
    var_bridge=$(ask "Network" "Bridge:" "${var_bridge}")
    var_album_name=$(ask "Album" "Album name in Immich (blank: same as Google):" "${var_album_name}")
    var_interval=$(ask "Schedule" "Check the album every (e.g. 30m, 1h, 12h):" "${var_interval}")
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Videos" \
      --defaultno --yesno "Copy videos as well as photos?" 8 50; then
      var_skip_videos="false"
    fi
  fi

  if pct status "${CTID}" >/dev/null 2>&1; then
    msg_error "Container ${CTID} already exists"; exit 1
  fi

  IMMICH_URL=$(ask "Immich" "Immich API URL (ends in /api):" "http://192.168.1.10:2283/api")
  IMMICH_URL="${IMMICH_URL%/}"
  [[ "${IMMICH_URL}" == */api ]] || IMMICH_URL="${IMMICH_URL}/api"

  IMMICH_KEY=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Immich API key" \
    --passwordbox "Immich API key. Permissions needed:\nasset.read, asset.upload, album.create, album.read,\nalbum.update, albumAsset.create, user.read" 12 70 3>&1 1>&2 2>&3) || cancelled
  [[ -n "${IMMICH_KEY}" ]] || { msg_error "An Immich API key is required"; exit 1; }

  var_album_url=$(ask "Google Photos" "Shared album link (must open in a private window):" "${var_album_url}")
  [[ "${var_album_url}" == https://* ]] || { msg_error "A shared album link is required"; exit 1; }

  TEMPLATE_STORAGE=$(pick_storage vztmpl "Template storage")
  CONTAINER_STORAGE=$(pick_storage rootdir "Container storage")
}

# ---------- container ----------
get_template() {
  msg_info "Updating the template list"
  pveam update >/dev/null
  TEMPLATE=$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -V | tail -n 1)
  [[ -n "${TEMPLATE}" ]] || { msg_error "No Debian 13 template available"; exit 1; }
  msg_ok "Found ${TEMPLATE}"
  if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
    msg_info "Downloading ${TEMPLATE}"
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}" >/dev/null
    msg_ok "Downloaded ${TEMPLATE}"
  fi
}

create_container() {
  msg_info "Creating LXC ${CTID}"
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${var_hostname}" \
    --cores "${var_cpu}" --memory "${var_ram}" --swap "${var_swap}" \
    --rootfs "${CONTAINER_STORAGE}:${var_disk}" \
    --net0 "name=eth0,bridge=${var_bridge},ip=dhcp" \
    --unprivileged 1 --features nesting=1 --onboot 1 \
    --ostype debian --tags "${NSAPP}" \
    --description "${APP} ${GPI_VERSION}: copies a Google Photos shared album into Immich. Built from https://github.com/warreth/gPhotos2Immich; update with: update-gphotos2immich" \
    >/dev/null
  msg_ok "Created LXC ${CTID}"

  msg_info "Starting LXC ${CTID}"
  pct start "${CTID}"
  for _ in $(seq 1 30); do
    if pct exec "${CTID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      msg_ok "Started LXC ${CTID}, network is up"
      return
    fi
    sleep 2
  done
  msg_error "LXC ${CTID} has no network after 60 s"; exit 1
}

stage_files() {
  # Secrets and settings go in by file, never on a command line.
  STAGE_DIR=$(mktemp -d)
  chmod 700 "${STAGE_DIR}"
  (
    umask 077
    printf 'IMMICH_API_KEY=%s\nIMMICH_API_URL=%s\nDISABLE_WEBUI=true\nTZ=%s\n' \
      "${IMMICH_KEY}" "${IMMICH_URL}" "$(cat /etc/timezone 2>/dev/null || echo UTC)" \
      >"${STAGE_DIR}/gphotos2immich.env"
    printf 'ALBUM_URL=%q\nALBUM_NAME=%q\nSYNC_INTERVAL=%q\nSKIP_VIDEOS=%q\nGPI_VERSION=%q\n' \
      "${var_album_url}" "${var_album_name}" "${var_interval}" "${var_skip_videos}" "${GPI_VERSION}" \
      >"${STAGE_DIR}/settings"
  )
  pct push "${CTID}" "${STAGE_DIR}/gphotos2immich.env" /root/gphotos2immich.env --perms 600
  pct push "${CTID}" "${STAGE_DIR}/settings" /root/gphotos2immich.settings --perms 600
  if [[ -n "${INSTALL_SCRIPT}" && -f "${INSTALL_SCRIPT}" ]]; then
    cp "${INSTALL_SCRIPT}" "${STAGE_DIR}/install.sh"
  else
    curl -fsSL -o "${STAGE_DIR}/install.sh" "${REPO_RAW}/install/${NSAPP}-install.sh"
  fi
  pct push "${CTID}" "${STAGE_DIR}/install.sh" /root/gphotos2immich-install.sh --perms 700
  rm -rf "${STAGE_DIR}"
  unset STAGE_DIR IMMICH_KEY
}

run_install() {
  pct exec "${CTID}" -- bash /root/gphotos2immich-install.sh
  pct exec "${CTID}" -- rm -f /root/gphotos2immich-install.sh
}

main() {
  header_info
  preflight
  settings
  header_info
  get_template
  create_container
  stage_files
  run_install
  local ip
  ip=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')
  echo
  msg_ok "${APP} ${GPI_VERSION} is running in LXC ${CTID} (${var_hostname}, ${ip})"
  echo -e "   Logs:    ${BL}pct exec ${CTID} -- journalctl -u gphotos2immich -f${CL}"
  echo -e "   Update:  ${BL}pct exec ${CTID} -- update-gphotos2immich [tag]${CL}"
}

main "$@"
