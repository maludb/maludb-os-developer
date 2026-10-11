#!/usr/bin/env bash
# Build libpg_query (BSD-3, the PostgreSQL parser as a library — https://github.com/pganalyze/libpg_query) as a shared library for the
# door's ctypes binding (services/door/pgquery.py; design §6.1 step 2, D7). Idempotent; runs as the application's owner (no root):
#
#   deploy/build-libpg_query.sh            → services/vendor/lib/libpg_query.so (+ VERSION)
#
# THE PIN. 17-6.2.5 — the PostgreSQL 17 grammar, the same major as this cluster (17.11). The 18.x line exists (18.1.0) but parses PG 18
# syntax PG 17 rejects (e.g. `NOT NULL … NOT VALID`): the door classifies what the server will run, so the grammars match. Move the pin
# with the server's major. The tarball is GitHub's archive of the tag; its sha256 is checked before anything is built (an archive whose
# hash changed is refused, never built — fetch it again by hand and compare against the tag before moving the pin).
set -euo pipefail

VERSION="17-6.2.5"
SHA256="344ee7a39d3fa4eb5e8cdff8aa7db514a30883423c65731c9ce04b2b7089abb6"
URL="https://github.com/pganalyze/libpg_query/archive/refs/tags/${VERSION}.tar.gz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${HERE}/services/vendor"
LIB="${VENDOR}/lib"
SRC="${VENDOR}/src"

if [[ -f "${LIB}/libpg_query.so" && "$(cat "${LIB}/VERSION" 2>/dev/null)" == "${VERSION}" ]]; then
    echo "libpg_query ${VERSION}: already built (${LIB}/libpg_query.so)"
    exit 0
fi

command -v gcc >/dev/null || { echo "gcc is required (build-essential)" >&2; exit 1; }
command -v make >/dev/null || { echo "make is required (build-essential)" >&2; exit 1; }

mkdir -p "${SRC}" "${LIB}"
TARBALL="${SRC}/libpg_query-${VERSION}.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
    curl -fsSL --max-time 300 -o "${TARBALL}.part" "${URL}"
    mv "${TARBALL}.part" "${TARBALL}"
fi
echo "${SHA256}  ${TARBALL}" | sha256sum -c --quiet - || { echo "libpg_query ${VERSION}: sha256 mismatch — refusing to build" >&2; rm -f "${TARBALL}"; exit 1; }

BUILD="${SRC}/libpg_query-${VERSION}"
rm -rf "${BUILD}"
tar -xzf "${TARBALL}" -C "${SRC}"
make -C "${BUILD}" -s -j"$(nproc)" build_shared >/dev/null
SO="$(find "${BUILD}" -maxdepth 1 -name 'libpg_query.so*' -type f | head -1)"
[[ -n "${SO}" ]] || { echo "libpg_query ${VERSION}: the build produced no shared library" >&2; exit 1; }
install -m 0644 "${SO}" "${LIB}/libpg_query.so"
echo "${VERSION}" > "${LIB}/VERSION"
rm -rf "${BUILD}"
echo "libpg_query ${VERSION}: built → ${LIB}/libpg_query.so"
