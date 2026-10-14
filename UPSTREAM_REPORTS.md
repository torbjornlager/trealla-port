# Trealla upstream requests and bug reports

This document collects Trealla issues discovered while porting the Web Prolog
actor, HTTP, WebSocket, and distribution layers.  It is a staging area for
reports to send upstream: entries should retain the smallest reproducer we can
produce, the affected Trealla version, the practical impact, and the workaround
currently used in this repository.

Unless stated otherwise, historical observations were made with Trealla Prolog
v3.12.6 on macOS. Current outstanding items were audited with v3.13.10. Before
filing, rerun the reproducer with the latest upstream build and search the
upstream tracker for duplicates. `UPSTREAM_OUTSTANDING.md` is the short,
maintainer-ready summary of this ledger.

Status meanings:

- **Ready** — sufficiently specific to file after one clean-current-build run.
- **Needs minimization** — real application evidence exists, but the report
  should first be reduced to a small standalone program.
- **Retest** — observed on an older release; establish whether it remains.

## v3.13.10 upstream audit

Trealla v3.13.10 implements SWI-compatible absolute `deadline/1` options for
`thread_get_message/3` and corrects interference between concurrent sleeps.
The expired-deadline reproducer now prints `none`. Five runs of the concurrent
one-, three-, and two-second `sleep/1` reproducer took 3.001–3.004 seconds, and
the equivalent `thread_sleep/1` probe took 3.002 seconds. FR-010 and BUG-021
are therefore resolved. The port now uses the native deadline and sleep
facilities, and its complete unit and bidirectional SWI interoperability suite
passes on macOS arm64.

## v3.13.4 upstream audit

Trealla v3.13.4 pins frames referenced by attributed-variable, blackboard, and
`b_setval/2` stores, and corrects tail-call eligibility. Its new store-pinning
and accumulator regressions pass locally. These changes address the class of
engine lifetime problem suspected in BUG-020, but that historical application
failure was already not reproducible on a clean v3.13.2 build; it remains a
historical record rather than a report retroactively claimed as fixed.

The complete Web Prolog unit and bidirectional SWI interoperability suites pass
against v3.13.4 on macOS arm64. FR-010 remains open, and BUG-021 remains
reproducible: three concurrent one-, three-, and two-second sleeps took
4.196, 4.167, and 4.134 seconds. Ten 10,000-message ping-pong stress runs also
passed. The recursive spawning benchmark passed at 1,000 and 2,000 generations
but exceeded a 20-second probe at 5,000; that is not yet a minimized runtime
report.

## v3.13.3 upstream audit

Trealla v3.13.3 contains one runtime commit after v3.13.2: a predicate cached
by a call is now cached afresh after that predicate is abolished. The complete
Web Prolog unit and bidirectional SWI interoperability suites pass against the
release on macOS arm64. FR-010 remains open: `thread_get_message/3` still
rejects `deadline/1` with `domain_error(read_option, deadline(...))`.

## v3.13.2 upstream audit

Trealla v3.13.2 incorporates the maintainer's `trealla-port-review` work.  The
upstream history explicitly resolves the original nine feature requests in
this document: FR-001 through FR-009.  The release adds application-defined
`send/2`, `thread_local/1`, `http_switch_protocol/2`, URI form encoding,
atomic `flag/3`, temporary-module lifecycle predicates, `library(sandbox)`,
inference and thread stack limits, and independent TLS server-name/address
handling.

The same history explicitly addresses BUG-002, BUG-004 through BUG-006,
BUG-008, BUG-010, and BUG-012 through BUG-019.  Those entries remain below as
historical records of the original symptoms and workarounds.  BUG-001,
BUG-003, BUG-007, BUG-009, and BUG-011 do not have a corresponding fix named
in the v3.13.2 history and still require focused retesting before their status
is changed.

BUG-006 nevertheless still fails its application regression when compound
cells are restored to ordinary literal construction: the toplevel paging suite
hangs at its target-switch test. The explicit `functor/3` plus `arg/3`
construction therefore remains pending a smaller v3.13.2 reproducer.

BUG-014 also fails its application retest: directly closing the registered
listener from the shutdown thread leaves the owner blocked in `accept`, and
the node lifecycle suite times out. The loopback wake connection remains in
place pending a focused v3.13.2 reproducer.

BUG-017's broad original description is no longer independently reproducible:
a conventional dynamically asserted call to an imported meta-predicate keeps
its caller module on v3.13.2. Loading the expanded actor clause body without
the receive-qualification pass still makes regression 102 fail when the
selected body calls the next private predicate. The remaining trigger must be
narrowed to temporary-module runtime dispatch before filing.

The port's full manual, WebSocket, distribution, SWI-interoperability, and
deployment suites pass against v3.13.2.  Removing the compatibility
workarounds is deliberately a separate follow-up: each should first be
replaced with its new native facility and covered by the same regression
test.

A later clean retest could not reproduce BUG-020: both a repeatedly replaced
`thread_local/1` deferred list and pre-guard `nb_setval/2` storage passed the
complete unit suite on v3.13.2. The port retains its established
non-backtrackable representation, but BUG-020 must not be filed without a new
standalone failure.

## Feature requests

### FR-001: Allow a module-local definition to replace or shadow a built-in

**Status:** Resolved in v3.13.2
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

Port result: the Trealla actor implementation now exports canonical `send/2`;
the `!/2` operator remains an alias.

### FR-002: Add thread-local dynamic predicates

**Status:** Resolved in v3.13.2
**Priority:** Medium

At the time of the report Trealla had no `thread_local/1` directive. The actor runtime therefore stored
per-actor deferred receive state and parent state in the thread-local
blackboard (`bb_put/2` and `bb_get/2`) rather than using the declarative
thread-local facts used by the SWI implementation.

Desired behavior: support `thread_local/1`, with semantics close enough to SWI
for portable thread-aware libraries.

v3.13.2 port status: mutable actor state now uses native per-thread
non-backtrackable globals. See BUG-020 for a separate `thread_local/1`
list-replacement observation.

### FR-003: Provide a supported HTTP-to-WebSocket upgrade handoff

**Status:** Resolved in v3.13.2
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

Port result: `http_switch_protocol/2` is available. The direct server remains
an architectural choice because it owns Web Prolog's connection registry,
bounded shutdown, authentication, and governance lifecycle.

### FR-004: Add standard URI query percent-encoding helpers

**Status:** Resolved in v3.13.2
**Priority:** Low

Older Trealla releases had no equivalent of `www_form_encode/2`; the RPC
client and HTTP node consequently carried local encoders.

Desired behavior: a maintained library predicate for percent-encoding and
decoding URI query components.

Port result: RPC encoding and node query decoding use native
`www_form_encode/2`, including its UTF-8 handling.

### FR-005: Add an atomic process-wide counter such as `flag/3`

**Status:** Resolved in v3.13.2
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

v3.13.2 port status: `make_ref/1` now uses native atomic `flag/3`, followed by
the shared actor/reference reservation check.

The distributed SWI implementation takes a different approach: its
`hook_make_ref/1` uses a ten-digit cryptographically random ID, but `make_id/1`
checks the shared actor/reservation tables and reserves the selected ID while
holding a mutex.  Thus it is not relying on randomness alone for uniqueness.
The same application-level check-and-retry approach is a viable Trealla
workaround and does not require a new opaque-reference primitive.

### FR-006: Expose temporary-module lifecycle operations

**Status:** Resolved in v3.13.2
**Priority:** Medium

Actor source isolation needs a fresh module for each actor and deterministic
destruction when that actor terminates. At the time of the report Trealla
could create modules while loading a file, but its public Prolog API had no equivalent of SWI-Prolog's
`in_temporary_module/3` or a supported module-destruction predicate.

Desired behavior: a scoped temporary-module operation, or explicit supported
create/delete operations, that remove the module's predicates, operators,
imports, and module-table entry after use.

v3.13.2 port status: actor modules are explicitly created and reclaimed with
public `destroy_module/1` at actor termination.

### FR-007: Provide an extensible goal-safety analysis library

**Status:** Resolved in v3.13.2
**Priority:** Medium

At the time of the report Trealla had no equivalent of SWI-Prolog's `library(sandbox)`. A node accepting
goals and source from remote peers consequently has to maintain its own walker,
safe-primitive catalog, meta-call guards, directive policy, and source
validation rules.

Desired behavior: a module-aware safety API that can validate goals and source
before execution, recognizes the meta-arguments of standard predicates, and
allows applications to declare additional safe primitives and meta-predicates.
Runtime checking must remain possible when a callable is initially a variable.

v3.13.2 port status: `sandbox_policy.pl` delegates primitive safety analysis
to `library(sandbox)` while retaining Web Prolog's profile, capability,
source, and scoped-mutation policy.

### FR-008: Add inference and per-thread stack ceilings

**Status:** Resolved in v3.13.2
**Priority:** High

The SWI node bounds public calls with `call_with_inference_limit/3` and actor
memory with the `stack_limit(Bytes)` thread option. Trealla v3.12.6 provided
neither facility: `call_with_inference_limit/3` is absent and
`thread_create/3` rejects `stack_limit/1` with
`domain_error(thread_option, stack_limit(_))`.

Desired behavior: a catchable inference-limit primitive and a supported
per-thread stack/heap ceiling. Together with an application-level actor cap,
these allow a public node to bound CPU work and process memory without placing
every individual query in a separate OS process.

v3.13.2 port status: queries use `call_with_inference_limit/3`, and actor
creation passes the configured `stack_limit/1` thread option. Container limits
remain a defense-in-depth boundary.

### FR-009: Separate a socket's connection address from its TLS server name

**Status:** Resolved in v3.13.2
**Priority:** Medium

A DNS-rebinding-resistant HTTPS client needs to resolve and authorize a
numeric destination, connect to that exact address, and still send the
original host name as TLS SNI (and eventually verify it as the certificate
identity). Trealla v3.12.6 derived both the TCP
destination and TLS server name from the same address term.

Connecting to the authorized numeric address therefore pins the destination
but also supplies that address, rather than the URI host, as SNI. Connecting
by host name preserves SNI but performs another resolution inside the socket
primitive, reopening the authorization-to-connection race.

Desired behavior: a supported client option such as
`tls_server_name(Host)`/`server_name(Host)`, independent of the TCP address,
or a public TLS-upgrade API that accepts the authenticated host name after a
caller-controlled TCP connection has been established. A way to obtain all
candidate resolver addresses would also allow policy-checking each candidate
without losing normal address-family fallback.

v3.13.2 port status: every resolver result is policy-checked, the connection
uses an approved numeric address, and `server_name(Host)` preserves SNI and
certificate identity verification.

### FR-010: Support absolute deadlines in `thread_get_message/3`

**Status:** Resolved in v3.13.10
**Priority:** Medium

Trealla's SWI-compatible `thread_get_message/3` accepts `timeout(Seconds)` but
not SWI-Prolog's `deadline(AbsoluteTime)` option. A selective receive loop must
therefore recompute a shrinking relative timeout after every unrelated
message. Passing an absolute deadline directly is simpler and prevents a
restarted relative timeout from extending the caller's requested wait.

Repository reproducer:
`reproducers/fr-010-thread-get-message-deadline.pl`.

```sh
tpl -q -f reproducers/fr-010-thread-get-message-deadline.pl \
    -g "reproducer,halt"
```

Trealla v3.13.2 through v3.13.4 report:

```text
error(domain_error(read_option,deadline(...)),thread_get_message/3)
```

The same program under SWI-Prolog prints `none`, meaning the already-expired
deadline makes the call fail immediately without an exception. Desired
behavior: accept `deadline(Time)` as an alternative to `timeout(Seconds)`,
using the same absolute time basis as `get_time/1`. No matching Trealla issue
was found in an upstream issue search on 2026-10-12.

v3.13.10 result: the reproducer prints `none`, matching SWI-Prolog. The actor
receive loop now passes its absolute deadline directly to
`thread_get_message/3`.

## Bug reports

### BUG-001: Abrupt in-process WebSocket teardown can crash Trealla

**Status:** Retest
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

**Status:** Resolved in v3.13.3
**Priority:** High

Calling `thread_detach/1` from the terminating thread's `at_exit` hook does not
return.  The actor runtime originally followed the SWI lifecycle pattern and
would hang during cleanup.

Current workaround: every actor is created with `detached(true)` up front, and
the `at_exit` cleanup in `actors:stop/2` never calls `thread_detach/1`.

Evidence: `actors.pl` documents the workaround immediately above `stop/2`.
Trealla's current regression test refuses self-detach with
`permission_error(detach, thread, ...)` and allows an existing join to obtain
the real status; it no longer hangs.

### BUG-003: `thread_property/2` reports `status(running)` inside `at_exit`

**Status:** Resolved in v3.13.3
**Priority:** Medium

Inside a terminating thread's `at_exit` hook, querying its status still yields
`running`; the final success, failure, or exception outcome is unavailable.
This differs from the lifecycle information used by the SWI actor runtime.

Current workaround: `actors:start/4` catches the actor goal and records its
outcome explicitly in `exit_reason/2`; `actors:stop/2` consumes that fact to
construct `down/3`.

Upstream question: if `running` is intentional during the hook, Trealla needs
another supported way for an exit hook to inspect the thread's final outcome.

v3.13.3 retest: `thread_property(Me, status(Status))` inside the hook reports
`status(true)` for a successfully completed thread, and `thread_join/2` also
returns `true`. In v3.13.10 the port removed its normal-outcome recording
wrapper and now reads success, failure, and exceptions from native thread
status. It records only explicit actor `exit/1` reasons, which must hide the
internal unwind exception and obey first-exit-wins semantics.

### BUG-004: `http_open/3` leaves socket-opening choicepoints

**Status:** Resolved in v3.13.2
**Priority:** Medium

On v3.12.6, a successful `http_open/3` leaves internal socket-opening
choicepoints.  When the RPC predicate later backtracks for additional Prolog
answers, execution can re-enter those connection internals instead of staying
within the established HTTP response.

v3.13.2 port status: the `once/1` wrapper is gone and `http_open/3` is called
directly.

Expected behavior: after a connection has been selected successfully,
`http_open/3` should be deterministic unless its public contract explicitly
documents alternative connections on backtracking.

### BUG-005: TLS client verification does not verify hostnames

**Status:** Resolved in v3.13.2
**Priority:** High

Trealla v3.12.6 can establish an encrypted `wss://` socket.  Without
`certfile/1` it does not verify the peer; with `certfile/1` it enters the
certificate-verification path but does not verify that the certificate name
matches the requested host.

Impact: callers can obtain encryption without server identity verification,
which is unsafe for production WebSocket and HTTPS clients.

v3.13.2 port status: ordinary clients verify the chain and host name by
default, and pinned-address source loading supplies the URI host separately.

Desired behavior: secure defaults plus explicit CA/trust-store and hostname
verification controls, with verification enabled for ordinary `wss://` and
`https://` clients.

### BUG-006: Mutable compound cells can retain an argument from an earlier thread

**Status:** Retest and minimize  
**Priority:** Medium

In the versions used while building the port, a `count/1` cell passed to
`findnsols/4` did not reliably observe `nb_setarg/3` updates made through a
nested predicate when the cell crossed a `catch/3` frame. Allocating the cell,
calling `findnsols/4`, and mutating it inside one `catch/3` made mid-stream page
size changes work.

A second v3.12.6 symptom appeared when two WebSocket sessions ran in sequence.
The code created a fresh mutable answer target with
`Target = target(Target1)` inside `run_call/8`. The second PTCP received and
printed its new `Target1`, but after its goal resumed from acknowledged browser
I/O, `arg(1, Target, Out)` returned the first PTCP's target. Its success event
was therefore sent to the closed first connection. Constructing the cell
explicitly with `functor(Target, target, 1), arg(1, Target, Target1)` avoids the
cross-thread retention. The same defensive construction is now used for the
mutable `count/1` cell.

Current workaround: `toplevel_actors:run_call/8` deliberately keeps the
complete paged enumeration and both mutable cells in one catch frame, and
constructs those cells with `functor/3` plus `arg/3` rather than unification
with a compound literal.

v3.13.10 retest: replacing the explicit construction with `count(Limit)`,
`target(Target)`, and `count(0)` reproducibly stalls the paging group as t14
resumes the suspended enumeration through `toplevel_next/1`. The workaround
therefore remains required.

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

### BUG-008: `thread_signal/2` intermittently fails to interrupt a CPU-bound thread

**Status:** Resolved in v3.13.2
**Priority:** High

On Trealla v3.12.6 for macOS arm64, an actor running `(repeat, fail)` does not
reliably process an `exit/2` implemented with `thread_signal/2`. In 30 fresh
process runs of the former registration-cleanup test, 22 delivered the
expected `down/3` message and 8 remained blocked for more than three seconds.

The application-level shape is:

```prolog
spawn((repeat, fail), Pid, [monitor(true), link(false)]),
exit(Pid, reason),
receive({down(Pid, _, reason) -> true}).
```

The registration test was changed to use an actor blocked in `receive/1`,
because that test is intended to verify automatic name cleanup rather than
preemptive interruption. `toplevel_abort/1` remains the functional coverage
for interrupting a running goal.

`thread_cancel/1` is not a viable fallback in this configuration: a direct
50-process probe that recorded the desired exit reason and then cancelled the
actor exited with status 139 in all 50 processes. Both observations need
standalone reproducers against the latest upstream commit before filing; they
may be related to BUG-007 or to Trealla's current task/thread cancellation
work.

### BUG-009: A module-qualified actor trampoline misexecutes a conjunction

**Status:** Resolved in v3.13.2
**Priority:** Medium

On Trealla v3.12.6, a conjunction read from a WebSocket command and passed
through the actor module's meta-predicate trampoline executes its first arm,
then can raise `existence_error(procedure, (',')/2)`.  This affected native
Web Prolog `spawn` commands such as a remote spawn followed by a monitored
receive.  Direct `call(user:(write(a),write(b)))` succeeds, so the trigger
appears to involve the combination of a goal read as data, module
qualification, a meta-predicate, and execution in a new thread.

v3.13.2 port status: the structural conjunction trampoline is gone; the
browser-to-remote-node interoperability path now uses native control-term
execution.

### BUG-010: `listing(Module:PI)` lists the calling module instead

**Status:** Resolved in v3.13.2
**Priority:** Medium

Trealla v3.12.6 accepts a module-qualified predicate indicator in
`listing/1`, but appears to discard the resolved module and enumerate the
calling module's predicate database. This prevents `src_predicates/1` from
serializing a private static predicate in another source module. Direct
`clause/2` access is not a substitute because Trealla rejects access to such
static private predicates.

v3.13.2 port status: `src_predicates/1` calls `listing(Module:PI)` directly.
Output capture remains serialized because `listing/1` has no stream argument.

### BUG-011: `call_with_time_limit/2` discards goal choicepoints

**Status:** Not a bug (SWI-compatible)
**Priority:** Medium

Trealla v3.12.6 implements `call_with_time_limit/2` by applying `once/1` to
its goal. A nondeterministic goal consequently exposes only its first answer:

```prolog
?- findall(X, call_with_time_limit(1, member(X, [a,b])), Xs).
Xs = [a].
```

The historical expectation was `Xs = [a,b]`. A clean audit found that
SWI-Prolog 10.1.3 also returns `Xs = [a]`: `call_with_time_limit/2` is
semidet in both systems. This item must not be filed as a compatibility bug.

Current workaround: the PTCP and HTTP producer paths use Trealla's internal
reusable `$alarm` primitive. The PTCP cancels its alarm while a result page is
suspended awaiting the client, as does the HTTP producer while it waits for a
continuation request. Each creates a fresh alarm immediately before resuming
its choicepoint. This preserves choicepoints without charging client think-time
to the execution limit.

### BUG-012: `crypto_n_random_bytes/2` repeats predictable output across processes

**Status:** Resolved in v3.13.2
**Priority:** Critical for credential generation

Trealla v3.12.6 implements `crypto_n_random_bytes/2` with C `rand()`, seeded
once with `time(NULL)`. Fresh processes started in the same second therefore
produce identical byte sequences:

```sh
for i in 1 2 3; do
  tpl -g "crypto_n_random_bytes(16,B),writeq(B),halt"
  echo
done
```

Observed output:

```text
[28,194,191,34,120,145,237,31,137,35,43,88,71,237,26,244]
[28,194,191,34,120,145,237,31,137,35,43,88,71,237,26,244]
[28,194,191,34,120,145,237,31,137,35,43,88,71,237,26,244]
```

The source itself currently carries the comment `FIXME: not truly crypto
strength`, but the predicate name and its use by `library(uuid)` can lead
applications to treat it as a CSPRNG.

Desired behavior: obtain bytes from the operating-system cryptographic random
source and fail closed when that source is unavailable. If compatibility
requires retaining the current PRNG, it should have a name that does not imply
cryptographic security.

v3.13.2 port status: token generation now uses native
`crypto_n_random_bytes/2`.

### BUG-013: An IPv6 wildcard listener reports IPv4 peers as `0.0.0.0`

**Status:** Resolved in v3.13.2
**Priority:** High for access-control servers

On macOS with Trealla v3.12.6, a server opened on the wildcard address may
select an IPv6 listening socket. An IPv4 client can connect through the
dual-stack listener, but `socket_server_accept/4` reports its peer as
`0.0.0.0` rather than the client's address.

Minimal server (run `curl http://127.0.0.1:39999/` in another shell):

```sh
tpl -g "use_module(library(sockets)),socket_server_open(39999,S,[]),socket_server_accept(S,Peer,C,[]),writeq(Peer),nl,close(C),socket_server_close(S),halt"
```

Observed peer begins with `0.0.0.0`; expected is `127.0.0.1`.

The underlying `tpl_accept()` currently allocates `struct sockaddr_in` and
passes it to `accept()` even when the listening socket is IPv6. It then calls
`inet_ntop(AF_INET, ...)` unconditionally. An IPv4-mapped IPv6 peer is
therefore decoded using the wrong address family.

Impact: IP allowlists, blocklists, trusted-proxy checks, per-client quotas,
and audit attribution cannot safely use the reported peer address.

Desired behavior: accept into `sockaddr_storage`, inspect `ss_family`, and
format either the IPv4 or IPv6 address accordingly.

v3.13.2 port status: the peer-address defect is fixed. The node retains an
explicit IPv4 wildcard as its conservative deployment default, but callers
may select another interface with `bind_address/1`.

### BUG-014: Cross-thread server close does not wake a blocked accept

**Status:** Resolved in v3.13.3
**Priority:** Medium

On macOS with Trealla v3.12.6, one thread can call
`socket_server_close/1` successfully on a listening socket owned by another
thread, while the owner remains blocked in `socket_server_accept/4`. A new
client can still connect and satisfy that accept after the reported close.

Minimal outline:

```prolog
:- dynamic held/2.

server :-
    socket_server_open('127.0.0.1':Port, Server, []),
    assertz(held(Port, Server)),
    socket_server_accept(Server, _, Client, []),
    close(Client), socket_server_close(Server).

test :-
    thread_create(server, Thread, []), sleep(0.1),
    held(Port, Server), socket_server_close(Server),
    socket_client_open('127.0.0.1':Port, Client, []),
    close(Client), thread_join(Thread, _).
```

The client connection succeeds and releases the accept. Expected behavior is
either that closing the server reliably interrupts the blocked accept, or
that Trealla provides a supported cross-thread listener-stop operation with
that effect.

Impact: a server cannot implement bounded graceful shutdown merely by closing
its listening stream from a control thread.

Current workaround: `node.pl` marks the listener as stopping and makes one
local wake-up connection. The accept loop observes the flag, closes the wake
connection, and closes its own listener from the owning thread.

v3.13.3 retest: the upstream `socket_accept_closed.pl` regression passes.
Closing the listener wakes the blocked accept with an `existence_error`, and a
new connection is refused. The node's explicit wake connection can remain an
application-level shutdown mechanism, but this is no longer an upstream bug.

v3.13.10 application retest: removing the explicit wake connection and closing
the listener directly makes node lifecycle test t95 hang in the blocked accept
loop. The smaller upstream regression and the application still differ, so the
node retains its owner-thread wake-and-close sequence pending minimization.

### BUG-015: A TLS-disabled build reports `resource_error(memory)` for SSL

**Status:** Resolved in v3.13.2
**Priority:** Low

On macOS arm64 with Trealla v3.12.6 built using `make NOSSL=1`, requesting an
SSL client socket immediately raises `error(resource_error(memory),'$client'/5)`.
This is not evidence of a defect in an SSL-enabled build; it is misleading
feature-unavailability reporting in the explicitly TLS-disabled build used by
this repository's default build helper.

Start a disposable TLS peer (using any test certificate and key):

```sh
openssl s_server -quiet -accept 43129 -cert cert.pem -key key.pem -www
```

Then run:

```sh
tpl -g "use_module(library(sockets)),catch(socket_client_open('127.0.0.1':43129,S,[ssl(true)]),E,(writeq(E),nl,halt(2))),close(S),halt"
```

Observed result:

```text
error(resource_error(memory),'$client'/5)
```

The same failure is visible through
`http_open('https://127.0.0.1:43129/', Stream, [])`. Expected behavior is a
specific `existence_error(feature, ssl)` or similar availability error, never
a spurious memory-exhaustion exception.

v3.13.2 port status: TLS-disabled builds now report feature unavailability
accurately. TLS use still naturally requires an OpenSSL-enabled build or a
terminating proxy.

### BUG-016: Blocking inside a receive body can lose its deferred tail

**Status:** Resolved in v3.13.2
**Priority:** High

The actor receive loop keeps unmatched mailbox messages in a thread-local
blackboard list. On Trealla v3.12.6, if a matching receive body blocks in
`thread_get_message/3` before recursively receiving again, the next deferred
message is no longer observed. The browser terminal exposed this when
`flush/0` drained two messages: it emitted the first, waited for the browser's
acknowledgement, then returned success without emitting the second. Both
messages were demonstrably enqueued before `flush/0` began.

The same recursive drain works when its body does not block, so the trigger
appears to involve resuming a receive continuation after a cross-thread queue
wait. It may be related to the mutable-term/cross-thread continuation symptoms
in BUG-006, but the exact runtime mechanism has not yet been isolated.

v3.13.2 port status: `flush/0` again receives and emits each message in one
recursive pass. The acknowledged browser interoperability regression passes.

### BUG-017: Receive bodies were invoked without their caller module

**Status:** Not an independently demonstrated Trealla bug
**Priority:** High

An actor-private module dynamically asserts a clause whose body calls the
imported `actors:receive/1` meta-predicate. Trealla v3.12.6 qualifies the
receive closure as belonging to `actors`, rather than to the private module
where the clause was asserted. An unqualified predicate called from the
selected receive body is consequently looked up in `actors` and raises
`existence_error(procedure, ...)`, even though that predicate exists in the
private source module.

The application-level reproducer is the selective-receive tutorial:

```prolog
wait_hello :-
    receive({hello -> writeln('Got hello.'), wait_goodbye}).

wait_goodbye :-
    receive({goodbye -> writeln('Got goodbye.')}).
```

Calling `wait_hello/0` after queueing `goodbye` and then `hello` prints the
first line and formerly failed at `wait_goodbye/0`. The equivalent statically
compiled SWI implementation retains the source module.

Current workaround: the isolation loader rewrites `receive/1,2` in submitted
source before assertion. It explicitly qualifies the receive clause set and
each executable receive-body leaf with the fresh actor module. Regression test
102 exercises the complete tutorial sequence, including deferred-message
selection.

v3.13.2 retest: a standalone temporary module that asserts a clause calling a
simple imported meta-predicate retains the correct caller context. The broad
meta-predicate claim above is therefore not ready to file. The application
regression still requires its qualification bridge, so any future report must
first isolate the additional temporary-module, runtime-term, or receive-DSL
condition that distinguishes it from the passing minimal case.

v3.13.10 audit: current SWI actor code explicitly extracts the module from the
receive clause set, evaluates guards in that module, and calls the selected
body and timeout handler as `Module:Goal`. Its control guard and distributed
goal serialization preserve the corresponding module context. The Trealla
private-source loader obtains the same observable result by qualifying the
receive DSL before assertion. Removing that bridge in isolation compares two
different application implementations rather than isolating a Trealla defect,
so this item should not be sent upstream.

### BUG-018: `format/3` segfaults on the `~p` directive

**Status:** Resolved in v3.13.2
**Priority:** High

Trealla v3.12.6 exits with signal 11 when its formatter encounters the SWI
`~p` print-term directive:

```prolog
?- format(atom(Text), '~p', [-2]).
```

The standalone process exits with status 139 and produces no Prolog
exception. On a Web Prolog node, an otherwise valid actor query can therefore
drop its WebSocket connection and restart the whole node.

Expected behavior is either support for `~p` or a catchable format error; an
unsupported directive must not crash the process.

v3.13.2 port status: the translation layer is gone and actor I/O passes `~p`
directly to native `format/3`. Regression test 111 covers the original query.

### BUG-019: Rebuilding `If -> Then ; Else` loses commitment semantics

**Status:** Resolved in v3.13.2
**Priority:** High

Trealla v3.12.6 changes the semantics of an if-then-else term after the term
has been recursively deconstructed and rebuilt. If `If` succeeds and `Then`
subsequently fails, `Else` is incorrectly executed. Calling the original term
without rebuilding it correctly fails without entering `Else`.

Standalone reproducer (`reproducers/bug-019-rebuilt-if-then-else.pl`):

```prolog
reproducer :-
    rebuild_control((true -> fail ; writeln(unexpected_else)), Goal),
    ( call(Goal) ->
        writeln(unexpected_success)
    ; writeln(expected_failure)
    ).

rebuild_control((Left0 ; Right0), (Left ; Right)) :- !,
    rebuild_control(Left0, Left),
    rebuild_control(Right0, Right).
rebuild_control((If0 -> Then0), (If -> Then)) :- !,
    rebuild_control(If0, If),
    rebuild_control(Then0, Then).
rebuild_control(Goal, Goal).
```

Run:

```text
tpl -f reproducers/bug-019-rebuilt-if-then-else.pl -g "reproducer,halt"
```

Expected output:

```text
expected_failure
```

Observed output:

```text
unexpected_else
unexpected_success
```

The reproducer was confirmed on macOS 26.5.1 arm64, built with Apple Clang
21.0.0 and `NOSSL=1`, against both the v3.12.6 release and upstream `HEAD`
commit `8fa6f4e986016fdfe0ad7c29a8560fba22868194` (the two refs currently resolve
to the same commit). It does not depend on Web Prolog, modules, threads,
sockets, or dynamically asserted clauses.

No duplicate was found in the upstream tracker on 2026-10-02. Closed issues
[#130](https://github.com/trealla-prolog/trealla-prolog/issues/130) and
[#651](https://github.com/trealla-prolog/trealla-prolog/issues/651) concern
other if-then-else discrepancies, but neither involves rebuilding a control
term before `call/1`.

Impact: compatibility layers commonly walk control terms to qualify or rewrite
their leaves before execution. The Web Prolog actor isolation layer does this
for private source modules; the defect caused a failed timeout branch to enter
the terminating `Else` branch, so repeated promise polling returned its first
timeout instead of waiting for the remote answer.

v3.13.2 port status: the promise-polling special case is gone. Regression test
121 and the SWI-to-Trealla promise/yield interoperability test now exercise the
ordinary reconstructed control term.

### BUG-020: Mutable per-thread list state can perturb or corrupt live terms

**Status:** Not reproduced on clean v3.13.2 retest
**Priority:** High

While replacing the actor runtime's old blackboard state on Trealla v3.13.2,
the deferred mailbox was represented as a `thread_local/1` predicate whose
single clause was repeatedly retracted and asserted. In the selective-receive
suite, a ground value such as `[4-low2]` was later read as
`[4-dummy|dummy]`, and subsequently as a variable. The receive loop then
failed to make progress and hung.

A small single-threaded retract/assert experiment did not reproduce the
failure, so the interaction still needs reducing from the private-module,
recursive selective-receive case before it is ready to file.

A second application-level symptom appeared while porting SWI's pre-guard
message deferral. Calling `nb_setval/2` with a list containing a pristine copy
of a freshly dequeued message before matching it changed the `/call` JSON
answer path: a formerly valid binding response failed in `write_term/2` with
`domain_error(write_option, variable_names(['X'=a]))`. Delaying that state
write until the message is rejected (or immediately before a reserved control
exception is rethrown) restores the correct answer.

On 2026-10-12 both suspected mechanisms were substituted independently into
the current port. Replacing the deferred state through a `thread_local/1`
clause passed every unit group. Storing the copied message with `nb_setval/2`
before guard evaluation also passed every unit group, including `/call` JSON
bindings and private recursive receive. Simple standalone experiments pass as
well. The historical observations remain recorded here, but this report must
not be sent upstream unless a fresh failure can be reproduced.

The production port conservatively retains the established per-thread
`nb_setval/2`/`nb_current/2` list and commits new deferred copies only on
rejection or exceptional propagation.

### BUG-021: Concurrent `sleep/1` calls lengthen one another

**Status:** Resolved in v3.13.10
**Priority:** High

Independent threads sleeping for one, three, and two seconds should all have
finished after approximately three seconds. On Trealla v3.13.3 and v3.13.4
they regularly take about 4.1–4.5 seconds in total. Instrumenting each thread
shows that all three enter `sleep/1` promptly, but their actual waits are
lengthened when the other process-wide alarms fire.

Standalone reproducer (`reproducers/bug-021-concurrent-sleep.pl`):

```prolog
reproducer :-
    get_time(Start),
    thread_create(sleep(1), One, []),
    thread_create(sleep(3), Three, []),
    thread_create(sleep(2), Two, []),
    thread_join(One, _),
    thread_join(Three, _),
    thread_join(Two, _),
    get_time(Finish),
    Elapsed is Finish-Start,
    format('elapsed(~3f).~n', [Elapsed]).
```

Run:

```text
tpl -f reproducers/bug-021-concurrent-sleep.pl
```

Expected output is close to `elapsed(3.000).`; observed output on macOS arm64
is typically close to `elapsed(4.200).`. The same defect occurs with
`thread_sleep/1`.

Impact: actor programs use sleeps concurrently for timeouts, races, and
teaching examples. The three-way parallel example that should take as long as
its slowest three-second branch instead takes roughly 4.2 seconds.

v3.13.10 result: five `sleep/1` runs completed in 3.001–3.004 seconds, and the
equivalent `thread_sleep/1` probe completed in 3.002 seconds. Sandboxed code
now uses native `sleep/1`; regression tests 147 and 148 continue to cover both
the primitive and tutorial-level behavior.

### BUG-022: A list-valued `:` meta-argument is not caller-qualified

**Status:** Ready to file
**Priority:** High

Trealla v3.13.10 qualifies a callable argument passed to an imported predicate
whose argument is declared `:`, but does not qualify a list passed through the
same argument position. The library-side `strip_module/3` call consequently
returns the caller for the callable and leaves the module unbound for the
list. SWI-Prolog returns the importing caller module in both cases.

Standalone reproducer:

- `reproducers/bug-022-list-meta-library.pl`
- `reproducers/bug-022-list-meta-caller.pl`

Run:

```sh
cd reproducers
tpl -q -f bug-022-list-meta-caller.pl \
    -g "bug_022_list_meta_caller:reproducer,halt"
```

Observed on Trealla v3.13.10:

```text
contexts(bug_022_list_meta_caller,_1)
```

Expected, and observed with SWI-Prolog:

```text
contexts(bug_022_list_meta_caller,bug_022_list_meta_caller)
```

The `:` specifier denotes an arbitrary module-sensitive argument; it is also
used for structured data containing callbacks, not only for a directly
callable term. This affected supervisor child specifications: a nested server
callback inside the child-specification list was resolved in the wrong module.
The port works around the defect by explicitly passing `Module:ChildSpecs`.

## Compatibility gaps worth tracking, but not yet bug reports

These missing facilities increase porting work but need a clearer upstream
scope or an existing-library survey before becoming individual requests:

- `library(settings)`
- a PlUnit-compatible test framework

Trealla v3.13.4 supplies both `library(debug)` and
`predicate_property(_, number_of_clauses(N))`; they are no longer gaps.

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
