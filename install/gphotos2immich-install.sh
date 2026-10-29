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

# The update script below is also the build step, so install and update
# share one code path.
msg_info "Writing update-gphotos2immich"
cat >/usr/local/bin/update-gphotos2immich <<'UPDATE'
#!/usr/bin/env bash
# Build and install gPhotos2Immich at a release tag (default: newest release).
# Usage: update-gphotos2immich [vX.Y.Z]
set -Eeuo pipefail
SRC_DIR=/opt/gphotos2immich-src
APP_DIR=/opt/gphotos2immich
REPO=https://github.com/warreth/gPhotos2Immich

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  TAG=$(curl -fsSL https://api.github.com/repos/warreth/gPhotos2Immich/releases/latest | jq -r .tag_name)
fi
CURRENT=$(cat "${APP_DIR}/VERSION" 2>/dev/null || echo none)
if [[ "${TAG}" == "${CURRENT}" ]]; then
  echo "gPhotos2Immich ${TAG} is already installed."
  exit 0
fi

# Go toolchain: newest stable release from go.dev, checksum verified.
NEED_GO=$(curl -fsSL "${REPO/github.com/raw.githubusercontent.com}/${TAG}/go.mod" | awk '$1=="go"{print $2}')
HAVE_GO=$(/usr/local/go/bin/go env GOVERSION 2>/dev/null | sed 's/^go//' || true)
if [[ -z "${HAVE_GO}" ]] || [[ "$(printf '%s\n%s\n' "${NEED_GO}" "${HAVE_GO}" | sort -V | head -n 1)" != "${NEED_GO}" ]]; then
  echo "Installing Go (needs ${NEED_GO}, have ${HAVE_GO:-none})"
  case "$(dpkg --print-architecture)" in
    amd64) GOARCH=amd64 ;; arm64) GOARCH=arm64 ;;
    *) echo "Unsupported architecture"; exit 1 ;;
  esac
  read -r GOFILE GOSHA < <(curl -fsSL 'https://go.dev/dl/?mode=json' |
    jq -r --arg a "${GOARCH}" '[.[] | select(.stable)][0].files[]
      | select(.os=="linux" and .arch==$a and .kind=="archive") | "\(.filename) \(.sha256)"')
  TMP=$(mktemp -d)
  curl -fsSL -o "${TMP}/${GOFILE}" "https://go.dev/dl/${GOFILE}"
  echo "${GOSHA}  ${TMP}/${GOFILE}" | sha256sum -c --quiet
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${TMP}/${GOFILE}"
  rm -rf "${TMP}"
fi

echo "Building gPhotos2Immich ${TAG}"
rm -rf "${SRC_DIR}"
git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" "${REPO}" "${SRC_DIR}"
(cd "${SRC_DIR}" && CGO_ENABLED=0 GOFLAGS=-trimpath HOME=/root \
  /usr/local/go/bin/go build -ldflags='-s -w' -o "${SRC_DIR}/gphotos2immich" main.go)

systemctl stop gphotos2immich 2>/dev/null || true
install -o root -g root -m 755 "${SRC_DIR}/gphotos2immich" "${APP_DIR}/gphotos2immich"
echo "${TAG}" >"${APP_DIR}/VERSION"
/usr/local/go/bin/go clean -cache -modcache 2>/dev/null || true
if systemctl is-enabled gphotos2immich >/dev/null 2>&1; then
  systemctl start gphotos2immich
fi
echo "gPhotos2Immich ${TAG} installed."
UPDATE
chmod 755 /usr/local/bin/update-gphotos2immich
msg_ok "Wrote update-gphotos2immich"

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
