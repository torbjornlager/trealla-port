# Separate sandbox cascade-timeout investigation — 24 October 2026

This investigation is separate from the promise callback-context repair. No
cascade/lifecycle runtime change, fixture assertion change or timeout extension
was made. The callback repair's public conformance passes 24/24 PY and 8/8 HC;
this finding must not be counted as a failure of those selections or as resolved
by their success.

The broader sandbox group intermittently fails at t145_cascade_timeout. The
fixture checks nested linked-actor cleanup after its existing sleeps and contains
no promise callback. A full-group original-source control passed, while the
repaired-source control failed; see sandbox-controls.json and the two logs.

A fixed isolated comparison then ran the original unchanged t145 assertion five
times per source set on the same separate v3.14.10 engine, with unchanged receive
timeouts and a 30-second process watchdog:

| Production source | Pass | Fail |
| --- | ---: | ---: |
| Original HEAD files | 2 | 3 |
| Callback-repaired files | 4 | 1 |

The original-source reproduction shows that the failure predates this repair.
These small samples do not establish its cause, resolve it, or measure a reliable
failure rate. The snapshot/sleep assumptions are relevant to a future bounded
investigation, not a reason to relax the assertion. Every result is retained in
cascade-batch.json and its individual logs.

sandbox_controls.py and cascade_batch.py create disposable source copies and
restore original rpc.pl, sandbox_policy.pl and isolation.pl from HEAD for the
original control. HEAD meant the pre-repair Trealla commit at execution; commands
and tested repaired-file hashes are also identified by the sibling
[promise callback repair record](../promise-callback-context-2026-10-24/REPORT.md)
and its preservation.json. For future reproduction, use that recorded pre-repair
commit explicitly rather than assuming the current HEAD remains original.

Installed runtimes and n3/n5 were unchanged. No engine rebuild or deployment was
performed. The repair's broader-group raw failures remain in its own results
and logs as well; this separate record does not replace them with passing controls.

## Test-only repair follow-up

The [bounded wait-strategy repair](../cascade-wait-repair-2026-10-24/REPORT.md)
waits for all three exact termination notifications under one deadline before
requesting a fresh snapshot. Its fixed verification passes 48/48 processes
across the two explicit runtime revisions. Original findings above remain
historical evidence; runtime code and installed/live nodes were unchanged.
