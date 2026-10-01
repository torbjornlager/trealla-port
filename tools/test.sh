#!/bin/sh

# SPDX-License-Identifier: MIT

# Reproducible test runner for the Trealla port.
#
# Usage:
#   ./tools/test.sh            # isolated unit groups
#   ./tools/test.sh unit       # same as the default
#   ./tools/test.sh interop    # Trealla <-> SWI WebSocket/protocol matrix
#   ./tools/test.sh all        # unit and interoperability tests
#
# Select the Trealla executable with TPL=/path/to/tpl.  TEST_TIMEOUT controls
# the per-process timeout in seconds; interoperability ports can be overridden
# with TEST_PORT_BASE.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TPL=${TPL:-tpl}
SWIPL=${SWIPL:-swipl}
TEST_TIMEOUT=${TEST_TIMEOUT:-30}
TEST_PORT_BASE=${TEST_PORT_BASE:-39760}
MODE=${1:-unit}
BACKGROUND_PIDS=""

fail() {
    printf '%s\n' "ERROR: $*" >&2
    exit 1
}

cleanup() {
    for cleanup_pid in $BACKGROUND_PIDS; do
        kill "$cleanup_pid" 2>/dev/null || true
        wait "$cleanup_pid" 2>/dev/null || true
    done
}

trap cleanup EXIT HUP INT TERM

command -v "$TPL" >/dev/null 2>&1 || fail "Trealla executable not found: $TPL"

VERSION_TERM=$(
    "$TPL" -g "current_prolog_flag(version_data,V),writeq(V),nl,halt" 2>&1
) || fail "cannot query Trealla version from $TPL"

case "$VERSION_TERM" in
    trealla\(0,0,0,* | trealla\(0,0,0\))
        fail "$TPL reports an unusable development version: $VERSION_TERM; set TPL to a released Trealla build"
        ;;
    trealla\(*)
        ;;
    *)
        fail "$TPL did not report a Trealla version_data term: $VERSION_TERM"
        ;;
esac

printf 'Trealla: %s (%s)\n' "$VERSION_TERM" "$TPL"

"$TPL" -g \
    "current_prolog_flag(version_data,trealla(A,B,C,_)),((A>3;A=:=3,B>12;A=:=3,B=:=12,C>=6)->halt;halt(2))" \
    >/dev/null 2>&1 || fail "Trealla v3.12.6 or newer is required; found $VERSION_TERM"

run_with_timeout() {
    test_label=$1
    shift
    printf '\n=== %s ===\n' "$test_label"

    "$@" &
    command_pid=$!
    (
        sleep "$TEST_TIMEOUT"
        kill -TERM "$command_pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$command_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!

    wait "$command_pid"
    command_exit=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ "$command_exit" -eq 137 ] || [ "$command_exit" -eq 143 ]; then
        fail "$test_label timed out after ${TEST_TIMEOUT}s"
    fi
    if [ "$command_exit" -ne 0 ]; then
        fail "$test_label failed with exit status $command_exit"
    fi
}

run_tpl_goal() {
    test_label=$1
    test_goal=$2
    run_with_timeout "$test_label" \
        "$TPL" -g "consult('$ROOT/tests.pl'),($test_goal->halt;halt(1))"
}

run_unit() {
    run_tpl_goal "actors" "run_test_group(actors)"
    run_tpl_goal "toplevel actors" "run_test_group(toplevel)"
    run_tpl_goal "parallel behaviours" "run_test_group(parallel)"
    run_tpl_goal "private source isolation" "run_test_group(isolation)"
    run_tpl_goal "execution profile policy" "run_test_group(profiles)"
    run_tpl_goal "sandbox and public source policy" "run_test_group(sandbox)"
    run_with_timeout "WebSocket and protocol vectors" \
        "$TPL" -g "consult('$ROOT/websocket_tests.pl'),(websocket_tests->halt;halt(1))"
}

wait_for_port() {
    wait_port=$1
    wait_tries=100
    while [ "$wait_tries" -gt 0 ]; do
        if nc -z 127.0.0.1 "$wait_port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
        wait_tries=$((wait_tries - 1))
    done
    return 1
}

start_background() {
    "$@" &
    started_pid=$!
    BACKGROUND_PIDS="$started_pid $BACKGROUND_PIDS"
    STARTED_PID=$started_pid
}

stop_background() {
    stopped_pid=$1
    kill "$stopped_pid" 2>/dev/null || true
    wait "$stopped_pid" 2>/dev/null || true
}

run_interop() {
    command -v "$SWIPL" >/dev/null 2>&1 || fail "SWI-Prolog executable not found: $SWIPL"
    command -v nc >/dev/null 2>&1 || fail "nc is required for interoperability readiness probes"
    printf 'SWI-Prolog: %s\n' "$($SWIPL --version 2>&1 | head -n 1)"

    echo_port=$((TEST_PORT_BASE + 1))
    reverse_port=$((TEST_PORT_BASE + 2))
    swi_protocol_port=$((TEST_PORT_BASE + 3))
    trealla_protocol_port=$((TEST_PORT_BASE + 4))
    trealla_remote_port=$((TEST_PORT_BASE + 5))

    for candidate_port in "$echo_port" "$reverse_port" "$swi_protocol_port" "$trealla_protocol_port" "$trealla_remote_port"; do
        if nc -z 127.0.0.1 "$candidate_port" >/dev/null 2>&1; then
            fail "interoperability port $candidate_port is already in use; set TEST_PORT_BASE"
        fi
    done

    start_background "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "server($echo_port)"
    swi_echo_pid=$STARTED_PID
    wait_for_port "$echo_port" || fail "SWI echo server did not start on port $echo_port"
    run_with_timeout "Trealla client -> SWI WebSocket" \
        "$TPL" -g "consult('$ROOT/websocket_tests.pl'),trealla_client_test($echo_port),halt"
    stop_background "$swi_echo_pid"

    start_background "$TPL" -g \
        "consult('$ROOT/websocket_tests.pl'),trealla_server_once($reverse_port),halt"
    trealla_echo_pid=$STARTED_PID
    # This fixture accepts exactly one TCP connection.  A readiness probe
    # would consume it, so give the listener a moment and verify its process
    # is still alive instead.
    sleep 0.2
    kill -0 "$trealla_echo_pid" 2>/dev/null || fail "Trealla echo server did not start on port $reverse_port"
    run_with_timeout "SWI client -> Trealla WebSocket" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "client_test($reverse_port),halt"
    wait "$trealla_echo_pid"

    start_background "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "protocol_server($swi_protocol_port)"
    swi_protocol_pid=$STARTED_PID
    wait_for_port "$swi_protocol_port" || fail "SWI protocol fixture did not start on port $swi_protocol_port"
    run_with_timeout "Trealla client -> SWI protocol fixture" \
        "$TPL" -g "consult('$ROOT/websocket_tests.pl'),trealla_protocol_client_test($swi_protocol_port),halt"
    stop_background "$swi_protocol_pid"

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($trealla_protocol_port)"
    trealla_protocol_pid=$STARTED_PID
    # The native node treats a bare TCP readiness probe as a malformed HTTP
    # request and logs unexpected_eof. Avoid adding noise to successful runs.
    sleep 0.2
    kill -0 "$trealla_protocol_pid" 2>/dev/null || fail "Trealla protocol node did not start on port $trealla_protocol_port"
    run_with_timeout "SWI client -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "protocol_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI browser terminal -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "browser_io_client_test($trealla_protocol_port),halt"

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($trealla_remote_port)"
    trealla_remote_pid=$STARTED_PID
    sleep 0.2
    kill -0 "$trealla_remote_pid" 2>/dev/null || fail "remote Trealla protocol node did not start on port $trealla_remote_port"
    run_with_timeout "Trealla distributed source isolation" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(distribution_source_isolation_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "SWI browser terminal -> remote Trealla actor" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "browser_distributed_io_client_test($trealla_protocol_port,'http://127.0.0.1:$trealla_remote_port'),halt"
    stop_background "$trealla_remote_pid"
    stop_background "$trealla_protocol_pid"
}

case "$MODE" in
    unit)
        run_unit
        ;;
    interop)
        run_interop
        ;;
    all)
        run_unit
        run_interop
        ;;
    *)
        fail "unknown mode '$MODE' (expected unit, interop, or all)"
        ;;
esac

printf '\nALL %s TESTS PASSED\n' "$MODE"
