# Trealla shutdown-stall investigation — 21 October 2026

Status: investigation recorded at the user's request. **No runtime repair has
been applied by this investigation.** The installed engine and running nodes
are unchanged. The reduction needs further work before submitting an upstream
engine-bug claim.

## What I was asked to investigate

After Claude's bounded `actor_exit` repair, the synchronous-toplevel regression
passed, but delegated-lineage cleanup still intermittently failed to deliver a
termination notification or finish reclaiming an actor. The authorised task was
to reduce that stall without Web Prolog and compare a separate current-upstream
Trealla build, leaving the installed runtime unchanged.

## Engines used

| Engine | Revision | Executable SHA-256 |
| --- | --- | --- |
| Installed/pinned v3.13.10 | `36f512f595e407e330f6e1f6b4eb339da2b0675e` | `34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563` |
| Separate upstream v3.13.26 | `7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6` | `99b0115e85deb4a5b4b3ae2ba28a0ff36733aef575b3ba2a30b739f007177a41` |

The separate build is at:

```
/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-shutdown-stall/upstream-2026-10-21
```

I cloned the official upstream repository afresh. A first attempt to use the
previous shallow clone as a Git reference failed; a normal shallow clone then
succeeded. Upstream HEAD was still the revision above. I built it with:

```
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4
```

Each executable was paired with its own adjacent `library/` directory through
`TPL_LIBRARY_PATH`. Nothing was installed or put on the user's PATH. The final
installed-binary checksum matches the initial checksum. The upstream checkout
has no source modifications.

## Reassessment of the current port

I inspected Claude's changes to `toplevel_actors:handle_error/4` and
`synchronous_toplevel_tests.pl`. The handler rethrows `actor_exit` only after
`actor_terminating/0` confirms a committed exit. A user-thrown atom remains a
query error. The focused `exit_unwind` regression passed in my reassessment.

For the current lineage suite, five fresh-process runs passed and the sixth
hit an external eight-second timeout after the initial validation output.
This independently reproduced the remaining intermittent problem.

I then used a **temporary instrumented copy** of the receiver tests, without
editing runtime code. It printed stages around family creation and the two
immediate `close_namespace/1` calls, bounded the otherwise unbounded child
retirement wait, and dumped remaining actor records on failure.

A failing pinned run showed a root with an explicit `kill` reason and a native
thread handle whose status was no longer available, while its child had gone.
A failing upstream run showed both root and child with `kill` records and native
handles whose status was unavailable. These observations alone do not locate
where cleanup stopped.

## Important finding: the duplicate-close window

The receiver test calls `close_namespace(NS)` **twice immediately** to test
idempotency. Both calls can signal the same still-visible actor.

The current actor implementation does the following:

1. `actors:exit/1` records the first exit reason, then throws `actor_exit`.
2. `actors:commit_exit/3` avoids a second throw only while an exit-reason record
   already exists.
3. The native thread enters its `at_exit` hook, `actors:stop/2`.
4. At the start of `stop/2`, `down_reason/2` **retracts** the exit-reason record.
5. There is still cleanup to perform before `down` is delivered.
6. A second pending exit request can now see no exit reason, record it again,
   and throw `actor_exit` while the cleanup hook itself is running.

That is a concrete race in the lifetime of the first-exit guard. It also changes
how to interpret the earlier probes: a remaining `exit_reason(Pid,kill)` does
**not prove that `stop/2` never started**. The first record may have been removed
and then recreated by the second exit request.

### Port-level comparison

I compared instrumented copies of `namespace_isolation/0`, changing only whether
the second immediate close was present. Each trial used a fresh engine process.

| Engine | Two immediate closes | One close |
| --- | --- | --- |
| Pinned v3.13.10 | 6/10 passed | 10/10 passed |
| Upstream v3.13.26 | 6/10 passed | 10/10 passed |

The raw observations are saved in:

```
reproducers/port-repeated-exit-lineage-controls.json
```

This supports the duplicate-exit explanation. It is not a proposal to delete the
idempotency test or to weaken the requirement that repeated closure be safe.

## Standalone reduction

The durable reduction is:

```
reproducers/port-repeated-exit-cleanup.pl
reproducers/port-repeated-exit-cleanup.py
reproducers/port-repeated-exit-cleanup-results.json
```

It imports **no Web Prolog code** and uses no networking, source loading or
temporary modules. One native thread catches the first `actor_exit`. Its
`at_exit` hook is held at a barrier so the parent can send another exit request
while cleanup is in progress.

Two policies differ only in the bookkeeping that guards repeated requests:

- `withdraw`: remove the exit-reason record at the beginning of `at_exit`, as
  the current actor cleanup does. The second request treats itself as the first
  and throws again.
- `retain`: retain the record during the hook. The second request is recognised
  as a duplicate and returns without throwing.

The barriers deliberately make the cleanup window reproducible. They are not
part of the full actor implementation. Retaining a fact in this toy process is
a diagnostic control, **not a complete proposed solution for runtime metadata
reclamation**.

### Final standalone results: 20 trials per policy per engine

| Engine/policy | Completed cleanup marker | Explicit missing-cleanup diagnostic | Exit 0 with no output |
| --- | --- | --- | --- |
| Pinned / withdraw | 0 | 1 | 19 |
| Pinned / retain | 20 | 0 | 0 |
| Upstream / withdraw | 0 | 3 | 17 |
| Upstream / retain | 20 | 0 | 0 |

An explicit failure looks like:

```prolog
missing_cleanup(withdraw,second_request(true),reason_recorded(yes))
```

The successful control prints:

```prolog
completed(retain,second_request(false))
```

**Important qualification:** most `withdraw` trials ended with exit code zero
and no output, rather than producing the intended diagnostic. These must not be
counted as successful cleanups: the explicit completion marker is absent. But
I have not yet explained that early, silent process exit. The runner currently
expects the explicit diagnostic and therefore exits nonzero for the recorded
batch. Its raw results preserve every outcome; a zero subprocess exit status
alone is not the pass criterion.

Consequently, the standalone test does demonstrate missing cleanup/completion
on both builds, with successful retained-guard controls. It is not yet a fully
stable reduction of every detail of the original stall. In particular, the
silent exits need investigation before calling this a well-characterised
upstream engine defect.

To repeat the recorded comparison:

```sh
python3 reproducers/port-repeated-exit-cleanup.py \
  --engine pinned="$PWD/.build/trealla-v3.13.10/tpl" \
  --engine upstream=/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-shutdown-stall/upstream-2026-10-21/tpl \
  --runs 20 \
  --output /tmp/repeated-exit-results.json
```

## Exploratory tests and limitations

Earlier raw tests of blocked threads, `setup_call_cleanup/3` and temporary
modules did not establish the original failure. An early reduction also omitted
the explicit mutex creation required by Trealla; those invalid signal-handler
results were excluded from the final evidence.

After that was corrected, a matrix of plain, temporary-module and additional
thread-cleanup variants passed 25 trials per variant on each build when the
first-exit record was retained. These controls helped isolate bookkeeping
withdrawal rather than requiring XML, HTTP, promises or temporary modules.

One earlier exploratory pinned run with overlapping source loading crashed with
signal 11. It was not reduced or attributed and is not evidence for the
repeated-exit conclusion. Existing source/module engine reports are separate.

The observed ability of a signal throwing an exception to interrupt an
`at_exit` hook does not, by itself, establish an engine bug. Our port must not
turn a duplicate termination request into a fresh unwind of its own teardown.
The silent standalone exits may raise a separate engine question; that remains
unresolved.

## Recommended next step (implemented below)

Investigate a narrow actor-runtime repair that keeps an unambiguous
"termination has started" guard effective throughout teardown, independently
of consuming the public exit reason. Preserve the first reason and complete
normal monitor delivery. Address eventual retirement of that guard rather than
leaving permanent per-actor metadata accidentally.

Then rerun the duplicate-close test and ordinary termination/monitor regressions
on both builds. Do not treat removing the second close, adding sleeps or blindly
retrying teardown as a fix. Repeating partially completed cleanup could lose
monitor snapshots or duplicate notifications.

Before submitting an upstream report, finish reducing and classifying the
standalone silent-exit behaviour separately from the port's bookkeeping race.
No report has been submitted for this investigation, and no candidate engine
patch has been installed or applied.

## Follow-up: termination guard applied to `actors.pl`

Status: a narrow port-level repair has been committed. The commit contains only
the repair hunks of `actors.pl` and this document. The uncommitted lineage-receiver
work, including `receiver_lineage_tests.pl` and the reproducer files named above,
is still only in the working tree. The engines and their checksums are unchanged.

### Why `exit_reason/2` alone could not be the guard

Trealla runs queued `thread_signal/2` goals inside the `at_exit` hook. It
stops only when it marks the thread non-alertable, after the hook returns. (See
`src/bif_threads.c`, v3.13.10, around the `at_exit_goal` call.) A signal is
handled *before* the goal it interrupts runs. So a `catch/3` placed at the start
of `stop/2` cannot protect the hook. A throw can happen before the catch is
installed. The guard therefore has to be in place before the hook starts, and it
must stay effective until the actor can no longer be found.

### The repair

1. **Close the gate inside the actor's own catch.** `start/5` now runs the
   actor body (`start_actor/5`) under an inner `catch/3` that captures the
   result as `true`, `false`, `exited` or `exception(Ball)`. It then records
   `actor_finishing(Pid)` under the registry mutex. All of this happens inside
   the outer `catch(..., actor_exit, ...)`. If an exit signal arrives before
   the gate closes, it is caught as an ordinary exit. Once the gate is closed,
   `replay_outcome/1` makes the thread end with the same success, failure or
   exception as before. Monitors still read the native thread status.
2. **Name the target in the signal.** `exit/2` now sends
   `actors:exit_signal(Pid, Reason)` instead of `actors:exit(Reason)`. This
   handler commits only if `pid_thread(Pid, Self)` still holds and neither
   `exit_reason/2` nor `actor_finishing/1` is present. Otherwise it is a
   no-op. In particular, it no longer calls `self/1`, so a late signal cannot
   register the dying thread under a fresh PID.
3. **Retire everything in one locked step.** `stop/2` now does all of the
   following in its single registry-mutex section, via `down_reason_unlocked/2`:
   it reads the native status, retracts `pid_thread`/`thread_pid` *first*, and
   then consumes `exit_reason/2` and `actor_finishing/1`. From the end of the
   goal until the mapping is gone, at least one guard fact exists. After that,
   the handler cannot find the actor. Nothing is left behind per actor.
   `actor_finishing/1` is retired along with everything else.
4. `commit_exit/3` (used by `exit/1`) and `ensure_registerable_local_pid/1` also
   respect `actor_finishing/1`.

The first explicit reason still wins. Teardown is never retried. Cleanup runs
once, and `down/3` is delivered once, after the registry section.

There is one remaining narrow window. Suppose an actor has finished normally
but has not yet recorded `actor_finishing`, and a kill arrives. It is then
reported with reason `kill`. Cleanup still completes.

This repair does **not** cover non-exit throwing signals:
`throw('$abort_goal')`, `throw('$rpc_promise_disposed')` and
`throw(page_interrupted)` (in tests). If one of these was queued before
`pid_thread/2` was retracted but is handled inside `stop/2`, it can still
abort the hook. New ones cannot be sent after the mapping is gone. No test
currently exercises this.

### Results

`receiver_lineage_tests:run`, fresh process per trial, 20 s timeout. "Before"
is a temporary copy with only this repair reverted (other uncommitted changes
kept). The working tree was restored and checked with `cmp`.

| Engine | Before repair | After repair |
| --- | --- | --- |
| Pinned v3.13.10 | 14/20 (2 timeouts, 4 failures) | 20/20, then 49/50 |
| Upstream v3.13.26 | 19/20 | 20/20, then 50/50 |

All failures before the repair stopped right after the first validation line,
inside `namespace_isolation` (the duplicate close). The one failure after the
repair happened later, in the 20× `creation_race` loop. That is a different
scenario, and its rate is about 1 per 1,000 race iterations (see below).

Other checks with the repair:

- `synchronous_toplevel_tests`: 3/3 on each engine.
- `./tools/test.sh unit` on pinned: **all passed**.
- `./tools/test.sh unit` on upstream: one failure, in *supervisor replacement
  startup failure cleanup*. That group then passed 10/10 and 30/30 in
  isolation on upstream, and 10/10 on pinned. No pre-repair baseline was
  measured for it, so it is unattributed.
- The upstream log also shows `syntax error, start of rule expected,
  $trealla_actor_…:1` lines in the passing statechart and RPC groups. These are
  not related to this repair.

Committed state (HEAD plus the repair only, in a temporary worktree, pinned
engine). Two runs of `./tools/test.sh unit` each had one failing group, and the
failing group was different each time. Both groups are flaky without the repair:

- *HTTP client execution context*: HEAD 5/5, with the repair 5/5 on re-run.
- *HTTP paging request cleanup*: HEAD 22/25, with the repair 24/25.

### `creation_race` residual — not reproduced

The one pinned failure printed no exception. It stopped after the named
preparation line, so a goal in the `creation_race` loop failed. Its raw output
did not identify which step failed.

A temporary traced copy of the race checked each step with a bound and dumped
any leftover actor records on failure. It was not committed. It ran on pinned
with the repair:

- 6 processes × 200 iterations, race only: 1,200/1,200 passed.
- 100 processes, each running the full suite prefix (`authority_and_tokens`
  through `preparation_race(named)`) and then 20 traced iterations:
  100/100 passed (2,000 iterations).

Counting the regular suite runs, the failure has appeared once in about 4,200
race iterations. It is not characterised. It is not known to be caused by the
repair, because no pre-repair baseline reached this loop often enough to
compare. If it recurs, the traced copy is the starting point: it names the
failing step, such as a missing `raced/3` reply, a child still registered, the
worker's down reason, or a leftover `actor_namespace/2`.
