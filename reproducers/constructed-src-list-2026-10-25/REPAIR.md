# Constructed src_list admission repair — 25 October 2026

The bounded adapter repair is implemented and verified. Installed runtimes,
n3/n5, the SWI dependency pin and the separate engine builds remain unchanged.
This is not a deployment or an upstream engine patch. Pending Boolean/URI
runtime work is preserved and excluded from the tested source snapshot.

## Behaviour

Static nested-spawn admission now inspects a copy of the child goal/options.
For a non-ground `src_list(Terms)`, it checks source-option profile eligibility
using an empty inspection-only placeholder and defers source-content checks.
The original terms, including their sharing with the parent query, are retained
in the guarded runtime call. Earlier goals can therefore construct the source
before execution reaches `spawn/3`; admission does not execute those goals.

In whitelist mode, membership of child predicates from unknown source cannot
yet be determined. The early scan still rejects known forbidden operations;
the runtime `sandbox_spawn/7` retains the **original whitelist policy**, checks
actual options, source and child goal, and only then calls `actors:spawn/3`.
Tests show that a predicate absent from the actual source is rejected under
that policy. The early scan does not grant a permanent whitelist exemption.
Completely opaque option lists retain their existing whitelist rejection.

The runtime validator remains strict: unresolved or malformed source lists,
forbidden source bodies and forbidden child goals fail before actor creation.
Known profile restrictions remain enforced. Ground-source behaviour and other
source options are unchanged. The loader, JSON handling, actor copying and
general lifecycle code are not modified. Blacklist mode remains a prototype
policy, not a complete security boundary.

The former admission error for a source variable becomes a runtime check:
valid constructed lists execute; a list still unresolved when spawning raises
a catchable error at that point. Existing numeric data, character lists and
within-clause sharing are preserved; source data need not be ground.

## Changes

- `sandbox_policy.pl`: copied, deferred nested-source admission and guarded
  source-dependent whitelist checking.
- `src_list_admission_tests.pl`: focused regressions in both sandbox modes,
  runtime construction, partial lists, constructed clauses, numeric/character
  data, variable sharing, bad lists, unsafe source/child goals, unknown whitelist
  predicates and lower-profile/opaque-option restrictions.
- `tools/test.sh`: include that focused group in the unit tier.
- `README.md`: document the admission/runtime distinction and policy limits.

[`repair-only.patch`](repair-only.patch) contains exactly this batch, including
README and runner additions relative to their pre-batch working copies. It
excludes their unrelated pending edits. Its input identities describe the
pre-publication working copies used for verification.

## Verification

The new focused test file fails with the original sandbox policy at the
instantiation error, and passes with the repair on **unmodified Trealla
v3.14.10** and its matching library. Existing sandbox, profile, isolation and
nonbinding-supervisor-admission groups all pass. Commands, output, exit status
and durations are in [the unit results](repair-unit-results.json).

Unchanged shared public-interface packs pass **50/50** assertions across
disposable SWI and Trealla nodes. The unchanged experimental TXT-014 passes
with both Trealla engine selections. See [the matrix](COVERAGE.md):

- Unmodified v3.14.10 plus this adapter repair: **21/26** experimental cases pass.
- Separate JSON-library candidate plus this repair: **25/26** pass.
- SWI caller → Trealla peer remains **4/26**, with unchanged native readers.

The four supplementary-character failures in the first configuration are the
separate JSON-library issue [Trealla #1181](https://github.com/trealla-prolog/trealla-prolog/issues/1181).
They pass in the second configuration. TXT-023 still fails because its default
SWI peer reads supplied double-quoted text as native strings. These are
experimental differences, not required-profile failures. No draft semantics
or manifest assertions were changed. Historical reports remain intact.

Report schema/accounting validation passes for all 12 new raw conformance
reports. Shell syntax and source whitespace checks pass. These are focused
regressions and selected shared packs, not a claim that the full engine,
all runtime tiers or browser/GNU suites were rerun.

## Provenance and reproduction

The primary engine is the unchanged separate v3.14.10 acceptance build; its
hash is recorded in [repair provenance](repair-provenance.json). The optional
combined run uses the already verified separate JSON candidate, without editing
or installing it. A disposable source snapshot starts from committed runtime
`d0993e422be4fad74f957c5bcd12a400475fb6dc` and overlays only `sandbox_policy.pl`
and the new test file. [Snapshot identity](candidate-source.json) records its
temporary local Git revision, which is a fixture identity, not a published
runtime revision. Pending Boolean/URI source changes are excluded.

Run the focused group with a selected source checkout and separate executable:

```sh
TPL_LIBRARY_PATH=/path/to/separate/engine/library \
  /path/to/separate/engine/tpl -g \
  "consult(src_list_admission_tests),(catch(src_list_admission_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"
```

The [shared-pack fixture driver](conformance-check.py) records its exact archived
sources, commands, manifest/runner hashes and engine hashes in
[`shared-local/provenance.json`](shared-local/provenance.json). Each experimental
run likewise has a provenance file. The [validation summary](repair-validation.json)
keeps required/supporting results separate from experimental findings.

[Preservation checks](repair-preservation.json) pass for installed targets and
binary hashes, engine/library inputs, the native SWI sources, the dependency
pin, unrelated working files and original n3/n5 process identities. The pending
README and test-runner text is retained. All owned disposable nodes were stopped.
