# Outstanding Trealla reports from the Web Prolog port

Prepared 2026-10-13 from the `trealla-port` work, using Trealla v3.13.4 on
macOS arm64.  Thank you for the substantial set of fixes and additions already
made for this port.  After retesting, only the following two items are ready to
send upstream.

## Ready reports

### 1. Feature request: absolute message-queue deadlines

`thread_get_message/3` accepts `timeout(Seconds)`, but rejects the
SWI-compatible `deadline(AbsoluteTime)` option with
`domain_error(read_option, deadline(...))`.

Absolute deadlines are useful in selective-receive loops: unrelated messages
can be skipped without repeatedly converting the original deadline into a
shrinking relative timeout.  The requested time basis is the one used by
`get_time/1`.

Reproducer:

```sh
tpl -q -f reproducers/fr-010-thread-get-message-deadline.pl \
    -g "reproducer,halt"
```

Trealla v3.13.4 raises the domain error.  SWI-Prolog fails immediately and the
reproducer prints `none`, because its deadline is already expired.

### 2. Bug: concurrent `sleep/1` calls lengthen one another

Independent sleeps in separate threads interfere.  Threads sleeping for one,
three, and two seconds concurrently should finish in about three seconds, but
three clean v3.13.4 runs took 4.196, 4.167, and 4.134 seconds.  `thread_sleep/1`
has the same behavior.

Reproducer:

```sh
tpl -q -f reproducers/bug-021-concurrent-sleep.pl
```

This matters for actor timeouts, races, and concurrent teaching examples.  The
port currently works around it with a per-thread mailbox deadline, so the
one/three/two-second parallel example completes in about three seconds.

## Observations still needing a small reproducer

These should not yet be filed as Trealla bugs:

- A historical same-process WebSocket teardown crash was timing-sensitive and
  did not recur in five v3.13.3 runs of either application regression.
- The toplevel still uses defensive construction for mutable `count/1` and
  `target/1` cells because an earlier build could retain an argument belonging
  to another continuation or thread.  No standalone current-version
  reproducer exists.
- Dynamically loaded actor source still explicitly qualifies the imported
  `receive/1,2` closures and their bodies.  The original failure remains
  covered, but an ordinary dynamically asserted imported meta-call now passes;
  the narrower trigger has not been isolated.
- A list passed to an imported predicate argument declared with `:` is not
  consistently qualified with the caller module. The supervisor port
  currently supplies `Module:ChildSpecs` explicitly; this needs a small
  standalone reproducer before filing.
- Old 10,000-iteration actor benchmarks crashed intermittently on pre-3.0
  versions. On v3.13.4, ten 10,000-message ping-pong runs passed; the spawning
  benchmark passed at 1,000 and 2,000 generations but did not finish its
  5,000-generation run within a 20-second probe. This is not currently a crash
  report, but a bounded performance/stability test is still needed.

## Lower-priority portability requests

Two larger SWI-porting conveniences remain absent and may be worth discussing,
rather than filing as narrowly specified requests yet:

- `library(settings)` or a comparable typed application-settings facility;
- a PlUnit-compatible test framework.

The earlier candidates `library(debug)` and
`predicate_property(_, number_of_clauses(N))` are present in v3.13.4 and are no
longer requests.

## Items removed by this audit

- `call_with_time_limit/2` returning only the first solution is not a Trealla
  compatibility bug: SWI-Prolog 10.1.3 behaves the same way.
- Self-detach during an `at_exit` hook is now refused cleanly, the final thread
  status is visible inside the hook, and closing a listener from another thread
  wakes `socket_server_accept/4`.  The former BUG-002, BUG-003, and BUG-014 are
  therefore resolved.

Full historical details and resolved reports remain in `UPSTREAM_REPORTS.md`.
