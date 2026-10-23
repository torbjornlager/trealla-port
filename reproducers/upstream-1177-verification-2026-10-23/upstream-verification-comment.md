Verified fixed on a separate, unmodified Trealla v3.14.8 build at 42ebc2127e3f900036c6bcb54cfc11bec4762eb7, with its matching standard library. This contains the two null-parser guards from 3d0f2ebb and the regression-test relocation from 3b2c9c0c. Thank you!

- Both formerly crashing new-module paths (`load_text/2` and internal `'$module'/1` inside native threads): 20/20 fresh-process passes each.
- Existing-module and command-query controls, both paths: 20/20 each; command informational messages remain unchanged.
- Original thread-file-import diagnostic: 3/3 passes with exactly `status(true)`.
- Upstream `tests/misc/thread_module_creation.pl`: 20/20 exact-output passes.
- Existing temporary_module, module_qualifier_errors, meta_goal_module, retract_module_scope and op_module_visibility regressions: all five exact-output passes.

All 148 process invocations exit 0 with empty stderr and no watchdog timeouts. The standalone checks verify successful child termination and actual predicate contents from child and parent. Variable module qualifiers prevent compilation from pre-creating the supposedly new destination. The engine regressions require exact expected stdout as well as successful process exit.

Qualifications: these are focused macOS arm64 checks of the null-parser defect, not an audit of competing module creators or a full engine/application, live interoperability, TLS, WASM or other-platform certification. This does not approve an installed-runtime upgrade; our installed runtime and production code remain unchanged. The original v3.14.5 failure evidence and separate candidate results are retained.

Closing this report as fixed on the verified upstream snapshot.
