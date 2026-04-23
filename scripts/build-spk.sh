#!/usr/bin/env bash
# build-spk.sh — Build a Synology SPK package for WeTTY Terminal
#
# Usage:
#   ./scripts/build-spk.sh [--arch <arch>] [--node-version <version>]
#
# Options:
#   --arch          Target architecture: x86_64 (default) or aarch64
#   --node-version  Node.js LTS version to bundle (default: 20)
#
# The resulting .spk file is written to the dist/ directory.
#
# Prerequisites (build machine):
#   - bash, tar, gzip, curl, pnpm (>=9), node (>=18), imagemagick (optional, for icons)
#
# Cross-compilation note:
#   node-pty contains native C++ code.  The SPK built here targets the
#   architecture of the BUILD machine.  To build an aarch64 SPK on an x86_64
#   host, run inside a suitable QEMU/Docker aarch64 environment and pass
#   --arch aarch64.
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ARCH="x86_64"
NODE_MAJOR="20"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNOLOGY_DIR="${REPO_ROOT}/synology"
DIST_DIR="${REPO_ROOT}/dist"
STAGING_DIR="$(mktemp -d)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)         ARCH="$2";         shift 2 ;;
        --node-version) NODE_MAJOR="$2";   shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validate arch ─────────────────────────────────────────────────────────────
case "${ARCH}" in
    x86_64|aarch64) ;;
    *) echo "ERROR: Unsupported --arch '${ARCH}'. Use x86_64 or aarch64."; exit 1 ;;
esac

# Map SPK arch name → Node.js download suffix
case "${ARCH}" in
    x86_64)  NODE_ARCH="x64"   ;;
    aarch64) NODE_ARCH="arm64" ;;
esac

# ── Read version from package.json ────────────────────────────────────────────
PKG_VERSION=$(node -e "process.stdout.write(require('${REPO_ROOT}/package.json').version)")
SPK_VERSION="${PKG_VERSION}-0001"
SPK_NAME="wetty_${SPK_VERSION}_${ARCH}.spk"

echo "============================================================"
echo " Building WeTTY Terminal SPK"
echo "  Package version : ${PKG_VERSION}"
echo "  SPK version     : ${SPK_VERSION}"
echo "  Target arch     : ${ARCH}"
echo "  Node.js major   : ${NODE_MAJOR}"
echo "  Output          : ${DIST_DIR}/${SPK_NAME}"
echo "============================================================"

# ── Step 1 — Download and extract Node.js binary ─────────────────────────────
echo ""
echo "[1/6] Fetching latest Node.js ${NODE_MAJOR} LTS binary for ${ARCH} ..."

mkdir -p "${REPO_ROOT}/.cache"

# Fetch SHASUMS256.txt — used both to resolve the latest patch version and to
# verify the integrity of the downloaded tarball.
SHASUMS_URL="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt"
SHASUMS_FILE="${REPO_ROOT}/.cache/SHASUMS256-v${NODE_MAJOR}-${NODE_ARCH}.txt"
echo "  Fetching checksums from ${SHASUMS_URL} ..."
curl -fsSL -o "${SHASUMS_FILE}" "${SHASUMS_URL}"

# Parse bare semver (e.g. "20.11.1") — strip leading "v" and the platform suffix.
NODE_VERSION=$(grep "node-v.*-linux-${NODE_ARCH}.tar.xz" "${SHASUMS_FILE}" \
    | head -1 \
    | awk '{print $2}' \
    | sed 's/node-v//' \
    | sed 's/-linux-.*//')

if [ -z "${NODE_VERSION}" ]; then
    echo "ERROR: Could not determine Node.js version for major ${NODE_MAJOR}."
    exit 1
fi

NODE_TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_CACHE="${REPO_ROOT}/.cache/${NODE_TARBALL}"

# Extract the expected SHA-256 for this specific tarball.
EXPECTED_SHA256=$(grep "${NODE_TARBALL}" "${SHASUMS_FILE}" | awk '{print $1}')
if [ -z "${EXPECTED_SHA256}" ]; then
    echo "ERROR: Could not find SHA-256 checksum for ${NODE_TARBALL}."
    exit 1
fi

if [ ! -f "${NODE_CACHE}" ]; then
    echo "  Downloading ${NODE_URL} ..."
    curl -fsSL -o "${NODE_CACHE}" "${NODE_URL}"
else
    echo "  Using cached ${NODE_TARBALL}"
fi

# Verify integrity before extracting — fail hard on mismatch and remove the bad file.
echo "  Verifying SHA-256 ..."
ACTUAL_SHA256=$(sha256sum "${NODE_CACHE}" | awk '{print $1}')
if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
    echo "ERROR: SHA-256 mismatch for ${NODE_TARBALL}!"
    echo "  Expected : ${EXPECTED_SHA256}"
    echo "  Actual   : ${ACTUAL_SHA256}"
    rm -f "${NODE_CACHE}"
    exit 1
fi
echo "  SHA-256 verified OK"

NODE_TMP=$(mktemp -d)
tar -xf "${NODE_CACHE}" -C "${NODE_TMP}" --strip-components=1
NODE_BINARY="${NODE_TMP}/bin/node"

echo "  Using Node.js v${NODE_VERSION}"

# Prepend the downloaded Node.js v${NODE_MAJOR} bin directory to PATH so that
# pnpm install (and any node-gyp native compilation) uses the correct Node.js
# version rather than whatever happens to be installed system-wide.
export PATH="${NODE_TMP}/bin:${PATH}"

# ── Step 2 — Build WeTTY ──────────────────────────────────────────────────────
echo ""
echo "[2/6] Installing dependencies and building WeTTY ..."
cd "${REPO_ROOT}"
pnpm install --frozen-lockfile
pnpm build

# ── Step 3 — Assemble staging area ───────────────────────────────────────────
echo ""
echo "[3/6] Assembling package directory structure ..."

PACKAGE_STAGE="${STAGING_DIR}/package"
mkdir -p \
    "${PACKAGE_STAGE}/bin" \
    "${PACKAGE_STAGE}/app/build" \
    "${PACKAGE_STAGE}/app/conf" \
    "${PACKAGE_STAGE}/conf" \
    "${PACKAGE_STAGE}/var"

# Bundled Node.js binary
cp "${NODE_BINARY}" "${PACKAGE_STAGE}/bin/node"
chmod 755 "${PACKAGE_STAGE}/bin/node"

# Built WeTTY application (JS + client assets)
cp -r "${REPO_ROOT}/build/."  "${PACKAGE_STAGE}/app/build/"
cp -r "${REPO_ROOT}/conf/."   "${PACKAGE_STAGE}/app/conf/"
cp    "${REPO_ROOT}/package.json" "${PACKAGE_STAGE}/app/"

# node_modules (includes pre-compiled native modules for this arch)
cp -r "${REPO_ROOT}/node_modules" "${PACKAGE_STAGE}/app/node_modules"

# Default configuration for the NAS
cp "${SYNOLOGY_DIR}/conf/wetty.config" "${PACKAGE_STAGE}/conf/wetty.config"
cp "${SYNOLOGY_DIR}/conf/reverse-proxy.conf" "${PACKAGE_STAGE}/conf/reverse-proxy.conf"

# Tar up the package directory
tar -czf "${STAGING_DIR}/package.tgz" -C "${STAGING_DIR}" package

# ── Step 4 — Copy lifecycle scripts ──────────────────────────────────────────
echo ""
echo "[4/6] Adding lifecycle scripts ..."

for script in preinst postinst preuninst postuninst start-stop-status; do
    cp "${SYNOLOGY_DIR}/scripts/${script}" "${STAGING_DIR}/${script}"
    chmod 755 "${STAGING_DIR}/${script}"
done

# ── Step 5 — Generate INFO file ───────────────────────────────────────────────
echo ""
echo "[5/6] Generating INFO file ..."

sed \
    -e "s/%%VERSION%%/${SPK_VERSION}/" \
    -e "s/%%ARCH%%/${ARCH}/" \
    "${SYNOLOGY_DIR}/INFO" > "${STAGING_DIR}/INFO"

# ── Step 6 — Fetch / generate package icons ───────────────────────────────────
echo ""
echo "[6/6] Adding package icons ..."

ICON_72="${STAGING_DIR}/PACKAGE_ICON.PNG"
ICON_256="${STAGING_DIR}/PACKAGE_ICON_256.PNG"

# Try to generate icons with ImageMagick; fall back to a minimal placeholder.
if command -v convert &>/dev/null; then
    convert -size 72x72   xc:'#2d8cf0' -fill white \
        -font DejaVu-Sans-Bold -pointsize 14 \
        -gravity center -annotate 0 "WeTTY" \
        "${ICON_72}"  2>/dev/null || true
    convert -size 256x256 xc:'#2d8cf0' -fill white \
        -font DejaVu-Sans-Bold -pointsize 48 \
        -gravity center -annotate 0 "WeTTY" \
        "${ICON_256}" 2>/dev/null || true
fi

# Minimal 1×1 transparent PNG as ultimate fallback
_minimal_png() {
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$1"
}
[ -f "${ICON_72}"  ] || _minimal_png "${ICON_72}"
[ -f "${ICON_256}" ] || _minimal_png "${ICON_256}"

# ── Assemble final SPK ────────────────────────────────────────────────────────
echo ""
echo "Packaging SPK ..."

mkdir -p "${DIST_DIR}"
tar -czf "${DIST_DIR}/${SPK_NAME}" \
    -C "${STAGING_DIR}" \
    INFO \
    PACKAGE_ICON.PNG \
    PACKAGE_ICON_256.PNG \
    package.tgz \
    preinst postinst preuninst postuninst start-stop-status

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "${STAGING_DIR}" "${NODE_TMP}"

echo ""
echo "============================================================"
echo " Done!  SPK written to:"
echo "   ${DIST_DIR}/${SPK_NAME}"
echo ""
echo " Install via DSM:"
echo "   Package Center → Manual Install → upload the .spk file"
echo ""
echo " WeTTY will be available at:"
echo "   http://<NAS-IP>:13338/wetty"
echo "============================================================"
