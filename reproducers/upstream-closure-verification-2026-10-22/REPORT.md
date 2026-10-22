# Upstream closure verification — 22 October 2026

Four reports were closed as completed with verification comments. The retests
use the separate, **unmodified** upstream v3.14.5 build at
`beed430deca9fa48adf028541ea4c3e2bd8d3641`, with its matching adjacent standard
library, on macOS arm64 (SDK 15.4, `NOSSL=1 NOFFI=1`). No local candidate patches
were applied and neither installed runtimes nor live nodes were changed.

| Issue | Verification | Result |
|---|---|---|
| [#1172](https://github.com/trealla-prolog/trealla-prolog/issues/1172) HTTP timeout | Previously saved original reproducer, three trials; upstream stream/task timeout suites | Read-timeout errors at 0.203, 0.202, 0.203 s for a 0.2 s setting; all 21 and 9 expected output lines match; exit 0 |
| [#1173](https://github.com/trealla-prolog/trealla-prolog/issues/1173) Module-map race | Original standalone overlapping module-creation/list-worker reproducer, fresh processes | 100/100 pass; no signals, failures or watchdog timeouts |
| [#1174](https://github.com/trealla-prolog/trealla-prolog/issues/1174) Output capture | Original standalone message-controlled capture interleaving | 20/20 return exactly `actual(beta,alphaomega)`, exit 0, empty stderr |
| [#1175](https://github.com/trealla-prolog/trealla-prolog/issues/1175) Assertion expansion | Original standalone reproducer plus controls and bounded assertion checks | 20/20 original, 5/5 controls, 24/24 assertion checks pass; no parser diagnostics or watchdog timeouts |

The module-map worker still performs 200,000 list operations while the main
thread creates 300 modules. Output-capture interleaving still uses messages
rather than sleeps. No reproducer assertions or runtime behavior were changed
for this verification. Reproducer outputs and return codes were checked; process
success alone was not counted as correctness. The assertion checks retain
quoting, variable sharing, clause-reference, cut and error-recovery assertions.

## Evidence

- [Build provenance and unchanged installed executable hash](provenance.json).
- [Earlier HTTP timeout verification](../port-http-timeout-upstream-2026-10-22/engine-tests.json).
- [Module-map stress results](1173-module-map.json).
- [Output-capture results](1174-output-capture.json).
- [Assertion-expansion results and controls](1175-assert-expansion.json).
- [GitHub states and published verification comments](github-closures.json).

All four states were read back from GitHub and confirmed `closed`, with
`state_reason = completed`. Published comments:

- [#1172 verification](https://github.com/trealla-prolog/trealla-prolog/issues/1172#issuecomment-6336735833).
- [#1173 verification](https://github.com/trealla-prolog/trealla-prolog/issues/1173#issuecomment-6336769274).
- [#1174 verification](https://github.com/trealla-prolog/trealla-prolog/issues/1174#issuecomment-6336778730).
- [#1175 verification](https://github.com/trealla-prolog/trealla-prolog/issues/1175#issuecomment-6336786313).

## Boundaries

[#1176](https://github.com/trealla-prolog/trealla-prolog/issues/1176), the file-path
module-import regression, was read back as **open** and was not changed. Passing
results for that issue still require its separate candidate engine patch. Other
thread/module-creation and intermittent lifecycle diagnostics remain separate;
closing these four specific reproductions does not approve an engine upgrade or
claim all threading/loader behavior is correct. TLS, WASM and other operating
systems were not retested.

The upstream checkout was clean both before and after this retest. The installed
v3.13.10 executable still has SHA256
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
