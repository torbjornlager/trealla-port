# Trealla HTTP timeout verification — 22 October 2026

**The upstream timeout fix works in the tested plain-HTTP paths, but this build
is not yet a drop-in replacement for our installed engine.** Promise body-read
timeouts expose a stream leak in the port, and the existing private-actor callback
regression hangs on the new build. No runtime repair or engine installation was
made during this assessment.

**Follow-up:** the bounded port stream repair below now fixes the leak. The
assessment evidence and failures below are retained as historical results; the
separate callback hang and installed engines are unchanged.

## Builds and scope

- Pinned: Trealla v3.13.10, executable hash unchanged from before testing.
- Separate upstream: v3.14.5, commit
  `beed430deca9fa48adf028541ea4c3e2bd8d3641`, unmodified source checkout.
- This commit contains timeout fixes `7e13de8`, `f8790c5` and `2ff66ea`.
- Built with macOS 15.4 SDK, `NOSSL=1 NOFFI=1`. TLS and other platforms were
  not tested. Live n3/n5, installed engines and runtime source code were unchanged.

[provenance.json](provenance.json) records revisions, hashes and build settings;
[build.log](build.log) retains compilation output. Each executable used its own
matching adjacent standard library.

## Engine tests

The original [standalone reproducer](../bug-024-http-read-timeout.py) was run
three times per build. Its server sends nothing for 1.2 seconds; the requested
read timeout is 0.2 seconds.

| Check | Pinned | Separate upstream |
|---|---|---|
| Original reproducer, three runs | Incorrect success after 1.204–1.207 s | Read-timeout error after 0.202–0.203 s |
| Upstream `stream_read_timeout.pl` | Not run on old engine | All 21 output lines match expected output |
| Upstream `task_read_timeout.pl` | Not run on old engine | All 9 output lines match expected output |

The upstream suites include partial input, repeated reads, recovery, zero,
negative, very large and infinite timeouts, competing alarms and task yields.
Both stdout and exit status were checked, rather than interpreting a zero exit
as timeout enforcement. [Raw engine results](engine-tests.json).

## Web Prolog client checks

The new Python fixture is a disposable loopback HTTP peer returning deterministic
Prolog answers. It delays response headers, the body, or the remainder of a
partial body line. It does not execute submitted Web Prolog goals or use an
existing node. Tests run in the trusted standalone `user` context, following the
existing lifecycle tests.

| Check on separate upstream | Result |
|---|---|
| RPC delayed headers/body/partial line, explicit `http_timeout/1` and legacy `timeout/1` | All six time out; streams reclaimed; following request succeeds |
| RPC explicit timeout overrides legacy option in either order | Both timeout checks pass |
| RPC longer explicit timeout overrides shorter legacy value; legacy `infinite` | Both successful-response checks pass |
| Promise delayed headers | Callback, error delivery, queue/thread/stream reclamation pass |
| Promise delayed body | Error delivered promptly; queue/worker/timer reclaimed; stream count rises 3 → 4: **fail** |
| Promise partial body line | Same stream leak: **fail** |
| Short local yield waits and callback followed by successful retry | Pass, including caller-variable independence and resource reclamation |

The whole enforcement group remains **failed**, not waived. Its later cases
were also run independently so that the body failure did not conceal the partial
line and successful-retry outcomes. Evidence:

- [Combined run](client-enforcement.json)
- [Promise headers](promise_headers.json), [body](promise_body.json),
  [partial line](promise_partial.json), [successful retry](retry_success.json)

Reproduce against an explicitly selected engine:

```sh
python3 tools/test-http-timeout-enforcement.py --tpl /path/to/trealla/tpl \
  --output /tmp/http-timeout-results.json
```

Use `--case promise_body`, `promise_partial`, `promise_headers` or `retry_success`
to run a remaining case independently. The enforcement group is deliberately not
added to the default pinned-engine unit suite: v3.13.10 does not enforce the
underlying read timeout.

## Cause and smallest prospective stream repair

`rpc_fetch_answer/9` in `rpc.pl` opens the stream inside the protected goal of
`call_cleanup/2`. Its cleanup closes the stream only if the stream variable is
bound. A read exception unwinds that binding before cleanup; the variable is
then unbound and the guard skips `close/1`. Header-read exceptions are different:
the HTTP library itself closes a failed connection before returning a stream.

A plain `library(http)` probe, without Web Prolog imports, confirms the body-read
case on the new engine: the guarded `call_cleanup/2` sees an unbound stream and
leaves four streams instead of three. Acquiring the stream in the setup of
`setup_call_cleanup/3` returns to three streams after the same timeout. The old
engine returns its delayed body successfully and reclaims the stream on that
success path. [Raw cleanup probes](cleanup-and-module-probes.json).

The smallest prospective port repair is therefore to acquire the stream in
`setup_call_cleanup/3` and close it unconditionally in cleanup. This is a proposed
next batch, not a runtime change made by this investigation.

## Existing regression comparison and separate diagnostics

[Existing regression results](existing-regressions.json):

- HTTP option mapping/validation, promise lifecycle and RPC option validation
  pass on both engines.
- The complete promise correctness group passes on the pinned engine but hits
  the 35-second watchdog on upstream. This is incomplete evidence, not a pass.
- [Fresh-process stage diagnostics](promise-stage-diagnostics.json) isolate the
  hang to `promise_actor_callback_test`; the other five stages pass separately.
  The isolated callback stage also hits its eight-second watchdog. Its cause is
  not established here and is not attributed to the stream-timeout commits.

The initial resource-counting helper also exposed a public `stream_property/2`
module-context failure involving private `$stream_property/2`. A standalone
[module probe](module_stream_probe.pl) reproduces it on **both** old and new
engines; it is not evidence of a new upstream regression. Using the trusted
standalone context for resource inspection changes no timeout or cleanup
assertion. These observations remain in
[cleanup-and-module-probes.json](cleanup-and-module-probes.json).

## Recommendation

Keep the installed engine unchanged. First make the small promise stream-scope
repair with these failing body/partial-line tests. Investigate the private actor
callback hang separately before treating upstream v3.14.5 as an upgrade candidate.
Then rerun the focused client tests and native interoperability checks. The
destination-execution timeout API, TLS, general connection deadlines and remote
cancellation remain outside this batch. No upstream comment or issue was posted
as part of this local verification.

## Bounded stream repair and verification

`rpc_fetch_answer/9` now acquires its HTTP stream in the setup argument of
`setup_call_cleanup/3` and closes it in cleanup. Acquisition failure remains the
HTTP library's responsibility. Read and parse exceptions retain the acquired
handle for cleanup and continue through existing promise error delivery.
The local collector, timeout callbacks and retry semantics are unchanged.

A new malformed-reply case reproduces the same leak on the installed/pinned
engine without needing read-timeout enforcement: before the repair it delivers
the syntax error but leaves stream count 3 → 4. After the repair it returns to
three streams, reclaims the promise record/queue/worker/timer and successfully
issues another request. This case is included in `tools/test.sh unit`.

- [Malformed reply before repair, pinned](parse-error-before-repair.json): fails
  the stream-count assertion.
- [Malformed reply after repair, pinned](parse-error-after-repair-pinned.json):
  passes all assertions.
- [Full focused fixture after repair, separate upstream](client-enforcement-after-repair.json):
  all RPC timeout/precedence checks, promise header/body/partial-line timeouts,
  short local waits/callbacks/retry, malformed replies and resource checks pass.
- [Existing regressions after repair](regressions-after-repair.json): lifecycle,
  option validation and HTTP timeout mapping pass on both builds; the complete
  promise correctness group passes on pinned. The known upstream private actor
  callback hang was deliberately not rerun or changed in this repair.

No installed executable, live node, destination timeout semantics or remote
cancellation behavior was changed. This is a port stream-ownership repair,
not an engine timeout-enforcement workaround. The shared language manual states
the observable cleanup behavior; the runtime README records the implementation.
