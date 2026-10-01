#!/bin/sh

# SPDX-License-Identifier: MIT

# Build the released Trealla version used by this repository without
# replacing any system installation.  TLS is disabled by default because the
# conformance matrix uses plain loopback HTTP/WebSocket connections and this
# keeps the build independent of a host OpenSSL installation.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TREALLA_VERSION=${TREALLA_VERSION:-v3.12.6}
TREALLA_BUILD_DIR=${TREALLA_BUILD_DIR:-$ROOT/.build/trealla-$TREALLA_VERSION}
BUILD_JOBS=${BUILD_JOBS:-4}

if [ ! -d "$TREALLA_BUILD_DIR/.git" ]; then
    mkdir -p "$(dirname -- "$TREALLA_BUILD_DIR")"
    git clone --depth 1 --branch "$TREALLA_VERSION" \
        https://github.com/trealla-prolog/trealla.git "$TREALLA_BUILD_DIR"
fi

make -C "$TREALLA_BUILD_DIR" -j"$BUILD_JOBS" NOSSL=1

TPL_PATH="$TREALLA_BUILD_DIR/tpl"
VERSION_TERM=$(
    "$TPL_PATH" -g "current_prolog_flag(version_data,V),writeq(V),nl,halt"
)

printf 'Built %s at %s\n' "$VERSION_TERM" "$TPL_PATH"
printf 'Run tests with:\n  TPL=%s ./tools/test.sh all\n' "$TPL_PATH"
