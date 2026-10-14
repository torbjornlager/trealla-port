# Outstanding Trealla reports from the Web Prolog port

Updated 2026-10-14 from the `trealla-port` work, using Trealla v3.13.10 on
macOS arm64.  Thank you for the substantial set of fixes and additions already
made for this port.  No minimized bug report or feature request is currently
ready to send upstream.

## Resolved in v3.13.10

### Absolute message-queue deadlines

`thread_get_message/3` now accepts the SWI-compatible
`deadline(AbsoluteTime)` option.  The standalone reproducer's already-expired
deadline fails immediately and prints `none`, matching SWI-Prolog.  The actor
receive loop now passes its absolute deadline directly to Trealla.

Regression command:

```sh
tpl -q -f reproducers/fr-010-thread-get-message-deadline.pl \
    -g "reproducer,halt"
```

### Independent concurrent sleeps

Independent one-, three-, and two-second sleeps now finish in approximately
three seconds.  Five clean `sleep/1` runs took 3.001, 3.001, 3.004, 3.003, and
3.004 seconds; a `thread_sleep/1` run took 3.002 seconds.  The port now uses
native `sleep/1` for sandboxed actor code instead of its mailbox workaround.

Regression command:

```sh
tpl -q -f reproducers/bug-021-concurrent-sleep.pl
```

## Observations still needing a small reproducer

These should not yet be filed as Trealla bugs:

- A historical same-process WebSocket teardown crash was timing-sensitive and
  did not recur in five v3.13.3 runs of either application regression.
- The toplevel still uses defensive construction for mutable `count/1` and
  `target/1` cells. On v3.13.10, replacing it with ordinary compound literals
  reproducibly stalls the paging suite when `toplevel_next/1` resumes test
  t14. A standalone runtime-only reproducer is still needed.
- Dynamically loaded actor source still explicitly qualifies the imported
  `receive/1,2` closures and their bodies. On v3.13.10, removing the bridge
  makes test t102 fail again with `existence_error(procedure,wait_goodbye/0)`;
  an ordinary dynamically asserted imported meta-call still passes, so the
  narrower trigger has not been isolated.
- A list passed to an imported predicate argument declared with `:` is not
  consistently qualified with the caller module. Simple supervisor workers
  pass unqualified on v3.13.10, but a nested server callback then fails with
  `supervisor_down(init_failed)`. The port must continue supplying
  `Module:ChildSpecs`; this needs a small standalone reproducer before filing.
- Closing the node listener from a control thread still leaves the real
  application accept loop blocked on v3.13.10, even though the smaller
  upstream regression passes. Test t95 hangs without the existing local wake
  connection, so that shutdown mechanism remains.
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
- Self-detach during an `at_exit` hook is now refused cleanly and final thread
  status is visible inside the hook. The port now uses native status for
  ordinary actor termination and retains explicit state only for actor-level
  `exit/1` reasons. BUG-002 and BUG-003 are resolved; BUG-014's minimal
  reproducer is resolved, but the node's application-level accept loop still
  requires its wake connection as noted above.

Full historical details and resolved reports remain in `UPSTREAM_REPORTS.md`.
