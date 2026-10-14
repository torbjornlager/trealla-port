# Outstanding Trealla reports from the Web Prolog port

Updated 2026-10-14 from the `trealla-port` work, using Trealla v3.13.10 on
macOS arm64.  Thank you for the substantial set of fixes and additions already
made for this port. One minimized module-context bug is ready to send
upstream.

## Ready to send

### A list-valued `:` meta-argument is not caller-qualified

An imported predicate declares its first argument using the standard `:`
meta-argument specifier and uses `strip_module/3` to recover the caller. On
Trealla v3.13.10 a callable argument is correctly qualified, but a list passed
in the same position has no module qualification at all:

```text
contexts(bug_022_list_meta_caller,_1)
```

SWI-Prolog qualifies both values with the importing caller module:

```text
contexts(bug_022_list_meta_caller,bug_022_list_meta_caller)
```

The two-file reproducer deliberately tests both shapes through the same
predicate declaration:

```sh
cd reproducers
tpl -q -f bug-022-list-meta-caller.pl \
    -g "bug_022_list_meta_caller:reproducer,halt"
```

Files:

- `reproducers/bug-022-list-meta-library.pl`
- `reproducers/bug-022-list-meta-caller.pl`

Expected behavior: `:` qualifies an arbitrary module-sensitive argument, not
only callable terms. Structured callback specifications commonly place goals
inside lists or other containers. The missing qualification caused nested
server callbacks in the port's supervisor child-specification list to be
looked up in the wrong module. The port currently works around this by passing
`Module:ChildSpecs` explicitly.

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
- The former receive-specific module-context candidate was a port difference,
  not an independently demonstrated Trealla bug. Current SWI explicitly
  carries the clause module into receive guards, bodies, and timeout handlers;
  the Trealla private-source loader obtains the same result through its
  qualification bridge. Removing only that bridge, without porting SWI's
  associated control-guard and distributed-goal rewriting, is not a valid
  runtime comparison.

Full historical details and resolved reports remain in `UPSTREAM_REPORTS.md`.
