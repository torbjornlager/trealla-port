# Trealla #1177 verification on unmodified upstream

23 October 2026. Separate unmodified Trealla v3.14.8 at
`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`, with its matching adjacent library.
The checkout is clean, no candidate patch was applied, and the installed engine,
production runtime code and live nodes remain unchanged.

Upstream `3d0f2ebb70daa32cbcd6759ffb4716d64c3d6831` adds the two null-parser guards
at the `load_text/2` and internal `'$module'/1` informational logging sites.
`3b2c9c0c` moves the new engine test to `tests/misc` because WASM has no native
threads. Both commits are present in the tested snapshot.

## Results

| Check | Result |
|---|---|
| Standalone `load_new` thread-time module creation | 20/20 pass |
| Standalone `module_new` thread-time module creation | 20/20 pass |
| Existing-module controls, both paths | Each 20/20 pass |
| Command-query controls, both paths | Each 20/20 pass |
| Original thread-file-import diagnostic | 3/3 pass, exactly `status(true)` |
| Upstream `tests/misc/thread_module_creation.pl` | 20/20 exact-output passes |
| Existing temporary_module, module_qualifier_errors, meta_goal_module, retract_module_scope, op_module_visibility | All five exact-output passes |

All **148 process invocations** exit 0 with empty stderr. The standalone runner
requires the exact expected stdout, including informational messages only for
the command cases. It verifies both the child's successful status and the actual
predicate contents in child and parent. Variable module qualifiers prevent
compilation from pre-creating the new destinations. Every standalone invocation
has a five-second process watchdog. The original import diagnostic also has a
five-second watchdog. Engine regressions have a 60-second external watchdog and
require stdout exactly equal to the upstream expected files as well as exit 0
and empty stderr.

The previously crashing two paths no longer crash in these checks. Original
v3.14.5 failure evidence and the separately patched candidate results remain in
[the original report](../thread-module-creation-2026-10-22/REPORT.md). They were
not regenerated in this verification batch.

## Conclusion and boundaries

The null-parser defect is verified fixed on this unmodified upstream snapshot.
After explicit user authorization, #1177 was closed as completed on 23 October
2026 with the results and qualifications below. The #1176 closure is recorded
separately in its verification directory.

This is focused macOS arm64 verification of the null-parser defect, not a
concurrency audit of competing module creators or a full engine/application,
live interoperability, TLS, WASM or other operating-system run. It does not
approve an installed-runtime upgrade.

## Artifacts and reproduction

- [Standalone results](standalone.json), using the existing
  [runner](../bug-029-thread-module-creation.py) and
  [fixture](../bug-029-thread-module-creation.pl).
- [Original thread-import results](original-thread-import.json), using the
  [original diagnostic](../port-promise-callback-hang-2026-10-22/thread-file-import.py).
- [Engine regression results](engine-regressions.json) and [runner](verify.py).
- [Exact provenance and hashes](provenance.json).

Run from the trealla-port root:

```sh
python3 reproducers/bug-029-thread-module-creation.py \
  --engine upstream=/path/to/upstream/tpl --runs 20 --output /tmp/1177-standalone.json
python3 reproducers/port-promise-callback-hang-2026-10-22/thread-file-import.py \
  --tpl /path/to/upstream/tpl --output /tmp/1177-import.json
python3 reproducers/upstream-1177-verification-2026-10-23/verify.py \
  --engine /path/to/upstream/tpl --output /tmp/1177-engine.json
```

The existing standalone comparison runner records failures without failing its
own process: inspect all `passed` fields. The original import diagnostic records
exit status and output; verify `status(true)`, exit 0 and empty stderr explicitly.
The added engine runner also exits nonzero if any recorded check fails.

## Authorized closure record

The [published verification comment](https://github.com/trealla-prolog/trealla-prolog/issues/1177#issuecomment-6362440376)
reports all 148 process invocations, the exact upstream snapshot, and the focused
test boundaries. GitHub confirms the issue is closed as completed and the
published body matches the [retained comment](upstream-verification-comment.md)
exactly. See [API confirmation](upstream-closure.json) and
[screenshot](issue-1177-closed.png). No runtime upgrade was performed.
