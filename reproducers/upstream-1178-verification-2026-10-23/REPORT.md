# Verification of unmodified upstream Trealla fix for #1178

23 October 2026. Tested commit
[`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`](https://github.com/trealla-prolog/trealla-prolog/commit/42ebc2127e3f900036c6bcb54cfc11bec4762eb7),
identifying as **v3.14.8**, in a new separate, unmodified source checkout.
No candidate patches were applied. Installed/pinned engine and live nodes are
unchanged; this verification does not authorize an upgrade or close an issue.

## Results

All invocations use the matching adjacent library and an external watchdog.
A pass requires the completion marker, exit 0 and empty stderr; engine regression
checks additionally compare exact expected stdout. Failures are retained.

| Check | Result | Artifact |
|---|---|---|
| Original exceptional-termination tight-loop probe, 20 fresh processes, up to 1,000 iterations each | 18 pass; 2 exhaust the 1,000-poll budget; no SIGSEGV | `exception-standalone.json` |
| Exception probe with a two-second elapsed-time budget per retirement, 20 × 1,000 | 20/20 processes pass, 20,000 iterations | `exception-deadline.json` |
| Standalone minimal cancellation, 30 processes × 10 | 30/30 pass, 300 cases | `cancel-minimal.json` |
| Standalone concurrent cancellation, 30 × 10 | 30/30 pass, 300 cases | `cancel-standalone.json` |
| Strict cancellation-status regression, 20 × 300 | 20/20 exact passes, 6,000 cancellations | `engine-checks.json` |
| Full diagnostic Web Prolog lifecycle group, 30 fresh processes | 30/30 pass | `full-lifecycle.json` |
| Focused hard-cancel lifecycle, 30 × 10 | 30/30 pass, 300 cases | `hard-cancel-lifecycle.json` |
| Upstream's own new `tests/misc/thread_status_retirement.pl`, five processes | 5/5 exact passes | `upstream-regression.json` |
| Eight existing thread regression groups | All eight exact passes | `engine-checks.json` |

The full lifecycle group includes expiry, collector interruption, waiting
disposal, hard-cancel cleanup, startup rollback and 30 delivery-race iterations
per process. No stall sample was needed in these runs.

## What the results establish

The observed detached exception/cancellation SIGSEGV is not reproduced on this
upstream build in these checks. The standalone minimal and concurrent
cancellation probes load no Web Prolog files. They are the probes subsequently
added during the Claude handover follow-up, not the earlier application fixture.

The strict status regression permits only `running` or `exited(cancelled)` for
a cancelled thread that still has a status, followed by thread retirement.
It rejects `status(true)`. All 6,000 cancellations meet that check. Its inherited
retirement-error handler also accepts the older dispatch `uninstantiation_error`
as well as `existence_error`; it does not establish that every retired-handle
error is classified correctly. A copy is retained as `cancel-status-check.pl`
with its exact expected output for reproduction.

The eight existing groups are `thread_join_exception`, `thread_detach_joining`,
`thread_signal_delivery`, `thread_signal_blocked`, `thread_cancel_blocked`,
`thread_exit_mutex`, `thread_option_errors` and `thread_mailbox`.

## Original exception-probe failures — retained separately

Trials 15 and 16 of the unchanged original probe print
`throw(property_poll_exhausted(...))` at iterations 83 and 178 respectively.
Both exit 0 without the completion marker and therefore count as failures.
Neither crashes. The original bound is a number of tight polls, not elapsed
seconds; the entire processes lasted approximately 0.029 and 0.062 seconds.
Those results do not by themselves establish an engine retirement hang.

The follow-up `exception-deadline.pl` uses the same detached throw/status-poll
pattern, no sleeps, and a measured two-second deadline per retirement. It catches
only `existence_error(thread_object,_)` as retirement and fails on other errors
or deadline expiry. It passes 20/20 processes. This is a separate test with a
different bound, not a waiver or rewrite of the original two failed runs.

## Build and provenance

Checkout:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/upstream-1178-42ebc21-2026-10-23`.

Build:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4`.
Build log is adjacent as `upstream-1178-42ebc21-build-2026-10-23.log`.
The checkout remains clean. [Provenance](provenance.json) records the exact
revision, executable/library paths and source/engine hashes. The installed
v3.13.10 executable's hash is unchanged.

The tested revision also has earlier upstream changes, including #1177 work in
its ancestry. This is verification of the stated upstream snapshot, not an
isolation study attributing every lifecycle improvement solely to one commit.
The port fixture and cancellation-probe changes from the handover follow-up are
still present in the shared working tree and were not overwritten.

## Reproduction

From the trealla-port checkout, replace `/path/to/upstream/tpl` with the recorded
separate executable:

```sh
python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine upstream_1178=/path/to/upstream/tpl --runs 20 --timeout 20 \
  --goal "consult('reproducers/lifecycle-crash-2026-10-23/thread_property_race.pl'),(run_property_race(exception,1000)->halt;halt(1))" \
  --output /tmp/exception-original.json

python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine upstream_1178=/path/to/upstream/tpl --runs 20 --timeout 20 \
  --goal "consult('reproducers/upstream-1178-verification-2026-10-23/exception-deadline.pl'),catch((exception_deadline->halt;halt(1)),E,(writeq(E),nl,halt(1)))" \
  --output /tmp/exception-deadline.json

python3 reproducers/pinned-lifecycle-2026-10-23/run_batches.py \
  --engine upstream_1178=/path/to/upstream/tpl --case standalone_concurrent \
  --runs 30 --iterations 10 --output /tmp/cancel-concurrent.json

python3 reproducers/pinned-lifecycle-2026-10-23/run_batches.py \
  --engine upstream_1178=/path/to/upstream/tpl --case full \
  --runs 30 --output /tmp/lifecycle.json
```

Use `--case standalone_minimal` or `--case hard_cancel` for the other focused
batches. To run the strict status test directly, set `TPL_LIBRARY_PATH` to the
selected engine's adjacent library and invoke that engine with
`-q reproducers/upstream-1178-verification-2026-10-23/cancel-status-check.pl`;
require exit 0 and output matching `cancel-status-check.expected`.

Full engine suites, live interoperability, TLS, WASM and other operating systems
were not tested. No upstream issue was commented on or closed in this batch.

## Upstream follow-up

On 23 October 2026, posted the [verification update](https://github.com/trealla-prolog/trealla-prolog/issues/1178#issuecomment-6362180358) and closed #1178 as completed. The comment explicitly retains the two
tight-poll-budget failures, distinguishes upstream checks from the separate
mutex-exit backport suite, and confirms the existing mutex-exit fix.
#1176 and #1177 were checked and remain open.
The [posted text](upstream-verification-comment.md) and
[closure record](upstream-closure.json) are saved locally.
