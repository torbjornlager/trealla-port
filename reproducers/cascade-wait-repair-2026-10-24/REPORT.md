# Cascade fixture wait-strategy repair — 24 October 2026

## Change

Only tests.pl changes. t145 still asserts four initial actors and the exact
final `success(Session, [[Session]], false)` reply. It now identifies the root's
single child and that child's single grandchild under the existing registry
mutex, installs a private monitor for each fixture actor, and requests root exit.

All three exact pid/reference/reason notifications are required:

- root: die;
- child: kill;
- grandchild: kill.

Their receives share one absolute deadline, two seconds from immediately before
the exit request. They do not each obtain a fresh timeout. Selective receive
allows notifications to arrive out of order. Only after all three have been
observed does the test request a fresh actor snapshot and apply its original
exact singleton assertion with the original two-second response bound.

Both original sleep(0.1) calls, initial count assertion, source text, spawn checks,
initial-response bounds and final-snapshot assertion are preserved. No sleep is
lengthened. The new readiness observation replaces reliance on the second sleep;
it is not a larger snapshot retry window. Exact notification checks strengthen
the fixture without relaxing the final actor-state requirement.

`t145_with_monitors/2` uses nested setup_call_cleanup scopes so earlier refs are
retired even if a later monitor setup or the body fails. It withdraws/flushes
only the three fixture refs. It does not flush the mailbox or withdraw unrelated
monitors. The rest of tests.pl and all runtime modules remain unchanged.

## Fixed verification

The runner exports runtime Prolog sources from two explicit commits into fresh
disposable directories, then overlays only the identical repaired tests.pl and
its cleanup-control fixture:

- original runtime: c472ecb9f1a30d80558d105a980be34c73014fe4;
- callback-repaired runtime: bf47aac87d899b80da05c320f43dbe8aa438e068.

Both use the separate unmodified Trealla v3.14.10 engine and matching library.
Every runtime source file is checked against its selected commit. Each process
has a 30-second outer watchdog, and source sets alternate within each trial.
The fixed plan completes without retries or failures:

| Selection | Original runtime | Callback-repaired runtime |
| --- | ---: | ---: |
| Isolated repaired t145 | 20/20 pass | 20/20 pass |
| Complete sandbox group | 3/3 pass | 3/3 pass |
| Monitor-scope cleanup controls | 1/1 pass | 1/1 pass |

All **48/48 processes pass**, with no process watchdog timeouts. The complete
sandbox group retains every assertion, including the tests following t145.
Cleanup controls check success, logical failure, body exception and partial
setup failure, compare monitor registrations before/after and recover an
unrelated pending notification unchanged. Its original monitor remains active
until that control's own cleanup.

A successful pilot precedes the fixed batch. The first development pilot used
monitoring an unknown name to induce setup failure, but that API reports a
notification rather than failing setup. That control did not reach t145 and
its process later reported exit 137, with no useful log. It is not counted as a
runtime regression, a successful t145 run, or part of the bounded fixed batch.
The corrected control uses a pre-bound invalid reference to exercise partial
setup failure; the successful pilot and fixed control runs are preserved. This
changes only the new cleanup-control fixture, not any existing assertion.

## Preservation and evidence

- fixed/results.json and per-process logs: all 48 outcomes and exact commands.
- fixed/provenance.json: exact commits, engine revision, runtime/test hashes.
- assertion-preservation.json: unchanged original assertions/sleeps, exact new
  notification patterns and one shared deadline.
- fixed/preservation.json and before-edit.json: every pre-edit root Prolog source
  except tests.pl is byte-identical; installed executable targets/hashes,
  separate engine/library and live n3/n5 process identities are unchanged.
- monitor_scope_tests.pl and pilot-final.log: cleanup controls and pilot.
- run_batch.py: reproducible fixed verification. Its initial pre-edit metadata
  was captured in /tmp and is now stored byte-identically as before-edit.json;
  the runner reads that retained file for future reproduction.

No runtime code, installed engine, live launcher, language manual or book example
was changed. No deployment, GUI or full unit-suite certification is claimed.
The bounded batch demonstrates the repaired observation strategy on these
fixtures; it does not prove arbitrary lifecycle race freedom.

See the preceding
[stage investigation](../cascade-stage-investigation-2026-10-24/REPORT.md) for
unchanged-test failures, early snapshots and later termination observations.
Historical failures are retained rather than rewritten as passes.
