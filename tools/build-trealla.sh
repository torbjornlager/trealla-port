#!/bin/sh

# SPDX-License-Identifier: MIT

# Build the released Trealla version used by this repository without
# replacing any system installation. TLS is disabled by default because the
# conformance matrix uses loopback HTTP/WebSocket connections. Set
# TREALLA_TLS=1 to build against the host OpenSSL installation.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TREALLA_VERSION=${TREALLA_VERSION:-v3.12.6}
TREALLA_TLS=${TREALLA_TLS:-0}
case "$TREALLA_TLS" in
    0) DEFAULT_BUILD_DIR=$ROOT/.build/trealla-$TREALLA_VERSION ;;
    1) DEFAULT_BUILD_DIR=$ROOT/.build/trealla-$TREALLA_VERSION-tls ;;
    *) printf '%s\n' "TREALLA_TLS must be 0 or 1" >&2; exit 2 ;;
esac
TREALLA_BUILD_DIR=${TREALLA_BUILD_DIR:-$DEFAULT_BUILD_DIR}
BUILD_JOBS=${BUILD_JOBS:-4}

if [ ! -d "$TREALLA_BUILD_DIR/.git" ]; then
    mkdir -p "$(dirname -- "$TREALLA_BUILD_DIR")"
    git clone --depth 1 --branch "$TREALLA_VERSION" \
        https://github.com/trealla-prolog/trealla.git "$TREALLA_BUILD_DIR"
fi

case "$TREALLA_TLS" in
    0) make -C "$TREALLA_BUILD_DIR" -j"$BUILD_JOBS" NOSSL=1 ;;
    1) make -C "$TREALLA_BUILD_DIR" -j"$BUILD_JOBS" ;;
esac

TPL_PATH="$TREALLA_BUILD_DIR/tpl"
VERSION_TERM=$(
    "$TPL_PATH" -g "current_prolog_flag(version_data,V),writeq(V),nl,halt"
)

printf 'Built %s at %s\n' "$VERSION_TERM" "$TPL_PATH"
printf 'TLS support requested: %s\n' "$TREALLA_TLS"
printf 'Run tests with:\n  TPL=%s ./tools/test.sh all\n' "$TPL_PATH"
