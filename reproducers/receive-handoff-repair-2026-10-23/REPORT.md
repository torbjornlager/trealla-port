# Receive-handoff repair — separate candidate engines, 2026-10-23

## Outcome

The candidate engine primitive and receive-adapter integration pass both engine comparisons and worker-cleanup checks. The installed engine remains unchanged. Original engines retain the compatibility path and its known interruption gap; updating only `actors.pl` does not close that gap.

| Verification | Candidate pinned | Candidate upstream v3.14.8 |
| --- | --- | --- |
| Natural adapter probe | 1,500/1,500 | 1,500/1,500 |
| Native selective-queue control | 1,500/1,500 | 1,500/1,500 |
| Complete worker-scope groups, fresh processes | 100/100 | 100/100 |
| Direct primitive checks, including 1,000 interruption trials | pass | pass |
| Final adapter regression, including 1,000 interruption trials across four wait modes | pass | pass |
| Controlled standalone handoff, 1,000 trials | pass | pass |
| Existing engine global-variable and threaded-global-variable tests | pass | pass |
| Full port unit suite | 74 groups pass | 74 groups pass |

All 224 processes in the fixed comparison/worker runner completed successfully, without stderr, crashes, or watchdog expiry. Additional targeted and unit-suite results are stored separately. Finite batches do not prove the absence of every lifecycle failure.

The final adapter test adds body-failure and ordinary guard-error cases after the full suites had begun. Both engines passed a final explicit rerun of the expanded adapter test; the production adapter/engine code did not change during those suite runs.

## Implementation

The private engine builtin `$thread_get_message_saved/5` shares the existing queue matching/waiting code. After a native match it copies a bound template into the caller's non-backtrackable thread-local store **before** removing the queue item. These actions run within a single builtin, without a thread-signal checkpoint between them. Blocking waits still process signals. Timeouts leave the store untouched; validation precedes acquisition. Allocation-error preservation is a code-reviewed property, not an injected-failure test result.

`actors.pl` builds a deferred-list template containing the incoming variable and uses the primitive in blocking, timed, absolute-deadline and polling paths. The stored message is a pristine copy. Existing selection/guard logic either consumes it before running the selected body or retains it as a non-match. The exact `down(unrelated,probe,killed)` assertion is retained, with duplicate checks added.

Capability detection uses `predicate_property(...,built_in)`: Trealla's `current_predicate/1` does not enumerate this private builtin. Engines without it take the old native read path. README and test-runner output explicitly distinguish compatibility from the new guarantee; the runner checks ordinary receive semantics but explicitly skips interruption stress on those engines.

This is an internal candidate capability, not a public Web Prolog predicate. No shared language manual or book example needed changing: the repair makes the implementation meet existing receive semantics.

## Controls and attribution

`original-engine-controls.json` reruns the final natural regression through the fallback on both original engines. Ordinary semantics pass; the interruption regression fails with `interrupted_receive(failed(missing_unrelated))` on both.

`standalone.pl` removes all Web Prolog dependencies. It exposes the legal acquire-to-Prolog-store interruption window with a deliberate gate. Original engines fail the exact preservation check; candidate engines pass all 1,000 trials. The gate demonstrates the required atomicity; it is not evidence that native `thread_get_message/2-3` violates its existing contract. An early tight two-goal uninstrumented standalone probe did not reproduce in 1,000 trials on either original engine. The ungated adapter probe and controlled standalone are distinct evidence.

See `../receive-interruption-2026-10-23/REPORT.md` for the preceding natural fixed-batch failures (4/1,500 pinned; 3/1,500 upstream) and controls. No exact C/Prolog instruction was captured in those failing adapter processes. The repair covers the complete handoff rather than guessing a single failing instruction.

## Builds and installation

Separate source/build directories:

- `/Users/torbjorn.lager/.local/share/trinity-runtime-tests/receive-handoff-2026-10-23/pinned`
- `/Users/torbjorn.lager/.local/share/trinity-runtime-tests/receive-handoff-2026-10-23/upstream`

Bases:

- Pinned: `36f512f595e407e330f6e1f6b4eb339da2b0675e`.
- Upstream: exact unmodified v3.14.8 `42ebc2127e3f900036c6bcb54cfc11bec4762eb7`.

Build each with:

```sh
make -j4 NOSSL=1 NOFFI=1 \
  CC='clang -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
```

Pair every binary with its sibling `library/` via `TPL_LIBRARY_PATH`. Build logs and all hashes are retained. Both patches were checked in reverse against their candidate trees. No engine was installed, no live node restarted, and the original source trees were not modified. Original binary hashes remain:

- Pinned: `34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
- Original upstream: `a89f1f6c04d3e8637e0a8ee87cef03a18fac4dff29f25bb624534f47236fe441`.

## Files and rerunning

From the port root:

```sh
python3 reproducers/receive-handoff-repair-2026-10-23/run.py
TPL=/path/to/candidate/tpl ./tools/test.sh unit
```

- `run.py`, `results.json`, `batch.log`: fixed 224-process batch; exact commands, statuses, output, binary hashes and timings.
- `primitive_tests.pl`: standalone engine-only checks.
- `standalone.pl`, `standalone-results.json`: deterministic gated handoff control, original and candidate engines.
- `final-handoff-regressions.json`: final expanded adapter test results and test hash.
- `engine-regressions.json`, `engine-controlled-regressions.json`: engine-harness test results.
- `pinned-unit.*`, `upstream-unit.*`: full port unit suites; both exit 0.
- `*-build.log`, `provenance.json`: reproducible builds and hashes.
- `upstream-candidate.patch`, `pinned-candidate.patch`: engine implementation and native tests.
- `UPSTREAM-REPORT.md`: report/feature request, submitted as #1179; exact posted body is `submitted-body.md`.
- `../../receive_handoff_tests.pl`: permanent adapter regression.
- `../../worker_scope_tests.pl`: preceding stage diagnostics and original message assertion.

The installed engine is deliberately still on the original path. Upstream acceptance and a later explicit runtime update remain separate steps.

## Upstream submission

Submitted on 2026-10-23 as [Trealla #1179](https://github.com/trealla-prolog/trealla-prolog/issues/1179), after searching open/closed issues and reviewing the recent reports. The complete candidate patch and standalone tests are included inline. The published body was retrieved through the GitHub API and checked against `submitted-body.md` (ignoring surrounding whitespace). See `submission.json` and `upstream-1179-submitted.png`. The installed engine remains unchanged.
