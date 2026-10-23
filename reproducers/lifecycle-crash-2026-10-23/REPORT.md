# Exceptional thread retirement: investigation and separate candidate

23 October 2026. Report and candidate patch submitted as [Trealla #1178](https://github.com/trealla-prolog/trealla-prolog/issues/1178).
The published diff matches the tested patch byte-for-byte.

The standalone crash is reproducible without Web Prolog and is fixed in the
focused candidate checks. The expiry wait failure and other lifecycle outcomes
remain separate. The installed engine and production runtime code are unchanged.

- [Upstream draft and diagnosis](../bug-030-thread-status-retirement.md).
- [Candidate C repair and engine regression](../bug-030-thread-status-retirement.patch).
- [Executable, source and patch hashes](provenance.json).
- [Sanitized native crash stacks](crash-diagnosis.json).

## Fixed batches

| Artifact | Scope and result |
|---|---|
| [Initial lifecycle batches](lifecycle-batches.json) | 30 processes per engine; pinned 27 pass, 1 SIGSEGV, 2 incomplete; upstream 27 pass, 2 SIGSEGV, 1 expiry wait failure |
| [Normal retirement control](property-tight.json) | 20 processes per engine, 1,000 iterations each: all complete |
| [Exceptional retirement](property-exception.json) | 20 processes per engine: all SIGSEGV |
| [Final candidate standalone](final-candidate-standalone.json) | 20 processes × 1,000 iterations: all complete |
| [Final candidate lifecycle](final-candidate-lifecycle.json) | 30/30 complete; no crash or timeout |
| [Final engine regressions](final-engine-tests.json) | Expanded new regression 5/5; eight existing groups all exact passes |
| [Initial engine comparison](engine-regression.json) | Initial new regression: upstream crashes 5/5, candidate passes 5/5 |

The initial candidate results remain in `candidate-property-exception.json`,
`candidate-lifecycle.json` and `existing-engine-tests.json`. They precede the
allocation-error refinement and expanded direct-status assertions. In particular,
`candidate-lifecycle.json` records the expiry failure; it is not counted as a pass.

`initial-narrow-catch-diagnostic.json` records exploratory runs that stopped on
Trealla's retired-handle `uninstantiation_error`; this prompted the standalone
poll to record retirement errors, as the existing fixture already catches them.
It is not counted as a crash reproduction or successful batch.

Successful repetitive traces are compacted to a SHA256, line count and tail.
Failed process traces remain complete. Every pass required the completion marker,
exit 0 and empty stderr. The runner retains nonzero exits, crashes, watchdog
expiry and missing markers as failures, even if the engine exits 0.

## Reproduction

From the trealla-port checkout:

```sh
python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine pinned=/path/to/pinned/tpl \
  --engine upstream=/path/to/unmodified/tpl \
  --runs 30 --output /tmp/lifecycle.json

python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine candidate=/path/to/candidate/tpl --runs 20 --timeout 20 \
  --goal "consult('reproducers/lifecycle-crash-2026-10-23/thread_property_race.pl'),(run_property_race(exception,1000)->halt;halt(1))" \
  --output /tmp/exception-status.json
```

The default lifecycle runner uses a 15-second process watchdog; the individual
fixture polls have bounded retry counts. Its formerly unbounded ready-token
receive now has a two-second timeout. Diagnostics are opt-in; the normal group
keeps its existing success messages.

Candidate checkout:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/exception-status-repair-2026-10-23`.
Base: unmodified `beed430deca9fa48adf028541ea4c3e2bd8d3641`, v3.14.5.
Build: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4`.
`git apply --check` succeeds against the clean unmodified checkout. Candidate
source whitespace checks pass. No installation or node restart occurred.

## Unresolved diagnostics

- Expiry wait exhaustion occurred on unmodified upstream and the initial
  candidate. A later 30/30 passing batch does not establish its cause or fix it.
- One upstream lifecycle crash was in `do_signal`, unlike the two matching
  `do_thread_property_pin_both` crashes. Keep it separate.
- Two pinned lifecycle runs exited 0 after `race_cleaned` without a completion
  marker. These remain failures, not passes.
- Retired-handle dispatch can raise `uninstantiation_error`; no repair is included.
- General thread-table/alias concurrency and non-ground status payload behavior
  have not been certified by this ground-payload stress test.

## Submission

Duplicate checks covered open/closed issues and related pull requests. #1026
contains earlier threading/status reports without this exception-payload trigger.
The verified [published body](submitted-issue-body.md) and
[submission screenshot](issue-1178-submitted.png) are retained.
