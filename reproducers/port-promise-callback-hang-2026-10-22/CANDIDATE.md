# Separate candidate engine repair — 22 October 2026

The bounded import repair fixes the reduced lost-state case and the original
callback hang in a separate build. The installed/pinned engine and production
port sources remain unchanged. The full engine/application suites and live
interoperability matrix have not been run for this candidate.

## Patch and build

- Base: upstream `beed430deca9fa48adf028541ea4c3e2bd8d3641`.
- Candidate checkout:
  `/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/import-repair-2026-10-22`.
- Separate build command:
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4`.
- [Patch](../bug-028-use-module-state.patch) includes the engine regression and
  expected output; `git apply --check` passes on the untouched baseline checkout.
- [Upstream report](../bug-028-use-module-state.md), submitted as
  [Trealla #1176](https://github.com/trealla-prolog/trealla-prolog/issues/1176).
  The inline patch, including tests, was verified against the tested patch after
  publication. Duplicate searches covered open/closed issues and import-related PRs.
- [Provenance](candidate-provenance.json) records executable and patch hashes.

The patch adds a parser import flag carried through private loading helpers.
Only import-driven file parses suppress the explicit-reconsult branch when the
module already exists. Public C loading signatures remain unchanged. No loader
cache, ownership table or application callback workaround was added.

## Results

| Check | Result |
|---|---|
| Original callback, five fresh candidate processes | 5/5 pass |
| Standalone state preservation by file import | 5/5 pass |
| Module-name import control | 5/5 pass |
| Port trace and actual registry/promise table probes | All pass |
| New engine full/selective/reexport/thread import and explicit-reload regression | Pass; fails on unmodified baseline |
| Five existing consult/make/path-resolution regressions | All match expected output and exit 0 |
| Complete promise correctness group | Pass |
| HTTP read-timeout enforcement, cleanup, local timeout callbacks and retry | Pass |

- [Candidate comparison](candidate-comparison.json): the runner retains its label
  `upstream` for the explicitly selected candidate binary; see its engine path/hash.
  The original [unmodified comparison](comparison.json) is retained separately.
- [Candidate stage and table traces](candidate-traces.json).
- [Engine regressions](engine-regressions.json), including the unmodified failure.
  macOS lacks coreutils `timeout`; a temporary Python subprocess timeout wrapper
  was used for these shell tests. Expected output and exit status were both checked.
- [Promise and initial lifecycle run](candidate-promise-regressions.json).
- [HTTP timeout fixture](candidate-http-timeouts.json).

## Unresolved diagnostics kept separate

The initial supplemental lifecycle run exited with SIGSEGV after eight passing
stages, before the final delivery/cleanup-race success marker. A local crash report
names `do_thread_property_pin_both`. Three subsequent fresh-process candidate runs
and three unmodified runs pass:
[lifecycle repeats](lifecycle-repeat-diagnostics.json). This is an unresolved
intermittent diagnostic, not a passing initial run or proof of independence from
the patch.

The initial thread-import regression attempted to let `load_text/2` create its
new destination module inside the thread and crashed in `bif_load_text_2`.
The [standalone diagnostic](thread-file-import.py), which imports an ordinary
small file through a helper inside a thread, reproduces SIGSEGV on both builds:
[unmodified 3/3](thread-file-import-unmodified.json),
[candidate 3/3](thread-file-import-candidate.json). The final engine regression
explicitly creates its destination module first, matching the existing actor
startup sequence, then tests the threaded import into that module. It therefore
makes no claim to fix thread-time module creation.

An exploratory attempt to assert `predicate_property(_, exported)` in the
reexport case was removed: that property did not hold under the existing engine
behavior. The retained check verifies state preservation and callable imports
through the existing reexport loader path, without claiming new reexport semantics.

## Boundaries and recommendation

The minimal import report and candidate patch are now upstream for review; do not
install this build yet. Track the thread-time module-creation crash separately
and reduce the intermittent lifecycle/property crash before an upgrade decision.
The HTTP timeout fixes remain effective in this candidate. No user callback,
installed engine, live n3/n5 node, language manual or book example was changed.
