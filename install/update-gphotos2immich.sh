#!/usr/bin/env bash
# Build and install gPhotos2Immich at a release tag (default: newest release).
# Usage: update-gphotos2immich [vX.Y.Z]
set -Eeuo pipefail
# pct exec passes the host's LANG, which the container may not have, so perl
# warns. C.UTF-8 is always present.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LANGUAGE
SRC_DIR=/opt/gphotos2immich-src
APP_DIR=/opt/gphotos2immich
REPO=https://github.com/warreth/gPhotos2Immich

# Bump PATCHSET whenever the local patches below change, so existing installs
# rebuild even when the upstream tag is the same.
PATCHSET=p1

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  TAG=$(curl -fsSL https://api.github.com/repos/warreth/gPhotos2Immich/releases/latest | jq -r .tag_name)
fi
CURRENT=$(cat "${APP_DIR}/VERSION" 2>/dev/null || echo none)
if [[ "${TAG}+${PATCHSET}" == "${CURRENT}" ]]; then
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

# Patch: skip videos before downloading them. Upstream downloads the whole
# video into memory and only then checks skipVideos, so a few long videos at
# once get the service OOM-killed. The album listing already flags videos.
APP_GO="${SRC_DIR}/pkg/app/app.go"
if grep -q 'p.IsVideo && a.Cfg.SkipVideos' "${APP_GO}"; then
  echo "Upstream already skips videos before download; no patch needed."
elif grep -q $'^\ta.Logger.Debug("Downloading item"' "${APP_GO}"; then
  perl -0pi -e 's/^(\ta\.Logger\.Debug\("Downloading item")/\tif p.IsVideo && a.Cfg.SkipVideos {\n\t\ta.Logger.Debug("Skipping video item before download", "id", p.ID)\n\t\treturn "", false, 0, 0, nil\n\t}\n\n$1/m' "${APP_GO}"
  echo "Applied patch: skip videos before download."
else
  echo "WARNING: could not apply the skip-videos patch; upstream code changed." >&2
fi

(cd "${SRC_DIR}" && CGO_ENABLED=0 GOFLAGS=-trimpath HOME=/root \
  /usr/local/go/bin/go build -ldflags='-s -w' -o "${SRC_DIR}/gphotos2immich" main.go)

systemctl stop gphotos2immich 2>/dev/null || true
install -o root -g root -m 755 "${SRC_DIR}/gphotos2immich" "${APP_DIR}/gphotos2immich"
echo "${TAG}+${PATCHSET}" >"${APP_DIR}/VERSION"
/usr/local/go/bin/go clean -cache -modcache 2>/dev/null || true
if systemctl is-enabled gphotos2immich >/dev/null 2>&1; then
  systemctl start gphotos2immich
fi
echo "gPhotos2Immich ${TAG} installed."
