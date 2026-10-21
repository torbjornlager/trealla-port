# Trealla delegated-lineage receiver: work in progress

Status: **resumed 21 October 2026; toplevel `actor_exit` repair implemented;
the duplicate-close teardown race has been repaired in `actors.pl` (commit
e3fee4f).** One rare, uncharacterised `creation_race` failure remains. See
`docs/shutdown-stall-investigation-2026-10-21.md`.

This document records the current work. It is a handover, not a claim that the
batch is complete.

## Objective and agreed boundary

Implement receiver-side compatibility with native SWI's delegated lifetimes.
An authorised node transport supplies a lineage identifier, and Trealla must
keep the resulting local work separate from other lineages sharing that
connection. An explicit `lineage_close` must close that namespace, reclaim its
registrations and promises, and terminate its local actors and descendants.
Connection teardown must close all delegated namespaces on that connection.

Preserve ordinary remote spawning, legacy traffic, sandbox checks, names visible
node-wide, reply formats, unrelated monitors and unrelated connections. Do not
add downstream propagation of ownership or cancellation through further remote
nodes. Do not change book examples or installed engines/deployment configuration.

The user subsequently authorised a bounded repair for `actor_exit` handling,
preserving ordinary query errors and unrelated monitors. **That repair has not
yet been implemented.** The later pause takes precedence over that authorisation
until the user resumes the work.

## Changes already made in the working trees

In `trealla-port`:

- New `receiver_lineage.pl` validates the transport authority, 32-character
  hexadecimal lineage identifiers and optional account identifiers. Lineage
  identity includes the receiving connection. Account validation does not add
  SWI's aggregate delegated-account resource accounting to Trealla.
- `web_prolog.pl` carries validated lineage context with queued relay commands,
  handles `lineage_close`, checks actor-control boundaries, preserves another
  lineage's monitor references, and closes delegated namespaces at connection
  teardown. A queued spawn rejected after closure reports failure to its waiting
  reader rather than leaving that reader blocked.
- `actors.pl` supplies an internal scoped namespace context, extends registry
  ownership to delegated namespaces, and rejects local creation after closure
  under the registry mutex. Local descendants inherit the namespace, including
  children created with `link(false)`.
- `rpc.pl` accepts delegated namespaces for existing promise disposal machinery.
- A startup gate in `actors.pl` and `isolation.pl` covers reserved children still
  preparing source. Closure blocks activation; these children finish preparation
  under the existing loader limits and report a startup error before entering
  their goal. Readiness and the startup acknowledgement are coordinated with
  closure under the registry mutex. This is not immediate cancellation of a
  blocked source fetch.
- `profile_policy.pl` recognises the close command; transport authority remains
  separately required.
- New `receiver_lineage_tests.pl` and `swi_lineage_compat.pl`, integrated into
  `tools/test.sh`, exercise the receiver and native SWI interoperability.
- README and the earlier synchronous interoperability assessment explain the
  supported boundary and remaining limitations.

Other documentation changes:

- `trinity-demonstrator/web/manual.html`: delegated ownership, local cleanup and
  the receiver-only Trealla qualification.
- `trinity-conformance/docs/BASELINE_DIFFERENCES.md`: replace the obsolete claim
  that Trealla has no close handler with the remaining downstream limitation.
  Published conformance reports have not been rewritten.

The default open endpoint does not grant `internal_transport` authority. Live
checks used a fixture-only peer bearer token on disposable loopback nodes. No
credentials or trust settings have been changed on n3 or n5.

## Verification completed

The focused receiver regressions pass. They cover:

- Authority, token/account validation and sandbox rejection of private helpers.
- Restoration of command context, even if the command leaves a choice point.
- Separate lineages on one connection and identical tokens on other connections.
- Local detached descendants, registrations, promises and unrelated owners.
- Repeated closure, late requests, queued startup rejection and creation races.
- Controlled closure during both named and unnamed source preparation: no user
  goal executes, and the waiting creator receives the startup failure.
- Connection teardown of all delegated namespaces.

A complete Trealla unit run on the current runtime changes finished with
`ALL unit TESTS PASSED` (`/tmp/trealla-lineage-unit-verified.log`). Earlier runs
had intermittent statechart-cleanup and worker-test `missing_unrelated`
failures. Subsequent focused comparisons passed three times each on the working
and committed baseline sources, and the later full run passed. Those earlier
failures have not been repaired or conclusively attributed by this batch.
The existing parser diagnostics associated with the separately reported engine
issue have not been eliminated by changing the installed engine.

Live wire and native actor checks passed against disposable Trealla nodes with
both blacklist and whitelist sandboxes. These include legacy actors sharing the
connection, cross-lineage control rejection, preservation of a sibling monitor,
late-spawn errors, detached-child cleanup and native SWI's distribution encoder.

**An additional native synchronous-toplevel cleanup check is still failing.**
The batch must not be described as fully verified until this is resolved.

## What the latest trace actually establishes

The apparent missing synchronous answer was a misdiagnosis of where the test
failed. Native SWI receives the correct correlated answer, approximately 3 ms
after sending the query:

```prolog
success(Top, [a], true)
```

The failure occurs later, after `lineage_close`, while waiting for the toplevel's
termination notification. The trace shows:

1. The native spawn-time monitor for `Top` still exists after the synchronous
   wrapper releases its private monitor.
2. Trealla then sends a correlated **query error** with payload `actor_exit`.
3. The ordinary actor in the same lineage sends its expected `down(...,kill)`.
4. The toplevel's expected `down` does not arrive within the test deadline.

Representative incoming frames, with identifiers simplified:

```text
{type:success, pid:Top, term:"[a]", more:true,
 toplevel_correlation:Request}
{type:error, pid:Top, term:"actor_exit", data:"actor_exit",
 toplevel_correlation:Request}
{type:down, pid:Root, ref:Root, reason:"kill"}
```

This points to **Trealla's Web Prolog toplevel exception handling**, which is
turning the actor termination unwind into a query error. The trace does not
support a missing synchronous answer or loss of the native SWI monitor.
The exact catch/recovery boundary still needs to be inspected and confirmed
before editing it. This is not yet evidence of a Trealla engine defect.

The failing live test is `swi_lineage_compat:native_owned_spawn/3`. It creates a
remote actor and a session toplevel in the same delegated lineage, obtains the
first page through native `toplevel_call_synch/4`, closes the lineage, and waits
for both termination notifications. It currently contains temporary stage
messages (`native_actor_created` and `native_toplevel_created`) and an explicit
unexpected-answer assertion; tidy these after completing the diagnosis.

## Toplevel `actor_exit` repair — implemented (see Update)

Inspect Trealla's toplevel query-error handlers and ensure a genuine actor
termination unwind escapes query-error conversion and reaches the actor's
outer termination handling. Keep ordinary user exceptions as query errors.

In particular, distinguish an actual termination already recorded by
`actors:exit/1-2` from a user simply throwing the atom `actor_exit`. Check whether
the existing `actors:actor_terminating/0` provides the required distinction.
Avoid treating every occurrence of that atom as an instruction to terminate.
Also preserve the existing timeout/abort handling and private and unrelated
monitor references.

This is a bounded integration repair within the agreed receiver batch: lineage
closure must be able to terminate a toplevel waiting between pages. It should
not require a public protocol change or native SWI runtime modification.
If the investigation requires more extensive lifecycle changes, explain that
and discuss the expanded scope before proceeding.

Add regressions for termination while waiting between pages and, where the
same handler applies, during query execution. Verify that ordinary exceptions,
a user-thrown `actor_exit`, timeout behaviour and unrelated monitors retain their
intended semantics. Then rerun the focused receiver tests, the extended native
SWI live checks in both sandbox modes, and the relevant toplevel/worker cleanup
regressions. Update the documentation if the observed contract needs adjustment.

## Update: toplevel repair done, intermittent closure stall found

**Repair.** `toplevel_actors:handle_error/4` now rethrows `actor_exit` only
when `actors:actor_terminating/0` holds, i.e. `actors:exit/1` has already
recorded a reason. The unwind then escapes `run_call/8` and the session loops
and reaches `actors:start/5`. A user-thrown `actor_exit` with no committed exit
remains `error(Pid,actor_exit)`. `'$abort_goal'`, `'$resource_idle'` and
time-limit normalisation are unchanged.

`synchronous_toplevel_tests:exit_unwind` covers exit between pages, exit during
a blocked query, user-thrown `actor_exit` (session survives) and an unrelated
monitor. It fails with `no_toplevel_down(_)` when the new clause is disabled.
The temporary stage messages have been removed from
`swi_lineage_compat:native_owned_spawn/3`. That test now passes against
disposable nodes in both blacklist and whitelist modes, and README notes that
lineage toplevels terminate with an ordinary `down`.

**New finding: intermittent stall on closure (not caused by the repair).**
`receiver_lineage_tests` fails or hangs in about 15–30 % of runs, in
`namespace_isolation` right after `close_namespace(NS)`. Root's
`down(...,kill)` never arrives, or `assert_gone(Child)` loops forever.
The rate was 4/12 with the toplevel repair disabled and 2/12 with it enabled.
The committed `ws_client` teardown tests (`rpc_namespace_tests`,
`namespace_tests`) passed 15/15 each. Probes on the stuck actor showed:

- `exit_reason(Pid,kill)` is recorded, so the signal ran and `exit/1` committed.
- `stop/2` has not started: it would have retracted `exit_reason` first.
- The actor does not respond to `finish`, so it is not back in its `receive`.
- `'$actor_registry'` is free, so this is not a registry deadlock.

The actor therefore stalls between `throw(actor_exit)` in the signal handler and
its `at_exit` hook. It may be in `in_temporary_module/3` cleanup, or in the
engine's handling of a signal thrown during a blocked `thread_get_message`.
Root and Child are signalled back-to-back while each is blocked in `receive`.
Pinning this down needs lifecycle or engine-level investigation, which is
beyond the bounded repair, so scope must be agreed before continuing. The test
harness's 30 s per-group timeout turns the stall into a unit-suite failure.



Repositories:

- `/Users/torbjorn.lager/Documents/GitHub/trealla-port`
- `/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator`
- `/Users/torbjorn.lager/Documents/GitHub/trinity-conformance`

Temporary diagnostic files (not durable test assets):

- `/tmp/lineage-native-trace.log` — native sends, correlated answer, retained
  spawn-time monitor, query error and missing toplevel-down diagnostic.
- `/tmp/swi_lineage_trace.pl` — instrumented copy of the compatibility fixture.
- `/tmp/run-trealla-lineage-live.py` and
  `/tmp/run-trealla-lineage-trace.py` — disposable-node launchers.
- `/tmp/trealla-lineage-live.log` — latest disposable Trealla server log.
- `/tmp/trealla-lineage-unit-verified.log` — completed passing full unit run.

Use the pinned Trealla binary and its matching library directory for repeatable
checks. No candidate upstream engine patches have been installed. Disposable
live-check nodes were terminated by their launchers; existing n3/n5 deployments
were left unchanged.

These changes are **uncommitted and unpushed**. The preceding assertion-expansion
investigation was committed and pushed separately as `753be5a`; it is not part of
this unfinished receiver implementation. Do not accidentally include unrelated
book files when eventually committing this work.

## Follow-up investigation, 21 October 2026

See `docs/shutdown-stall-investigation-2026-10-21.md` for the recorded bounded
investigation and raw artifact paths. A fresh upstream v3.13.26 build also fails
the duplicate-close receiver test. Removing only the second immediate close in
a diagnostic copy passed 10/10 on each engine, versus 6/10 with both closes.

A standalone native-thread test exposes the risk of withdrawing the first-exit
guard at the beginning of `at_exit`: a second request can record the reason
again and interrupt cleanup. Thus the earlier inference that a remaining exit
reason proves `stop/2` never began was too strong. Retaining the guard makes all
20 standalone controls pass on each build. Most failure-mode trials instead
exit silently without the completion marker; that symptom is not yet explained.
Do not claim a fully classified upstream engine defect from these results.

No runtime code was changed by this follow-up. A lifecycle repair remains to be
agreed and implemented; the current installed engine and live nodes are unchanged.

**Later update (21 October 2026):** the lifecycle repair has since been agreed and
implemented in `actors.pl` (commit e3fee4f). Its design and before/after results
are recorded in `docs/shutdown-stall-investigation-2026-10-21.md`.
