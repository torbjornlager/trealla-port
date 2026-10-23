# Independent verification of Claude's pinned-engine mutex-exit repair

23 October 2026. Reran the checks independently against the existing separate
repair build. Installed Trealla, production runtime source and live nodes were
not changed. No engine was installed, upgraded or rebuilt for this verification.

## Verified builds

Repair checkout:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/pinned-unlock-all-repair-2026-10-23`.
Executable SHA256:
`bcc82045c106675aa5921aa565da1e4989bc5cddc835df599975b109f46f279a`.

Control checkout:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/pinned-cancel-status-repair-2026-10-23`.
The control already contains the cancellation/status backport but lacks the
`do_unlock_all()` repair. Both are separate builds based on pinned v3.13.10.

I checked the actual C files: ignoring comments and whitespace, they differ
only in `do_unlock_all()`. The repaired function is byte-for-byte identical to
that function in the clean upstream v3.14.5 assessment checkout. The
[control-to-repair diff](control-vs-repair-source.patch) is retained.
The repair executable matches the hash in Claude's report. This verifies the
reported existing build; it is not an independent rebuild from source.

## Fixed batch results

Fresh processes; same existing fixture and driver commands on both builds:

| Check | Repair | Control without mutex-exit fix |
|---|---|---|
| Delivery race: 30 processes, 30 cases each, 12-second process watchdog | 30/30 pass; 900 cases | 26/30 pass; 3 mutex ownership errors, 1 stall |
| Full lifecycle: 30 processes, 20-second watchdog | 30/30 pass | 27/30 pass; 3 mutex ownership errors |

Thus repair passes **60/60 processes**, while the control fails **7/60** in this
independent run. All six control exceptions contain
`permission_error(mutex_unlock,not_locked_by_me,'$rpc_promise_lifecycle')`.
The delivery stall stops after entering cleanup; its pre-termination sample is
retained in `delivery-control-24-sample.txt`.
No repaired process crashed, stalled, emitted stderr or missed its completion
marker. Every counted batch pass requires exit 0, empty stderr and the suite
completion marker; process exit 0 alone is not sufficient.

- [Delivery batch](delivery.json).
- [Full lifecycle batch](lifecycle.json).

The two batch processes were dispatched independently; repair/control trials
within each batch ran sequentially. Engine/unit regression suites were dispatched
after the repaired batch output had progressed, while some control activity
could still be running. This is a stress verification, not a benchmark or a
controlled timing comparison. No numerical probability claim is made.

## Regression suites

### Engine tests: 533/533 pass

Ran the repair checkout's unchanged `sh tests/run.sh`, with its matching adjacent
library. Summary: `Failed: 0`, `Succeeded: 533`, process exit 0; about 50 seconds.
This includes the two added thread-status regressions in that checkout.

macOS has no `timeout` command here. A scratch Python timeout shim implements
its timeout/exit-code behavior, including killing the test process group on
expiry; no system command was installed. A copy is retained as
[timeout-shim.py](timeout-shim.py).
The suite compares each test's stdout against its expected file and requires a
successful process exit. Combined stdout/stderr is retained without filtering;
there is no claim that the suite enforces empty stderr for every engine test.

- [Engine suite log](engine-suite.log).
- [Process result](engine-suite-result.json).

### Web Prolog units: 72/72 groups pass

Ran the same 72 `tools/test.sh unit` groups using a scratch copy of the runner
that records failures and continues, so an early failure cannot conceal the
remaining groups. All test commands, group ordering and 30-second per-group
watchdogs are preserved. Only ROOT resolution and failure/final accounting are
changed; [unit-runner.patch](unit-runner.patch) records those changes.
The repository's runner was not edited.

Summary: 72 group headers, no `RECORDED FAILURE` entries,
`RECORDED UNIT FAILURES: 0`, process exit 0; about 92 seconds.
The previously flaky HTTP paging cleanup group passed in this run. One passing
run does not establish that its intermittent failure is fixed.

- [Web Prolog unit log](web-prolog-unit.log).
- [Process result](web-prolog-unit-result.json).

The interop suite was not run. These results do not certify network
interoperability, other platforms, or a replacement of the installed engine.

## Interpretation

These independent results support Claude's diagnosis and bounded repair:
exit-time mutex bookkeeping in the old pinned engine is responsible for a
reproducible class of ownership errors/stalls. With all other C logic held equal,
substituting the upstream `do_unlock_all()` removes these observed failures in
this batch. This does not reveal the exact failing instruction interleaving, or
prove that every historical silent exit/stall has the same cause.

The repair takes the registry lock, clears ownership before releasing the mutex,
and releases it once per recorded recursive acquisition. The cancellation/status
backport in both builds is a separate prerequisite; the control comparison does
not attribute its benefits to `do_unlock_all()`.

## Reproduction and preservation

From `/Users/torbjorn.lager/Documents/GitHub/trealla-port`:

```sh
python3 reproducers/pinned-lifecycle-2026-10-23/run_batches.py \
  --engine repaired=/path/to/pinned-unlock-all-repair/tpl \
  --engine control=/path/to/pinned-cancel-status-repair/tpl \
  --case delivery --iterations 30 --runs 30 --timeout 12 \
  --output /tmp/delivery-independent.json

python3 reproducers/pinned-lifecycle-2026-10-23/run_batches.py \
  --engine repaired=/path/to/pinned-unlock-all-repair/tpl \
  --engine control=/path/to/pinned-cancel-status-repair/tpl \
  --case full --runs 30 --timeout 20 \
  --output /tmp/lifecycle-independent.json
```

For engine tests, put the timeout shim on a scratch PATH as `timeout`, set
`TPL_LIBRARY_PATH` to the repair build's adjacent library, and run `sh tests/run.sh`
from that build's checkout. For the Web Prolog units, use the recorded scratch
runner changes and set `TPL` to the separate repair executable.

[Provenance](provenance.json) records source/engine hashes, the port commit and
verified counts. The installed executable remains SHA256
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
`rpc.pl`, `rpc_lifecycle_tests.pl` and `tools/test.sh` were unchanged during this
verification. Claude's report and investigation files were not overwritten.
No upstream issue was posted or closed.
