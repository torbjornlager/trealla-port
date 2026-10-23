# Supervisor-intensity notification wait repair — 23 October 2026

The test-only repair passes the fixed supervisor-intensity batches on both
engines. The second supervisor-monitor wait now uses `timeout(1)` instead of
`timeout(0)`. Its exact `down(Sup,ExtraSup,shutdown)` pattern and failure outcome
are unchanged, as are all child, ordering, cleanup and unrelated-monitor checks.
The first notification still has its original four-second bound. A short
comment explains that independent notifications are separate sends.

No production runtime code, installed engine or live N3/N5 process changed.
This fixes a test assumption; it does not introduce atomic notification delivery
or extend a public runtime timeout. The preceding diagnostic wrappers remain.
See [the exact incremental repair](repair.diff).

## Verification

| Check | Candidate v3.14.8 + handoff primitive | Unmodified v3.14.8 |
|---|---|---|
| Complete supervisor-intensity group, fresh processes | 100/100 pass | 100/100 pass |
| Delayed second notification, original zero-time control | 5/5 fail as expected | 5/5 fail as expected |
| Delayed second notification, repaired exact assertion | 5/5 pass | 5/5 pass |
| Diagnostic negative control: require the old failure at `extra_supervisor_down` | 5/5 confirmed | 5/5 confirmed |
| Full application unit suite | 74 groups pass | initial run fails in separate HTTP paging cleanup; repeat passes all 74 groups |

All 200 fixed group runs exit 0 without crashes or watchdog expiry. Each group
retains all strategies, positive-limit accounting, shutdown policies, cleanup
errors, child monitors and abort controls. Each process has a 30-second external
watchdog; full unit runners retain their per-group deadlines and a 900-second
outer watchdog. Successful repetition does not prove the absence of every race.

The delayed-notification control uses the existing test-process send hook. It
holds the second supervisor notification for 50 ms after the first was sent,
then allows the real runtime send to proceed. It does not manufacture the down
message. The complete original exhaustion case runs, with either its archived
zero-time assertion or the repaired one-second assertion. Both preserve the
exact pid, reference and reason checks. The original control exits 1 on ordinary
failure; the repaired control exits 0. A second control uses the archived named
diagnostics to require the specific old failure, rather than accepting any
nonzero exit as evidence of the race. Every such check succeeds.

These controlled delays expose the scheduling assumption; they are not timing
or incidence benchmarks. Candidate and unmodified engines use their matching
adjacent libraries and the same application source.

## Separate full-suite observation

The candidate's complete 74-group unit suite exits 0. The first unmodified-engine
run exits 1 in `HTTP paging request cleanup`: startup failure, skip interruption
and collect interruption checks print their success lines, then the group fails
before the lookahead-interruption success line. The failing assertion is not
identified by that output. There is no basis here to attribute it to this test
repair or to the receive-handoff gap, and no paging code or assertions were
changed. Its original failure log is retained. The separate repeat passes all 74 groups and has its own
JSON/log record; that pass does not erase the first failure.

The supervisor-intensity repair's fixed and controlled checks pass on both
engines independently of that observation. The unmodified engine's initial full
suite is not reported as an all-pass result.

## Evidence and reproduction

- [fixed-results.json](fixed-results.json), named `fixed-*.log/json` files and
  [fixed-runner.log](fixed-runner.log): all 200 natural group invocations.
- [control-results.json](control-results.json), `control-*.log/json` files:
  original/repaired delayed-notification comparison.
- [negative-control-results.json](negative-control-results.json): specific
  expected-failure checks against archived diagnostics.
- `unit-candidate.log/json`, `unit-unmodified.log/json` and
  `unit-unmodified-repeat.log/json`: complete application suite attempts.
- [provenance.json](provenance.json): test/input hashes, engine hashes and
  changed tracked files. All candidate, unmodified and installed executable
  hashes match their preceding verification records.

From trealla-port:

```sh
python3 reproducers/supervisor-intensity-repair-2026-10-23/run.py fixed
python3 reproducers/supervisor-intensity-repair-2026-10-23/run.py control
python3 reproducers/supervisor-intensity-repair-2026-10-23/negative-control.py
python3 reproducers/supervisor-intensity-repair-2026-10-23/run.py unit
```

The full-suite repeat used the same recorded unmodified engine and command,
with a separate output label. The previous investigation's exact diagnostic
source and execution launchers have been archived before this repair. Its
rerunnable controls now select that frozen diagnostic source, preserving the
historical zero-time test instead of silently loading the repaired test.
Original execution-file hashes still match the `*-at-verification` copies.

The installation remains unchanged. This batch resolves the supervisor-intensity
assertion race; it does not resolve the SWI candidate's missing PCRE, the manual
wording smoke check or the separate unmodified-engine paging diagnostic.
