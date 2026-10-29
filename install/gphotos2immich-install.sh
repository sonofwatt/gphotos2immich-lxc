#!/usr/bin/env bash
# Runs inside the new container (pushed there by ct/gphotos2immich.sh).
# Expects /root/gphotos2immich.env and /root/gphotos2immich.settings.

set -Eeuo pipefail

YW=$'\033[33m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'; CL=$'\033[m'
BFR="\\r\\033[K"; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
msg_info() { printf "   %s..." "${YW}$1${CL}"; }
msg_ok() { printf "${BFR} %s %s\n" "${CM}" "${GN}$1${CL}"; }
msg_warn() { printf "${BFR} %s %s\n" "${CROSS}" "${YW}$1${CL}"; }
msg_error() { printf "${BFR} %s %s\n" "${CROSS}" "${RD}$1${CL}"; }
trap 'msg_error "Line ${LINENO}, exit $?: ${BASH_COMMAND}"' ERR

APP_DIR=/opt/gphotos2immich
APP_USER=gphotos2immich
ENV_FILE=/etc/gphotos2immich.env

# shellcheck source=/dev/null
source /root/gphotos2immich.settings
export DEBIAN_FRONTEND=noninteractive
# pct exec passes the host's LANG (e.g. en_US.UTF-8), which a fresh template
# has not generated, so perl and apt complain. C.UTF-8 is always present.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LANGUAGE

msg_info "Updating the OS"
apt-get update -qq
apt-get -y -qq dist-upgrade >/dev/null
msg_ok "Updated the OS"

msg_info "Installing dependencies"
apt-get -y -qq install curl ca-certificates git jq >/dev/null
msg_ok "Installed dependencies"

# The update script is also the build step, so install and update share one
# code path. ct/gphotos2immich.sh pushes it in next to this script.
msg_info "Installing update-gphotos2immich"
install -o root -g root -m 755 /root/update-gphotos2immich.sh /usr/local/bin/update-gphotos2immich
rm -f /root/update-gphotos2immich.sh
msg_ok "Installed update-gphotos2immich"

msg_info "Creating the ${APP_USER} user and folders"
id -u "${APP_USER}" >/dev/null 2>&1 ||
  useradd --system --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
install -d -o root -g root -m 755 "${APP_DIR}"
install -d -o "${APP_USER}" -g "${APP_USER}" -m 750 "${APP_DIR}/data"
msg_ok "Created the ${APP_USER} user and folders"

printf "   Building gPhotos2Immich %s (a few minutes)\n" "${GPI_VERSION}"
/usr/local/bin/update-gphotos2immich "${GPI_VERSION}"
msg_ok "Built gPhotos2Immich ${GPI_VERSION}"

msg_info "Writing the configuration"
# The API key lives only in the root-only env file, never in config.json.
install -o root -g root -m 600 /root/gphotos2immich.env "${ENV_FILE}"
jq -n \
  --arg url "${ALBUM_URL}" --arg name "${ALBUM_NAME}" --arg every "${SYNC_INTERVAL}" \
  --argjson skip "${SKIP_VIDEOS}" \
  '{debug: false, workers: 4, albumWorkers: 1, strictMetadata: false,
    skipVideos: $skip, dataDir: "./data",
    googlePhotos: [{url: $url, albumName: $name, syncInterval: $every}]}' \
  >"${APP_DIR}/config.json"
chown root:"${APP_USER}" "${APP_DIR}/config.json"
chmod 640 "${APP_DIR}/config.json"
rm -f /root/gphotos2immich.env /root/gphotos2immich.settings
msg_ok "Wrote the configuration"

msg_info "Checking the Immich API key"
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a
if curl -fsS -m 10 -H "x-api-key: ${IMMICH_API_KEY}" "${IMMICH_API_URL}/users/me" >/dev/null 2>&1; then
  msg_ok "Immich accepted the API key"
else
  msg_warn "Immich did not accept the key at ${IMMICH_API_URL}. Fix ${ENV_FILE}, then: systemctl restart gphotos2immich"
fi
unset IMMICH_API_KEY

msg_info "Creating the service"
cat >/etc/systemd/system/gphotos2immich.service <<EOF
[Unit]
Description=gPhotos2Immich (Google Photos shared album to Immich)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/gphotos2immich
Restart=on-failure
RestartSec=30
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR}/data

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q --now gphotos2immich
msg_ok "Created and started the service"

msg_info "Cleaning up"
apt-get -y -qq autoremove >/dev/null
apt-get -y -qq autoclean >/dev/null
msg_ok "Cleaned up"
