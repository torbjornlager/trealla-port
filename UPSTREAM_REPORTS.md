# Trealla upstream requests and bug reports

This document collects Trealla issues discovered while porting the Web Prolog
actor, HTTP, WebSocket, and distribution layers.  It is a staging area for
reports to send upstream: entries should retain the smallest reproducer we can
produce, the affected Trealla version, the practical impact, and the workaround
currently used in this repository.

Unless stated otherwise, the latest observation was made with Trealla Prolog
v3.12.6 on macOS.  Before filing, rerun the reproducer with the latest upstream
build and search the upstream tracker for duplicates.

Status meanings:

- **Ready** — sufficiently specific to file after one clean-current-build run.
- **Needs minimization** — real application evidence exists, but the report
  should first be reduced to a small standalone program.
- **Retest** — observed on an older release; establish whether it remains.

## Feature requests

### FR-001: Allow a module-local definition to replace or shadow a built-in

**Status:** Ready  
**Priority:** High

Trealla reserves built-in predicates such as `send/2` as static procedures and
provides no equivalent of SWI-Prolog's `redefine_system_predicate/1`.  This
prevents a compatibility library from presenting the canonical actor API under
the expected predicate name.

Minimal observation:

```prolog
?- predicate_property(send(_, _), built_in).
true.

?- assertz((send(_, _) :- true)).
error(permission_error(modify, static_procedure, send/2), assertz/1).
```

Desired behavior: an explicit, opt-in mechanism that allows a module to define
its own `send/2` without changing the system predicate globally.  An API similar
to `redefine_system_predicate/1`, or well-defined module-local shadowing, would
be sufficient.

Impact: the SWI actor implementation exports `send/2`; the Trealla port must
instead expose the `!/2` operator and keep its internal `actor_send/2` helper
private.  This is an API compatibility difference rather than merely an
implementation detail.

### FR-002: Add thread-local dynamic predicates

**Status:** Ready  
**Priority:** Medium

Trealla has no `thread_local/1` directive.  The actor runtime therefore stores
per-actor deferred receive state and parent state in the thread-local
blackboard (`bb_put/2` and `bb_get/2`) rather than using the declarative
thread-local facts used by the SWI implementation.

Desired behavior: support `thread_local/1`, with semantics close enough to SWI
for portable thread-aware libraries.

Current workaround: see the deferred-message and parent bookkeeping in
`actors.pl`.

### FR-003: Provide a supported HTTP-to-WebSocket upgrade handoff

**Status:** Needs minimization  
**Priority:** Medium

The standard HTTP server path writes ordinary HTTP response headers and closes
the socket, so it cannot hand the already-parsed request stream to a WebSocket
handler.  The port implements a separate socket server, parses HTTP itself, and
uses `ws_accept/3` to serve `/call` and `/ws` on one port.

Desired behavior: an HTTP server API that permits a handler to take ownership
of the connection after returning `101 Switching Protocols`, without an
automatic `Content-Length`, `Connection: close`, or stream close.

Current workaround: the direct socket server and protocol handoff in `node.pl`
and `websocket.pl`.

### FR-004: Add standard URI query percent-encoding helpers

**Status:** Ready  
**Priority:** Low

Trealla's standard library has no equivalent of `uri_encoded/3` or
`www_form_encode/2`.  The RPC client and HTTP node carry local RFC 3986
encoders/decoders as a result.

Desired behavior: a maintained library predicate for percent-encoding and
decoding URI query components.

### FR-005: Add an atomic process-wide counter such as `flag/3`

**Status:** Ready  
**Priority:** Low

The standalone SWI actor implementation does not require a special opaque
reference primitive.  Its `make_ref/1` increments a named process-wide counter
with `flag/3` and returns `ref(N)`.  Trealla v3.12.6 has no `flag/3`.

Minimal observation:

```prolog
?- flag(actor_ref, N, N + 1).
error(existence_error(procedure, flag/3), flag/3).
```

Desired behavior: provide an atomic named counter compatible with SWI-Prolog's
`flag/3`, or an equivalent primitive from which a collision-free `make_ref/1`
can be implemented.  This would also be useful for generating local actor IDs.

Current workaround: the port keeps a dynamic counter and increments it while
holding an explicitly created Trealla mutex.  This provides process-lifetime
uniqueness but is considerably more machinery than the SWI implementation.

The distributed SWI implementation takes a different approach: its
`hook_make_ref/1` uses a ten-digit cryptographically random ID, but `make_id/1`
checks the shared actor/reservation tables and reserves the selected ID while
holding a mutex.  Thus it is not relying on randomness alone for uniqueness.
The same application-level check-and-retry approach is a viable Trealla
workaround and does not require a new opaque-reference primitive.

## Bug reports

### BUG-001: Abrupt in-process WebSocket teardown can crash Trealla

**Status:** Ready  
**Priority:** High

When the test process contains both the WebSocket server and client and the
server drops the connection during or immediately after a remote spawn,
Trealla can crash after the logical assertion has already passed.  Observed
outcomes include exit status 139 and:

```text
Assertion failed: (a), function get_choice, file builtins.h, line 178.
```

Repository reproducers:

```sh
tpl -q -g "consult(distribution_tests),\
            distribution_spawn_disconnect_test(39903),halt"

tpl -q -g "consult(distribution_tests),\
            transparent_connection_drop_test(39904),halt"
```

The crash is timing-sensitive.  Separate-process node termination and restart
works correctly, which points to same-process stream/thread teardown rather
than the Web Prolog state machine itself.

Current workaround: use separate processes for end-to-end connection-failure
tests and avoid treating immediate same-process teardown as a reliable test
harness boundary.

### BUG-002: `thread_detach/1` hangs inside a thread's `at_exit` hook

**Status:** Needs minimization  
**Priority:** High

Calling `thread_detach/1` from the terminating thread's `at_exit` hook does not
return.  The actor runtime originally followed the SWI lifecycle pattern and
would hang during cleanup.

Current workaround: every actor is created with `detached(true)` up front, and
the `at_exit` cleanup in `actors:stop/2` never calls `thread_detach/1`.

Evidence: `actors.pl` documents the workaround immediately above `stop/2`.
A standalone two-predicate reproducer should be prepared before filing.

### BUG-003: `thread_property/2` reports `status(running)` inside `at_exit`

**Status:** Needs minimization  
**Priority:** Medium

Inside a terminating thread's `at_exit` hook, querying its status still yields
`running`; the final success, failure, or exception outcome is unavailable.
This differs from the lifecycle information used by the SWI actor runtime.

Current workaround: `actors:start/4` catches the actor goal and records its
outcome explicitly in `exit_reason/2`; `actors:stop/2` consumes that fact to
construct `down/3`.

Upstream question: if `running` is intentional during the hook, Trealla needs
another supported way for an exit hook to inspect the thread's final outcome.

### BUG-004: `http_open/3` leaves socket-opening choicepoints

**Status:** Needs minimization  
**Priority:** Medium

On v3.12.6, a successful `http_open/3` leaves internal socket-opening
choicepoints.  When the RPC predicate later backtracks for additional Prolog
answers, execution can re-enter those connection internals instead of staying
within the established HTTP response.

Current workaround: `rpc.pl` wraps the successful `http_open/3` call in
`once/1` before exposing answer backtracking.

Expected behavior: after a connection has been selected successfully,
`http_open/3` should be deterministic unless its public contract explicitly
documents alternative connections on backtracking.

### BUG-005: TLS client verification does not verify hostnames

**Status:** Needs upstream security review  
**Priority:** High

Trealla v3.12.6 can establish an encrypted `wss://` socket.  Without
`certfile/1` it does not verify the peer; with `certfile/1` it enters the
certificate-verification path but does not verify that the certificate name
matches the requested host.

Impact: callers can obtain encryption without server identity verification,
which is unsafe for production WebSocket and HTTPS clients.

Current workaround: terminate TLS in a proxy with complete certificate and
hostname verification.

Desired behavior: secure defaults plus explicit CA/trust-store and hostname
verification controls, with verification enabled for ordinary `wss://` and
`https://` clients.

### BUG-006: `findnsols(count(N), ...)` observes mutations only in the same catch frame

**Status:** Retest and minimize  
**Priority:** Medium

In the versions used while building the port, a `count/1` cell passed to
`findnsols/4` did not reliably observe `nb_setarg/3` updates made through a
nested predicate when the cell crossed a `catch/3` frame.  Allocating the cell,
calling `findnsols/4`, and mutating it inside one `catch/3` made mid-stream page
size changes work.

Current workaround: `toplevel_actors:run_call/6` deliberately keeps the
complete paged enumeration and mutable `count/1` cell in one catch frame.

This area changed around Trealla v2.99.12 and has been associated in the
project notes with upstream issue #1026.  Confirm the exact current behavior
and issue identity before filing a new report.

### BUG-007: High-volume actor thread benchmarks crash intermittently

**Status:** Retest  
**Priority:** High if still present

`Benchmarking/bm-ping-pong.pl` and `Benchmarking/bm-spawning.pl` were stable at
up to roughly 1,000 iterations but crashed approximately 30% of runs at
10,000 or more iterations on Trealla v2.98.10 and v2.99.12.

The project notes associate this with upstream issue #1026.  Application tests
use far fewer actor round trips and are unaffected.  Rerun on v3.12.6 and the
latest upstream build, capture the smallest failing iteration count and stack
trace, and confirm whether this is the same defect as BUG-006 or a separate
threading/GC issue.

## Compatibility gaps worth tracking, but not yet bug reports

These missing facilities increase porting work but need a clearer upstream
scope or an existing-library survey before becoming individual requests:

- `library(settings)`
- `library(debug)`
- a PlUnit-compatible test framework
- `predicate_property(_, number_of_clauses(N))`

## Resolved or obsolete observations

- `atom_number/2` now supports number-to-atom conversion in v3.12.6.  An old
  comment in this port says it only supports parsing; that comment is stale and
  should not be filed upstream.
- Positive `thread_get_message/3` timeouts are available and are used by the
  current actor receive loop.  The older timer-actor workaround is no longer an
  upstream request.

## Before filing an item

1. Test the smallest reproducer with the newest Trealla commit.
2. Record OS, architecture, compiler, and build flags (especially OpenSSL and
   sanitizers).
3. Include exact stdout/stderr and exit status for crashes.
4. State whether the defect reproduces without this repository.
5. Link the workaround here and any relevant test.
6. Add the upstream issue URL and change the status to **Filed**.
