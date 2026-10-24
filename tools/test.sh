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
TRINITY_NODE_FILE=${TRINITY_NODE_FILE:-$ROOT/../trinity-demonstrator/prolog/web_prolog/node.pl}
MODE=${1:-unit}
BACKGROUND_PIDS=""

# A repository-local Trealla build is not installed under its compiled
# system prefix. Pair it with the library directory beside the executable;
# otherwise it can silently load an older system-wide standard library.
TPL_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$TPL")" 2>/dev/null && pwd || true)
if [ -n "$TPL_DIRECTORY" ] && [ -d "$TPL_DIRECTORY/library" ]; then
    TPL_LIBRARY_PATH=$TPL_DIRECTORY/library
    export TPL_LIBRARY_PATH
fi

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
    "current_prolog_flag(version_data,trealla(A,B,C,_)),((A>3;A=:=3,B>13;A=:=3,B=:=13,C>=10)->halt;halt(2))" \
    >/dev/null 2>&1 || fail "Trealla v3.13.10 or newer is required; found $VERSION_TERM"

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
        "$TPL" -g "(catch((consult('$ROOT/tests.pl'),$test_goal),_,fail)->halt(0);halt(1))"
}

run_unit() {
    run_with_timeout "Canonical answer negotiation context" \
        "$TPL" -g "consult('$ROOT/answer_negotiation_tests.pl'),(catch(answer_negotiation_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Concurrent bootstrap and reply serialization" \
        "$TPL" -g "consult('$ROOT/source_capture_tests.pl'),(catch(source_capture_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Owned remote demonitor acknowledgement and flush" \
        "$TPL" -g "consult('$ROOT/remote_demonitor_tests.pl'),(catch(remote_demonitor_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Independent termination notification references" \
        "$TPL" -g "consult('$ROOT/termination_notification_tests.pl'),(catch(termination_notification_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "General toplevel creation validation and local path" \
        "$TPL" -g "consult('$ROOT/remote_toplevel_creation_tests.pl'),(catch(remote_toplevel_creation_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Public synchronous toplevel wrappers" \
        "$TPL" -g "consult('$ROOT/synchronous_toplevel_tests.pl'),(catch(synchronous_toplevel_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    http_timeout_port=$((TEST_PORT_BASE + 88))
    run_with_timeout "Promise stream cleanup on malformed replies" \
        python3 "$ROOT/tools/test-http-timeout-enforcement.py" --tpl "$TPL" --case parse_error
    run_with_timeout "HTTP transport timeout option mapping" \
        "$TPL" -g "consult('$ROOT/rpc_http_timeout_tests.pl'),(catch(rpc_http_timeout_tests:run($http_timeout_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Host runtime properties" \
        "$TPL" -g "consult('$ROOT/runtime_property_tests.pl'),(catch(runtime_property_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    http_once_port=$((TEST_PORT_BASE + 87))
    run_with_timeout "HTTP server first-slice cleanup" \
        "$TPL" -g "consult('$ROOT/http_once_tests.pl'),(catch(http_once_tests:run($http_once_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    rpc_once_port=$((TEST_PORT_BASE + 86))
    run_with_timeout "RPC first-slice once option" \
        "$TPL" -g "consult('$ROOT/rpc_once_tests.pl'),(catch(rpc_once_tests:run($rpc_once_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "first_solution continuation determinism" \
        "$TPL" -g "consult('$ROOT/first_solution_determinism_tests.pl'),(catch(first_solution_determinism_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "source-less toplevel worker routing" \
        "$TPL" -g "consult('$ROOT/public_worker_routing_tests.pl'),(catch(public_worker_routing_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "retired deployment page cap" \
        env WP_MAX_SOLUTIONS=100 "$TPL" -g "consult('$ROOT/Deployment/start_node.pl'),(catch(deployment_start:reject_retired_page_cap,E,true),E=error(domain_error(retired_environment_variable,'WP_MAX_SOLUTIONS'),_)->halt;halt(1))"
    page_size_port=$((TEST_PORT_BASE + 85))
    run_with_timeout "caller-controlled page sizes" \
        "$TPL" -g "consult('$ROOT/page_size_tests.pl'),(catch(page_size_tests:run($page_size_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "server promise setup/send cleanup" \
        "$TPL" -g "consult('$ROOT/server_promise_cleanup_tests.pl'),(catch(server_promise_cleanup_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    paging_offset_port=$((TEST_PORT_BASE + 84))
    run_with_timeout "HTTP paging offsets" \
        "$TPL" -g "consult('$ROOT/http_paging_offset_tests.pl'),(catch(http_paging_offset_tests:run($paging_offset_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    connection_stack_port=$((TEST_PORT_BASE + 83))
    run_with_timeout "connection-thread stack limits" \
        "$TPL" -g "consult('$ROOT/connection_stack_tests.pl'),(catch(connection_stack_tests:run($connection_stack_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "finite-limit WebSocket connection" \
        "$TPL" -g "consult('$ROOT/connection_stack_tests.pl'),(catch(connection_stack_tests:websocket_live($connection_stack_port),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "HTTP whole-page deadline" \
        "$TPL" -g "consult('$ROOT/http_page_deadline_tests.pl'),(catch(http_page_deadline_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "HTTP continuation cache eviction cleanup" \
        "$TPL" -g "consult('$ROOT/http_cache_eviction_tests.pl'),(catch(http_cache_eviction_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "HTTP paging request cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/http_paging_cleanup_tests.pl'),http_paging_cleanup_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "remote statechart construction and trace acknowledgements" \
        "$TPL" -g "(catch((consult('$ROOT/remote_chart_tests.pl'),remote_chart_tests:unit),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "remote statechart receiver boundary" \
        "$TPL" -g "(catch((consult('$ROOT/remote_statechart_invocation_tests.pl'),remote_statechart_invocation_tests:unit),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "discontiguous source declarations" \
        "$TPL" -g "(catch((consult('$ROOT/source_declaration_tests.pl'),source_declaration_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "empty dynamic declarations and boxshop" \
        "$TPL" -g "(catch((consult('$ROOT/statechart_boxshop_tests.pl'),statechart_boxshop_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "statechart local invocation" \
        "$TPL" -g "(catch((consult('$ROOT/statechart_invocation_tests.pl'),statechart_invocation_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "statechart execution" \
        "$TPL" -g "(catch((consult('$ROOT/statechart_actor_tests.pl'),statechart_actor_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor halt ordering" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_halt_tests.pl'),supervisor_halt_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "spawn reply correlation" \
        "$TPL" -g "(catch((consult('$ROOT/spawn_reply_tests.pl'),spawn_reply_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "remote supervisor receiver and sandbox" \
        "$TPL" -g "(catch((consult('$ROOT/remote_supervisor_tests.pl'),remote_supervisor_tests:remote_supervisor_tests,remote_supervisor_tests:remote_supervisor_policy_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "atomic remote named startup" \
        "$TPL" -g "(catch((consult('$ROOT/remote_named_tests.pl'),remote_named_tests:remote_named_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "receiver delegated lineage cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/receiver_lineage_tests.pl'),receiver_lineage_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "WebSocket namespace promise disposal" \
        "$TPL" -g "(catch((consult('$ROOT/rpc_namespace_tests.pl'),rpc_namespace_tests:rpc_namespace_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "WebSocket namespace teardown" \
        "$TPL" -g "(catch((consult('$ROOT/namespace_tests.pl'),namespace_tests:namespace_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "remote alias cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/remote_alias_tests.pl'),remote_alias_tests:remote_alias_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "stale local PID registration" \
        "$TPL" -g "(catch((consult('$ROOT/registration_tests.pl'),registration_tests:registration_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "atomic local named creation" \
        "$TPL" -g "(catch((consult('$ROOT/named_creation_tests.pl'),named_creation_tests:named_creation_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor restart intensity exhaustion cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_intensity_tests.pl'),supervisor_intensity_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor replacement startup failure cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_restart_tests.pl'),supervisor_restart_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor initial and dynamic startup cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_startup_tests.pl'),supervisor_startup_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor child specification validation" \
        "$TPL" -g "(catch((consult('$ROOT/child_spec_tests.pl'),child_spec_tests:child_spec_tests),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "supervisor source selection and variable receive" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_source_tests.pl'),supervisor_source_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "specialized wrapper option validation" \
        "$TPL" -g "consult('$ROOT/wrapper_option_tests.pl'),(wrapper_option_tests->halt;halt(1))"
    run_with_timeout "spawn option validation" \
        "$TPL" -g "consult('$ROOT/spawn_option_tests.pl'),(spawn_option_tests->halt;halt(1))"
    run_with_timeout "RPC client option validation" \
        "$TPL" -g "consult('$ROOT/rpc_option_tests.pl'),(rpc_option_tests->halt;halt(1))"
    run_with_timeout "HTTP client execution context" \
        python3 "$ROOT/tools/test-http-client-context.py" --tpl "$TPL"
    run_with_timeout "promise ownership" \
        "$TPL" -g "consult('$ROOT/rpc_ownership_tests.pl'),(rpc_ownership_tests->halt;halt(1))"
    run_with_timeout "promise lifecycle" \
        "$TPL" -g "consult('$ROOT/rpc_lifecycle_tests.pl'),(rpc_lifecycle_tests->halt;halt(1))"
    run_with_timeout "promise/yield correctness" \
        "$TPL" -g "consult('$ROOT/rpc_promise_tests.pl'),(rpc_promise_tests->halt;halt(1))"
    run_with_timeout "outbound synchronous vectors" \
        "$TPL" -g "consult('$ROOT/distribution_sync_tests.pl'),(distribution_sync_tests->halt;halt(1))"
    run_with_timeout "toplevel correlation vectors" \
        "$TPL" -g "consult('$ROOT/toplevel_correlation_tests.pl'),(toplevel_correlation_tests->halt;halt(1))"
    run_with_timeout "outbound canonical answer vectors" \
        "$TPL" -g "consult('$ROOT/distribution_canonical_tests.pl'),(distribution_canonical_tests->halt;halt(1))"
    run_tpl_goal "actors" "run_test_group(actors)"
    run_tpl_goal "toplevel actors" "run_test_group(toplevel)"
    run_tpl_goal "parallel behaviours" "run_test_group(parallel)"
    run_with_timeout "receive handoff semantics and interruption" \
        "$TPL" -g "(catch((consult('$ROOT/receive_handoff_tests.pl'),((predicate_property(sig_atomic(_), defined);predicate_property('\$thread_get_message_saved'(_,_,_,_,_),built_in))->receive_handoff_tests:run;(receive_handoff_tests:semantics,writeln('SKIP: receive interruption stress requires sig_atomic/1 or the saved-message engine primitive')))),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "signal-atomic receive deadlines and returning handlers" \
        "$TPL" -g "(catch((consult('$ROOT/receive_atomic_tests.pl'),(predicate_property(sig_atomic(_),defined)->receive_atomic_tests:run;writeln('SKIP: atomic receive deadline tests require public sig_atomic/1'))),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "worker scope startup and interruption cleanup" \
        "$TPL" -g "(catch((consult('$ROOT/worker_scope_tests.pl'),worker_scope_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "unexpected parallel worker exits" \
        "$TPL" -g "consult('$ROOT/parallel_exit_tests.pl'),(parallel_exit_tests->halt;halt(1))"
    run_with_timeout "generic server behaviour" \
        "$TPL" -g "(catch((consult('$ROOT/server_actor_tests.pl'),server_actor_tests:run_server_actor_tests),_,fail)->halt(0);halt(1))"
    run_with_timeout "supervisor behaviour" \
        "$TPL" -g "(catch((consult('$ROOT/supervisor_actor_tests.pl'),supervisor_actor_tests:run_supervisor_actor_tests),_,fail)->halt(0);halt(1))"
    run_with_timeout "SXML parser and validator" \
        "$TPL" -g "(catch((consult('$ROOT/sxml_parser_tests.pl'),sxml_parser_tests:run_sxml_parser_tests),_,fail)->halt(0);halt(1))"
    run_tpl_goal "private source isolation" "run_test_group(isolation)"
    run_tpl_goal "execution profile policy" "run_test_group(profiles)"
    run_tpl_goal "sandbox and public source policy" "run_test_group(sandbox)"
    run_tpl_goal "resource governance" "run_test_group(resources)"
    run_tpl_goal "authentication and origin policy" "run_test_group(auth)"
    run_tpl_goal "per-principal governance" "run_test_group(governance)"
    run_tpl_goal "audit and metrics observability" "run_test_group(observability)"
    run_tpl_goal "persistent bearer-token lifecycle" "run_test_group(tokens)"
    run_tpl_goal "controlled source URI policy" "run_test_group(source_policy)"
    run_tpl_goal "IP/CIDR and trusted-proxy policy" "run_test_group(ip_policy)"
    run_tpl_goal "node lifecycle" "run_test_group(lifecycle)"
    run_with_timeout "WebSocket and protocol vectors" \
        "$TPL" -g "(catch((consult('$ROOT/websocket_tests.pl'),websocket_tests),_,fail)->halt(0);halt(1))"
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
    trealla_private_port=$((TEST_PORT_BASE + 6))
    source_port=$((TEST_PORT_BASE + 7))
    ip_policy_port=$((TEST_PORT_BASE + 8))
    swi_actor_port=$((TEST_PORT_BASE + 9))
    swi_actor_home_port=$((TEST_PORT_BASE + 10))

    for candidate_port in "$echo_port" "$reverse_port" "$swi_protocol_port" "$trealla_protocol_port" "$trealla_remote_port" "$trealla_private_port" "$source_port" "$ip_policy_port" "$swi_actor_port" "$swi_actor_home_port"; do
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
    run_with_timeout "Trealla outbound client -> legacy fixture" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(legacy_outbound_test($swi_protocol_port)->halt;halt(1))"
    run_with_timeout "unsupported synchronous peer remains asynchronous" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(sync_legacy_test($swi_protocol_port)->halt;halt(1))"
    run_with_timeout "synchronous peer disconnect" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(sync_connection_loss_fixture_test($swi_protocol_port)->halt;halt(1))"
    stop_background "$swi_protocol_pid"

    start_background "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "source_server($source_port)"
    source_server_pid=$STARTED_PID
    wait_for_port "$source_port" || fail "SWI source fixture did not start on port $source_port"

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($trealla_protocol_port,[load_uri_allowed_origins(['http://127.0.0.1:$source_port']),load_uri_allowed_ip_ranges(['127.0.0.0/8']),max_source_text_bytes(128)])"
    trealla_protocol_pid=$STARTED_PID
    # The native node treats a bare TCP readiness probe as a malformed HTTP
    # request and logs unexpected_eof. Avoid adding noise to successful runs.
    sleep 0.2
    kill -0 "$trealla_protocol_pid" 2>/dev/null || fail "Trealla protocol node did not start on port $trealla_protocol_port"
    run_with_timeout "SWI client -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "protocol_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI client -> Trealla connection thread parity" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "connection_thread_parity_test($trealla_protocol_port),halt"
    run_with_timeout "SWI client -> Trealla reconstructed asynchronous queries" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "rebuilt_query_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI client -> Trealla canonical and legacy asynchronous answers" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "canonical_answer_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI client -> Trealla header answer negotiation and isolation" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "header_answer_client_test($trealla_protocol_port),halt"
    run_with_timeout "browser caller correlation -> Trealla" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "browser_correlation_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI client -> Trealla allowlisted source URI" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "source_uri_client_test($trealla_protocol_port,$source_port),halt"
    run_with_timeout "SWI statechart execution -> Trealla" \
        "$SWIPL" -q -s "$ROOT/swi_statechart_interop.pl" \
        -g "swi_statechart_interop:run($trealla_protocol_port,$source_port),halt"
    run_with_timeout "SWI browser terminal -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "browser_io_client_test($trealla_protocol_port),halt"
    run_with_timeout "SWI nested toplevel binding -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "nested_toplevel_binding_test($trealla_protocol_port),halt"
    run_with_timeout "SWI promise/yield -> Trealla protocol node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "promise_yield_client_test($trealla_protocol_port),halt"

    if [ -f "$TRINITY_NODE_FILE" ]; then
        start_background "$SWIPL" -q \
            -g "use_module('$TRINITY_NODE_FILE'),node:node($swi_actor_port,[profile(actor),auth(open)]),thread_get_message(stop)"
        swi_actor_pid=$STARTED_PID
        wait_for_port "$swi_actor_port" || fail "SWI actor node did not start on port $swi_actor_port"
        run_with_timeout "Unicode remote answers: Trealla -> SWI" \
            "$TPL" -g "consult('$ROOT/unicode_answer_tests.pl'),(catch(unicode_answer_tests:live('http://localhost:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Unicode remote answers: SWI -> SWI" \
            "$SWIPL" -q -s "$ROOT/unicode_answer_tests.pl" \
            -g "node:node($swi_actor_home_port,[profile(actor),auth(open)]),(catch(unicode_answer_tests:live('http://localhost:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Public remote demonitor -> SWI" \
            "$TPL" -g "consult('$ROOT/remote_demonitor_tests.pl'),(catch(remote_demonitor_tests:live('http://localhost:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Termination notifications -> SWI" \
            "$TPL" -g "consult('$ROOT/termination_notification_tests.pl'),(catch(termination_notification_tests:live('http://localhost:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Explicit termination notifications -> SWI" \
            "$TPL" -g "consult('$ROOT/termination_notification_tests.pl'),(catch(termination_notification_tests:explicit_live('http://localhost:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "General remote toplevel creation -> SWI" \
            "$TPL" -g "consult('$ROOT/remote_toplevel_creation_tests.pl'),(catch(remote_toplevel_creation_tests:live('http://localhost:$swi_actor_port','http://127.0.0.1:$source_port/source.pl'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Public synchronous wrappers -> SWI" \
            "$TPL" -g "consult('$ROOT/synchronous_toplevel_tests.pl'),(catch(synchronous_toplevel_tests:live('http://127.0.0.1:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Public runtime properties (swi_native)" \
            "$TPL" -g "consult('$ROOT/runtime_property_tests.pl'),(catch(runtime_property_tests:live('http://127.0.0.1:$swi_actor_port',swi_native),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla first-slice RPC -> SWI" \
            "$TPL" -g "consult('$ROOT/rpc_once_tests.pl'),(catch(rpc_once_tests:live('http://127.0.0.1:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "HTTP first-slice responses -> SWI" \
            "$TPL" -g "consult('$ROOT/http_once_tests.pl'),(catch(http_once_tests:live('http://127.0.0.1:$swi_actor_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla remote statechart text/URI -> SWI" \
            "$TPL" -g "(catch((consult('$ROOT/remote_chart_tests.pl'),remote_chart_tests:live_uri($swi_actor_port,'http://127.0.0.1:$source_port/chart.xml')),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla statechart invocation -> SWI" \
            "$TPL" -g "(catch((consult('$ROOT/remote_statechart_invocation_tests.pl'),remote_statechart_invocation_tests:live($swi_actor_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla -> SWI actor semantic contracts" \
            "$TPL" -g "(catch((consult('$ROOT/distribution_tests.pl'),cross_runtime_actor_contract_test($swi_actor_port)),_,fail)->halt(0);halt(1))"
        run_with_timeout "SWI -> Trealla actor semantic contracts" \
            "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
            -g "trinity_actor_contract_client_test($swi_actor_home_port,'http://127.0.0.1:$trealla_protocol_port','$TRINITY_NODE_FILE'),halt"
        run_with_timeout "Trealla canonical outbound -> SWI" \
            "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(canonical_outbound_test($swi_actor_port)->halt;halt(1))"
        run_with_timeout "Trealla atomic remote named startup -> SWI" \
            "$TPL" -g "(catch((consult('$ROOT/remote_named_tests.pl'),remote_named_tests:remote_named_live_test($swi_actor_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla supervisor halt -> SWI" \
            "$TPL" -g "(catch((consult('$ROOT/remote_supervisor_tests.pl'),remote_supervisor_tests:remote_supervisor_live_test($swi_actor_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla remote alias cleanup -> SWI" \
            "$TPL" -g "(catch((consult('$ROOT/remote_alias_tests.pl'),remote_alias_tests:remote_alias_live_test($swi_actor_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Trealla synchronous outbound -> SWI" \
            "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(sync_outbound_test($swi_actor_port),sync_explicit_close_test($swi_actor_port)->halt;halt(1))"
        run_with_timeout "SWI synchronous calls -> Trealla" \
            "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
            -g "correlation_client_test($trealla_protocol_port,'$TRINITY_NODE_FILE'),halt"
        stop_background "$swi_actor_pid"
    else
        printf '\n=== Actor semantic contracts ===\n'
        printf 'SKIP: set TRINITY_NODE_FILE to the canonical SWI node.pl checkout\n'
    fi

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($trealla_remote_port,[bearer_token(peer,'lineage-test-peer',[execute,internal_transport]),load_uri_allowed_origins(['http://127.0.0.1:$source_port']),load_uri_allowed_ip_ranges(['127.0.0.0/8'])])"
    trealla_remote_pid=$STARTED_PID
    sleep 0.2
    kill -0 "$trealla_remote_pid" 2>/dev/null || fail "remote Trealla protocol node did not start on port $trealla_remote_port"
    run_with_timeout "Public remote demonitor -> Trealla" \
        "$TPL" -g "consult('$ROOT/remote_demonitor_tests.pl'),(catch(remote_demonitor_tests:live('http://localhost:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Termination notifications -> Trealla" \
        "$TPL" -g "consult('$ROOT/termination_notification_tests.pl'),(catch(termination_notification_tests:live('http://localhost:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Explicit termination notifications -> Trealla" \
        "$TPL" -g "consult('$ROOT/termination_notification_tests.pl'),(catch(termination_notification_tests:explicit_live('http://localhost:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "General remote toplevel creation -> Trealla" \
        "$TPL" -g "consult('$ROOT/remote_toplevel_creation_tests.pl'),(catch(remote_toplevel_creation_tests:live('http://localhost:$trealla_remote_port','http://127.0.0.1:$source_port/source.pl'),E,(writeq(E),nl,fail))->halt;halt(1))"
    if [ -f "$TRINITY_NODE_FILE" ]; then
        run_with_timeout "Native SWI first-slice RPC -> Trealla" \
            "$SWIPL" -q -g "use_module('$TRINITY_NODE_FILE'),findall(X,rpc:rpc('http://127.0.0.1:$trealla_remote_port',member(X,[a,b,c,d,e]),[limit(2),once(true)]),[a,b]),findall(X,rpc:rpc('http://127.0.0.1:$trealla_remote_port',member(X,[a,b,c,d,e]),[limit(2),once(false)]),[a,b,c,d,e]),halt"
        run_with_timeout "Unicode remote answers: SWI -> Trealla" \
            "$SWIPL" -q -s "$ROOT/unicode_answer_tests.pl" \
            -g "node:node($swi_actor_home_port,[profile(actor),auth(open)]),(catch(unicode_answer_tests:live('http://localhost:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Unicode remote answers: Trealla -> Trealla" \
            "$TPL" -g "consult('$ROOT/unicode_answer_tests.pl'),(catch(unicode_answer_tests:live('http://localhost:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
        run_with_timeout "Native SWI statechart constructor -> Trealla" \
            "$SWIPL" -q -s "$ROOT/swi_remote_chart_interop.pl" \
            -g "swi_remote_chart_interop:run_uri($swi_actor_home_port,$trealla_remote_port,'http://127.0.0.1:$source_port/chart.xml','$TRINITY_NODE_FILE'),halt"
    fi
    run_with_timeout "Trealla remote statechart text/URI -> Trealla" \
        "$TPL" -g "(catch((consult('$ROOT/remote_chart_tests.pl'),remote_chart_tests:live_uri($trealla_remote_port,'http://127.0.0.1:$source_port/chart.xml')),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla statechart invocation -> Trealla" \
        "$TPL" -g "(catch((consult('$ROOT/remote_statechart_invocation_tests.pl'),remote_statechart_invocation_tests:live($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "SWI public local statechart invocation -> Trealla" \
        "$SWIPL" -q -s "$ROOT/swi_statechart_interop.pl" \
        -g "swi_statechart_interop:run_invocations($trealla_remote_port),halt"
    run_with_timeout "Trealla distributed source isolation" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(distribution_source_isolation_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Trealla validated remote toplevel wrapper" \
        "$TPL" -g "consult('$ROOT/wrapper_option_tests.pl'),(wrapper_options_live_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Trealla explicit and transparent spawn validation" \
        "$TPL" -g "consult('$ROOT/spawn_option_tests.pl'),(spawn_options_live_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Trealla validated RPC and promise HTTP options" \
        "$TPL" -g "consult('$ROOT/rpc_option_tests.pl'),(rpc_options_live_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Public synchronous wrappers -> Trealla" \
        "$TPL" -g "consult('$ROOT/synchronous_toplevel_tests.pl'),(catch(synchronous_toplevel_tests:live('http://127.0.0.1:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Public runtime properties (trealla_native)" \
        "$TPL" -g "consult('$ROOT/runtime_property_tests.pl'),(catch(runtime_property_tests:live('http://127.0.0.1:$trealla_remote_port',trealla_native),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla first-slice RPC -> Trealla" \
        "$TPL" -g "consult('$ROOT/rpc_once_tests.pl'),(catch(rpc_once_tests:live('http://127.0.0.1:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "HTTP first-slice responses -> Trealla" \
        "$TPL" -g "consult('$ROOT/http_once_tests.pl'),(catch(http_once_tests:live('http://127.0.0.1:$trealla_remote_port'),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla promise ownership over WebSocket and HTTP" \
        "$TPL" -g "consult('$ROOT/rpc_ownership_tests.pl'),(rpc_ownership_live_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Trealla WebSocket promise disposal and client isolation" \
        "$TPL" -g "(catch((consult('$ROOT/rpc_namespace_tests.pl'),rpc_namespace_tests:rpc_namespace_live_test($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla WebSocket namespace teardown" \
        "$TPL" -g "(catch((consult('$ROOT/namespace_tests.pl'),namespace_tests:namespace_live_test($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla remote supervisor receiver" \
        "$TPL" -g "(catch((consult('$ROOT/remote_supervisor_tests.pl'),remote_supervisor_tests:remote_supervisor_live_test($trealla_remote_port),remote_supervisor_tests:remote_supervisor_source_test($trealla_remote_port),remote_supervisor_tests:remote_supervisor_extended_test($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    if [ -f "$TRINITY_NODE_FILE" ]; then
        run_with_timeout "Native SWI delegated lineage -> Trealla" \
            "$SWIPL" -q -s "$ROOT/swi_lineage_compat.pl" \
            -g "(catch(swi_lineage_compat:run($swi_actor_home_port,$trealla_remote_port,'$TRINITY_NODE_FILE'),E,(print_message(error,E),fail))->halt;halt(1))"
        run_with_timeout "Native SWI supervisor constructor -> Trealla" \
            "$SWIPL" -q -s "$ROOT/swi_supervisor_compat.pl" \
            -g "swi_supervisor_compat:run($swi_actor_home_port,$trealla_remote_port,'$TRINITY_NODE_FILE'),halt"
    fi
    run_with_timeout "Trealla atomic remote named startup -> Trealla" \
        "$TPL" -g "(catch((consult('$ROOT/remote_named_tests.pl'),remote_named_tests:remote_named_live_test($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla remote alias cleanup -> Trealla" \
        "$TPL" -g "(catch((consult('$ROOT/remote_alias_tests.pl'),remote_alias_tests:remote_alias_live_test($trealla_remote_port)),E,(writeq(E),nl,fail))->halt;halt(1))"
    run_with_timeout "Trealla canonical outbound -> Trealla" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(canonical_outbound_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "Trealla synchronous outbound -> Trealla" \
        "$TPL" -g "consult('$ROOT/distribution_tests.pl'),(sync_outbound_test($trealla_remote_port),sync_explicit_close_test($trealla_remote_port)->halt;halt(1))"
    run_with_timeout "SWI browser terminal -> remote Trealla actor" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "browser_distributed_io_client_test($trealla_protocol_port,'http://127.0.0.1:$trealla_remote_port'),halt"
    stop_background "$trealla_remote_pid"
    stop_background "$trealla_protocol_pid"
    stop_background "$source_server_pid"

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($trealla_private_port,[auth(private),bearer_token(interop,'interop-secret',[execute]),bearer_token(observer,'admin-secret',[admin]),max_call_requests_per_window(1),max_ws_actors_per_principal(1)])"
    trealla_private_pid=$STARTED_PID
    wait_for_port "$trealla_private_port" || fail "private Trealla protocol node did not start on port $trealla_private_port"
    run_with_timeout "SWI auth and ownership -> private Trealla node" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "private_ownership_client_test($trealla_private_port),halt"
    stop_background "$trealla_private_pid"

    start_background "$TPL" -g \
        "consult('$ROOT/distribution.pl'),web_prolog:web_prolog_node($ip_policy_port,[trusted_proxy_ranges(['127.0.0.0/8']),ip_blocklist(['198.51.100.0/24']),max_call_requests_per_window(1),auto_ban_threshold(2),auto_ban_window_seconds(60),auto_ban_seconds(60)])"
    trealla_ip_policy_pid=$STARTED_PID
    wait_for_port "$ip_policy_port" || fail "IP-policy Trealla node did not start on port $ip_policy_port"
    run_with_timeout "SWI client -> Trealla IP gate and auto-ban" \
        "$SWIPL" -q -s "$ROOT/swi_websocket_interop.pl" \
        -g "ip_policy_client_test($ip_policy_port),halt"
    stop_background "$trealla_ip_policy_pid"
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
