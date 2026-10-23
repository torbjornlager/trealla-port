# Verification of Trealla #1176 on unmodified upstream

23 October 2026. Tested the separate **unmodified v3.14.8** build at
`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`, with its matching adjacent library.
It contains upstream `b61ec3df` (ordinary imports do not reconsult a module file)
and the subsequent `0f503394` (explicit reload preserves asserted dynamic clauses).
No local candidate patch was applied. The engine checkout remains clean.

The #1178 closure record was committed and pushed first as
[`44a7cc9`](https://github.com/torbjornlager/trealla-port/commit/44a7cc92b58f3050fa809ce4f542019d63071e30).
The installed engine and production runtime code are unchanged.

## Results

| Check | Unmodified upstream result |
|---|---|
| Original actor callback/startup test | 5/5 pass |
| Original standalone file-path import/state-loss reproducer | 5/5 preserve `[kept]` |
| Existing-module-name import control | 5/5 preserve `[kept]` |
| Full, selective, reexport and native-thread import variants | Each 5/5 pass; asserted state retained and imported predicate callable |
| Framework import of `actors.pl` by path | 5/5 preserve the actor and promise tables |
| Framework import of `rpc.pl` by path | 5/5 preserve the actor and promise tables |
| Complete Web Prolog promise correctness group | Pass |
| Upstream `use_module_state` engine regression | 5/5 exact-output passes |
| Existing `reconsult_module`, `make_module_state`, `make_same_second`, `make_failed_load`, `runtime_consult_base` | All five exact-output passes |

The original three comparison cases also pass 5/5 each on pinned v3.13.10,
used as a positive control. That comparison has 30 invocations total; the focused
upstream runner has 41 invocations. Every recorded invocation passes; captured
stderr is empty. Original comparison cases have a three-second process watchdog;
focused checks have a 65-second external watchdog, with the engine shell tests'
internal 60-second watchdogs retained.

The original callback test explicitly asserts the `waiting` callback answer and
receives the child termination notification with reason `true`; timeout fails
the test. The table probes compare their before/after snapshots exactly and
require nonempty actor and promise tables. Import variants require both
`Rows == [kept]` and a successful call through the importing module. Engine
regressions require exit 0 and stdout exactly equal to the upstream `.expected`
file; completion markers alone are not enough for those tests.

## Import versus explicit reload

The upstream regression confirms that importing an already loaded file after
changing that file does not reload its existing module: asserted state and
`version(1)` remain. Explicit `consult/1` does reload it to `version(2)` while
retaining `[kept]`. This matches the tested upstream expected output and its
additional asserted-clause preservation change. It is not a claim that the
upstream implementation is identical to our earlier candidate patch.

The added native-thread variant explicitly pre-creates its destination module,
matching the original import regression. It does not separately verify #1177's
new-module creation behavior, and no closure of #1177 is inferred.

## Conclusion and boundaries

The #1176 state-loss defect and its demonstrated callback/startup symptom are
not reproduced in these focused checks on the stated unmodified upstream
snapshot. This supports posting verification and closing #1176, subject to user
authorization. **No upstream comment or closure was performed in this batch.**
#1176 and #1177 remain open pending their respective follow-up actions.

No upgrade of the installed runtime is proposed by these results. Full engine
suites, broad Web Prolog groups, live cross-runtime interoperability, TLS, WASM
and other operating systems were not rerun here. Earlier failing v3.14.5 and
candidate results are retained in their original investigation directories.

## Artifacts

- [Original reproducer/callback comparison](original-comparison.json), with its
  [console log](original-comparison.log).
- [Focused assertions and engine regressions](focused-checks.json), with their
  [console log](focused-checks.log).
- [Import-variant fixture](import-variants.pl).
- [Focused runner](verify.py).
- [Exact revision, source and engine hashes](provenance.json).

## Reproduction

Run from the trealla-port root:

```sh
python3 reproducers/port-promise-callback-hang-2026-10-22/run.py \
  --pinned .build/trealla-v3.13.10/tpl \
  --upstream /path/to/unmodified-upstream/tpl --trials 5 \
  --output /tmp/1176-original.json

python3 reproducers/upstream-1176-verification-2026-10-23/verify.py \
  --engine /path/to/unmodified-upstream/tpl \
  --output /tmp/1176-focused.json
```

The focused runner creates a temporary executable `timeout` shim from the
already retained test shim in
`reproducers/unlock-all-independent-verification-2026-10-23/timeout-shim.py`,
so macOS need not install a system utility. No repository runner or engine
source is modified. All results, including failures if any, are retained;
these diagnostic runners are evaluated by their result records rather than
assuming their own successful process exit means every test passed.

The tested executable is
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl`.
The installed v3.13.10 binary retains SHA256
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
