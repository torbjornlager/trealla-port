# Apparent promise callback hang: module re-import loses runtime state

Initial investigation date: 22 October 2026. No runtime repair, engine patch,
installation or live-node restart was made during the initial trace below.
A subsequent [separate candidate build](CANDIDATE.md) now fixes this regression
in focused checks; its additional diagnostics and upgrade boundaries are retained.
This is a module-loading regression in the tested
separate upstream engine, rather than a demonstrated timeout-callback defect.

## Builds and repeatability

Port revision: `1be82f8e0a2d01d10a30c7f8a499420a91d96cdb`.

- Pinned Trealla v3.13.10: `36f512f595e407e330f6e1f6b4eb339da2b0675e`.
- Separate upstream v3.14.5: `beed430deca9fa48adf028541ea4c3e2bd8d3641`;
  existing macOS arm64 build with `NOSSL=1 NOFFI=1`.
- Both executables used their own adjacent `library` directory.
- Fresh processes, five trials per engine/case, three-second external watchdog.
  A zero exit without the explicit pass marker is not counted as a pass.

| Case | Pinned | Separate upstream |
|---|---|---|
| Original `promise_actor_callback_test` | 5/5 pass | 5/5 watchdog timeouts |
| Standalone file-path import retains asserted fact | 5/5 pass | 5/5 lose fact, explicit assertion error |
| Same standalone import by existing module name | 5/5 pass | 5/5 pass |

[comparison.json](comparison.json) contains all 30 results and executable hashes.
The installed binary retains SHA256
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
The separate upstream source checkout remains unmodified.

## Actual failing stages

The [initial trace](initial-stages.json) locates the hang after child entry and
before `yield/3` returns. The parent has not returned from `spawn/3`.
Further stage tracing reaches the promise-accessibility check inside the
lifecycle mutex; the mutex itself is acquired successfully. The callback is
never reached.

The [exception trace](callback-error-trace.json) records the actual child error:

```prolog
error(existence_error(promise,1000000000),
      context(rpc:yield/3,'unknown, consumed, or expired promise'))
```

The [observer](observer.json) finds no promise state and no pid/thread mappings
by then. This explains why neither startup nor termination completes the parent
wait. It is not evidence that a timeout callback loops.

A [direct table-import probe](actual-table-imports.json), without actor startup,
is more specific: on upstream, importing `actors.pl` by file path removes the
existing parent pid/thread mapping; importing `rpc.pl` by file path removes the
existing promise record. Both records survive on pinned. The two imports were
run in separate processes, so the effects are independent.

The original actor source bootstrap imports these same framework files. Losing
the actor registry prevents readiness delivery to the parent's pid, leaving the
parent in the startup handshake. Losing the promise record makes the child
raise the missing-reference error; its monitor relation has also been erased.

## Standalone reduction

Only two tiny files are needed: [state-library.pl](state-library.pl) exports a
dynamic `state/1`, and [import-state.pl](import-state.pl) imports it, asserts
`state(kept)`, then imports the same file into a second module with `load_text/2`.
There are no Web Prolog imports, threads, queues, sockets or callbacks.

```prolog
assertz(callback_probe_state:state(kept)),
load_text(':- use_module(\'/absolute/path/state-library.pl\').',
          [module(callback_probe_importer)]),
findall(X, callback_probe_state:state(X), After).
```

Pinned returns `After = [kept]`; the separate upstream build returns `After = []`.
The control replacing the file path with the existing module name
`callback_probe_state` retains `[kept]` on both builds.

Reproduce the complete comparison from any working directory:

```sh
python3 /path/to/trealla-port/reproducers/port-promise-callback-hang-2026-10-22/run.py \
  --pinned /path/to/pinned/tpl --upstream /path/to/separate-upstream/tpl \
  --output /tmp/callback-comparison.json
```

The runner is diagnostic: it records the expected current failures rather than
pretending the original test passed. [staged.pl](staged.pl) retains the detailed
port-side stage and table probes.

## Source explanation and smallest repair

Source inspection of the tested upstream revision shows:

1. `src/module.c:do_use_module` resolves an existing module name directly, but
   a file-path import goes through `load_file` in the importing module's context.
2. `src/parser.c` handles the imported file's `module/2` declaration as a reload
   when the original module already knows that file.
3. That branch calls `unload_file`; `unload_realfile` discards clauses for the
   affected predicates, including the asserted dynamic facts in this reduction.

The reload branch is present in commit
`82fc93980a2e7b722b89d1e54ccc44e4d9515bf0` ("Reload module files on consult/1
as on make/0, keep runtime state, retry failed loads, and keep the load base per
thread"). This investigation inspected that code; it did not bisect or patch it.

The smallest appropriate fix is in Trealla's import loader: a normal
`use_module(File)` of an already-loaded module should attach imports to that
module without treating it as an explicit reconsult. Preserve the intended
explicit `consult/1`/`make/0` reload behavior separately. Add this state-preservation
case for file imports, including selective imports and a threaded importer.
The exact engine patch and compatibility with reload behavior still require
separate implementation and testing.

A port workaround could import already-loaded framework modules by name instead
of file path, with care for first-load/path-resolution behavior. The standalone
control supports that direction, but no such workaround was applied or validated
across the full actor bootstrap. Prefer fixing the engine's import semantics to
expanding promise/callback machinery or masking missing-reference errors.

This finding is suitable for an upstream report. Nothing has been submitted in
this investigation. Keep the installed engine unchanged; propose and test any
engine repair in a separate build before considering an upgrade.
