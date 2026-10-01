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

### FR-006: Expose temporary-module lifecycle operations

**Status:** Needs design
**Priority:** Medium

Actor source isolation needs a fresh module for each actor and deterministic
destruction when that actor terminates. Trealla can create modules while
loading a file, but its public Prolog API has no equivalent of SWI-Prolog's
`in_temporary_module/3` or a supported module-destruction predicate.

Desired behavior: a scoped temporary-module operation, or explicit supported
create/delete operations, that remove the module's predicates, operators,
imports, and module-table entry after use.

Current workaround: the Trealla port gives every actor a unique module,
retracts all dynamically loaded user clauses on termination, and deletes its
bootstrap file. The empty bootstrap module necessarily remains in the module
table until process exit.

### FR-007: Provide an extensible goal-safety analysis library

**Status:** Needs design
**Priority:** Medium

Trealla has no equivalent of SWI-Prolog's `library(sandbox)`. A node accepting
goals and source from remote peers consequently has to maintain its own walker,
safe-primitive catalog, meta-call guards, directive policy, and source
validation rules.

Desired behavior: a module-aware safety API that can validate goals and source
before execution, recognizes the meta-arguments of standard predicates, and
allows applications to declare additional safe primitives and meta-predicates.
Runtime checking must remain possible when a callable is initially a variable.

Current workaround: `sandbox_policy.pl` implements a native blacklist and a
conservative whitelist, rewrites opaque meta-calls through runtime guards, and
validates submitted source before it reaches an actor's private module.

### FR-008: Add inference and per-thread stack ceilings

**Status:** Ready
**Priority:** High

The SWI node bounds public calls with `call_with_inference_limit/3` and actor
memory with the `stack_limit(Bytes)` thread option. Trealla v3.12.6 provides
neither facility: `call_with_inference_limit/3` is absent and
`thread_create/3` rejects `stack_limit/1` with
`domain_error(thread_option, stack_limit(_))`.

Desired behavior: a catchable inference-limit primitive and a supported
per-thread stack/heap ceiling. Together with an application-level actor cap,
these allow a public node to bound CPU work and process memory without placing
every individual query in a separate OS process.

Current workaround: the Trealla port enforces wall-clock, live-actor, result
page, and textual-input limits. Hard process memory and CPU ceilings must be
provided by the container or service manager.

### FR-009: Separate a socket's connection address from its TLS server name

**Status:** Needs design
**Priority:** Medium

A DNS-rebinding-resistant HTTPS client needs to resolve and authorize a
numeric destination, connect to that exact address, and still send the
original host name as TLS SNI (and eventually verify it as the certificate
identity). Trealla's `socket_client_open/3` currently derives both the TCP
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

Current workaround: `source_policy.pl` resolves once and connects to the
authorized numeric address. HTTP is unaffected; HTTPS sites that require
name-based SNI may need a trusted fetch proxy until the two values can be
supplied separately.

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

**Status:** Needs minimization
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

**Status:** Needs minimization
**Priority:** Medium

On Trealla v3.12.6, a conjunction read from a WebSocket command and passed
through the actor module's meta-predicate trampoline executes its first arm,
then can raise `existence_error(procedure, (',')/2)`.  This affected native
Web Prolog `spawn` commands such as a remote spawn followed by a monitored
receive.  Direct `call(user:(write(a),write(b)))` succeeds, so the trigger
appears to involve the combination of a goal read as data, module
qualification, a meta-predicate, and execution in a new thread.

Current workaround: `web_prolog:run_spawn_goal/1` walks conjunctions
structurally and calls their leaves.  The browser-to-remote-node terminal
interoperability test exercises this path.  Reduce that path to a standalone
module/thread reproducer before filing upstream.

### BUG-010: `listing(Module:PI)` lists the calling module instead

**Status:** Needs minimization
**Priority:** Medium

Trealla v3.12.6 accepts a module-qualified predicate indicator in
`listing/1`, but appears to discard the resolved module and enumerate the
calling module's predicate database. This prevents `src_predicates/1` from
serializing a private static predicate in another source module. Direct
`clause/2` access is not a substitute because Trealla rejects access to such
static private predicates.

Current workaround: the isolation layer temporarily installs a uniquely
named helper in the source module, invokes unqualified `listing/1` from that
helper with output redirected to a temporary file, reads the terms back, and
removes the helper. Access is serialized because `listing/1` has no explicit
stream argument.

### BUG-011: `call_with_time_limit/2` discards goal choicepoints

**Status:** Ready
**Priority:** Medium

Trealla v3.12.6 implements `call_with_time_limit/2` by applying `once/1` to
its goal. A nondeterministic goal consequently exposes only its first answer:

```prolog
?- findall(X, call_with_time_limit(1, member(X, [a,b])), Xs).
Xs = [a].
```

Expected for compatibility with the SWI interface is `Xs = [a,b]`, with the
timer applying while each resumed branch executes.

Current workaround: the PTCP and HTTP producer paths use Trealla's internal
reusable `$alarm` primitive. The PTCP cancels its alarm while a result page is
suspended awaiting the client, as does the HTTP producer while it waits for a
continuation request. Each creates a fresh alarm immediately before resuming
its choicepoint. This preserves choicepoints without charging client think-time
to the execution limit.

### BUG-012: `crypto_n_random_bytes/2` repeats predictable output across processes

**Status:** Ready
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

Current workaround: `crypto_portable.pl` reads `/dev/urandom` directly for
bearer-token ids and secrets. Token issuance fails rather than falling back to
`crypto_n_random_bytes/2` when the OS source is unavailable.

### BUG-013: An IPv6 wildcard listener reports IPv4 peers as `0.0.0.0`

**Status:** Ready
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

Current workaround: the Trealla node binds explicitly to the IPv4 wildcard
`0.0.0.0` by default. This makes the reported IPv4 peer reliable, at the cost
of not accepting IPv6 connections on that listener.

### BUG-014: Cross-thread server close does not wake a blocked accept

**Status:** Ready
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

### BUG-015: A TLS-disabled build reports `resource_error(memory)` for SSL

**Status:** Ready
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

Current workaround: build Trealla with OpenSSL when TLS is required, or
terminate TLS in a reverse proxy. Hostname verification in SSL-enabled builds
remains a separate requirement tracked in BUG-005.

### BUG-016: Blocking inside a receive body can lose its deferred tail

**Status:** Needs minimization
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

Current workaround: `actors:flush/0` first drains every pending message into a
plain list without blocking for terminal acknowledgements, then emits the
collected messages in a second pass. The SWI-to-Trealla browser interoperability
test verifies two acknowledged outputs in order.

### BUG-017: Dynamically asserted calls to an imported meta-predicate lose the caller module

**Status:** Needs minimization
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
