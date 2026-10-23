Verified fixed on a separate, unmodified Trealla v3.14.8 build at 42ebc2127e3f900036c6bcb54cfc11bec4762eb7, using its matching standard library. This includes b61ec3df and the subsequent asserted-clause preservation change 0f503394. Thank you!

- Original actor callback/startup case: 5/5 passes, including the expected callback answer and termination notification.
- Original standalone file-path import and module-name control: 5/5 each, preserving `[kept]`.
- Full, selective, reexport and native-thread import variants: 5/5 each.
- Framework imports of actors.pl and rpc.pl: 5/5 each, preserving actor and promise tables; complete promise correctness group passes.
- Upstream use_module_state regression: 5/5 exact-output passes. The five existing reconsult_module, make_module_state, make_same_second, make_failed_load and runtime_consult_base regressions also pass.

Importing an already loaded file preserves the old version and asserted state; explicit consult reloads the changed version while retaining the asserted clauses, matching the upstream expected output. All recorded focused runs exit successfully with empty stderr.

The native-thread import check pre-creates its destination module, so this does not verify #1177; that remains a separate follow-up. These are focused macOS arm64 checks, not a full engine/application, interoperability, TLS or WASM certification. Our installed runtime remains unchanged.

Reproducible results, logs, fixtures and exact provenance: https://github.com/torbjornlager/trealla-port/tree/64d99f201c1ac0ac909aef759e8f54f18d6c981f/reproducers/upstream-1176-verification-2026-10-23

Closing this report as fixed on the verified upstream snapshot.
