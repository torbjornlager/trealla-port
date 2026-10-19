# Outstanding Trealla reports from the Web Prolog port

Updated 2026-10-18 from the `trealla-port` work, using Trealla v3.13.10 on
macOS arm64.  Thank you for the substantial set of fixes and additions already
made for this port. One minimized module-context bug is ready to send
upstream, and a newly isolated term-construction bug needs a current-build
retest before filing.

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

## New report needing a current-build retest

### BUG-023: `functor/3`-constructed terms fail callable/arithmetic lookup

On v3.13.10, constructing `X=ok` with `functor/3` and `arg/3`, then calling it,
raises a missing `(=)/2` error. Constructing `2+3` the same way and evaluating
it raises `type_error(evaluable,(+)/2)`. The equivalent `=../2` constructions
succeed. This reproduces without the port, threads, modules, or sockets:

```sh
tpl -f reproducers/bug-023-functor-callable-lookup.pl -g "reproducer,halt"
```

SWI-Prolog succeeds in all four cases. The port's browser-pid conversion
rebuilds every compound using the affected construction, causing failures in
basic remote queries. The port now uses a bounded `=../2` workaround, covered
by conversion vectors and live asynchronous query regressions. See
`UPSTREAM_REPORTS.md` for details. Retest current upstream
and search for duplicates before sending; this is not yet filed.

### Cancellation of a blocked queue reader and Prolog cleanup

The runtime-only `reproducers/port-promise-thread-cancel.pl` observation on
v3.13.10 prints:

```text
cancelled_queue_reader_still_running
prolog_cleanup_missing
```

After `thread_cancel/1`, a thread blocked in `thread_get_message/2` remains
running until a message wakes it. It then retires without running the
`setup_call_cleanup/3` cleanup goal. The port's promise lifecycle uses private
exception signals for its own workers, short queue waits against an overall
deadline, and stale-collector recovery after thread retirement. Retest current
upstream and clarify the intended cancellation/cleanup contract before filing;
this observation has not been sent upstream.

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

## Resolved port issue: remote supervisor entry qualification

A sender-only qualification wrapper was insufficient: the sandbox correctly
rejected `call(supervisor_actor:sup_init(...))` as a private module call.
The receiver now recognizes the existing unqualified supervisor startup shape,
validates fresh state/specifications, checks and rewrites child goals and
sources, and executes precompiled framework code with peer-local child source
contexts. Dynamic additions cross the same checks. No protocol extension or
general private-module allowance was introduced. This was a port adapter issue,
not an independently demonstrated Trealla engine bug.

The former observation in `reproducers/port-remote-supervisor-entry.pl` is now a
startup/control smoke check for updated peers. Detailed sandbox and live
regressions are in `remote_supervisor_tests.pl`; native SWI interoperability is
covered by `swi_supervisor_compat.pl`. Current n5 was not changed.

## Resolved port gaps: native SWI supervisor transport compatibility

The receiver-entry adapter accepts native SWI named and unnamed supervisor
startup, including explicitly supplied `src_text/1` child source. The former
`remote_spawn_failed(uncorrelated_spawn_reply)` port gap is repaired: optional
spawn request IDs are echoed on success and admission/startup errors, while
legacy replies and monitor events remain unchanged. Native compatibility tests
cover duplicate names and reuse after failed startup.

Native SWI's halt wait may observe normal `down` before its acknowledgement,
which travels over a separate connection. Native SWI and Trealla now tolerate
that ordering within the original halt deadline, requiring the matching reply
for success; missing acknowledgements and abnormal termination remain errors.
The compatibility smoke test no longer suppresses `supervisor_down(true)` and
includes repeated acknowledged halt cycles. Transport ordering itself is
unchanged; this was a caller-wait compatibility gap, not a Trealla engine bug.
Current n5 and shutdown policies are unchanged.

## Observations still needing a small reproducer

These should not yet be filed as Trealla bugs:

- On 2026-10-18, a Trealla v3.13.10 outbound synchronous-wait stress check
  exited with status 139 while another actor called `remote_node_close/1`.
  The macOS report (`tpl-2026-10-18-191542.ips`) faults in `flockfile`, called
  by `clearerr` from `bif_iso_get_byte_2`. The port allowed writer-side stream
  close before confirming reader cancellation, consistent with this race.
  Sixteen fresh pre-repair runs against SWI and Trealla passed, so the native
  failure remains intermittent. The port now confirms reader termination
  before writer close and includes concurrent-close regression coverage.
  `reproducers/port-shared-connection-close.pl` retains the application
  pattern. A standalone runtime reproducer and precise stream-safety diagnosis
  are still needed before filing upstream.

- On 2026-10-18, the standalone generic-server (31 cases) and supervisor
  (20 cases) suites passed and exited with status 0, but some runs printed
  temporary-module syntax diagnostics during shutdown, such as
  `syntax error, missing arg '', $trealla_actor_...:1`. The same diagnostics
  reproduced in a copy with the new wrapper-validation calls removed.
  This is not established as a wrapper-validation regression or an upstream
  runtime defect. A minimized source/module-teardown reproducer is needed
  before filing; lifecycle behavior was left unchanged in this batch.

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

## Portability feature requests

### SWI-compatible XML parser

The statechart layer needs an XML reader compatible with the useful core of
SWI-Prolog's `library(sgml)`, especially `load_structure/3` with
`dialect(xml)`, `space(remove)`, and the conventional
`element(Name, Attributes, Children)` result representation. DTD loading and
validation (`new_dtd/2`, `open_dtd/3`, and `free_dtd/1`) would let Trealla run
the same SXML validation path as SWI rather than maintaining a profile-specific
pure-Prolog parser.

The immediate use case is SXML 0.2 statechart documents, including comments,
CDATA, entity decoding, nested elements, and validation diagnostics. A smaller
XML-only library that preserves the SWI result representation would already
remove most of the porting layer; full SGML support is not required.

### Other lower-priority requests

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
- The old high-volume actor crash did not reproduce on v3.13.10. Ten fresh
  10,000-message ping-pong runs and five fresh 10,000-generation recursive
  spawning runs all completed. The earlier 5,000-generation 20-second probe
  was simply too short; that workload completes in about 41 seconds.

Full historical details and resolved reports remain in `UPSTREAM_REPORTS.md`.

## Resolved port issue: history default transition ownership

Execution tests exposed an existing pure-model compiler error: a `<history>`
node's default `<go>` was compiled as a transition on the parent state. This
created an unintended eventless loop in pause-and-resume. The child compiler
context now uses the history node ID, matching SWI. Parser/model and live
execution regressions cover the correction. This was a port bug, not evidence
of a Trealla engine defect.
