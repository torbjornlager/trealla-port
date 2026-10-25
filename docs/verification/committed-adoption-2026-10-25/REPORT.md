# Committed Trealla adoption checkpoint — 25 October 2026

Selected commit: `e7c51dc101cd8002dea9548f8154fc4d2bf6707d`.
Cyclic-answer guards, actor write/1 and private-source shadowing were committed
separately, with their tests and investigation records. The full unit driver
passes on the unchanged verified v3.14.10 engine with its matching libraries:
[unit.log](unit.log), [checks.json](checks.json).

n5 now starts from an exact detached checkout of this commit. Startup rejects
HEAD changes and modified or untracked runtime inputs. The preflight and public
ping-pong checks require plain `ping_pong`, three exchanges and both finishing
messages. It also passes the existing 29 native interoperability smoke checks
and the post-restart text checks, as recorded in the demonstrator's
[complete adoption record](../../../../trinity-demonstrator/docs/verification/committed-adoption-2026-10-25/REPORT.md).

This does not patch or reinstall Trealla. The existing character-list reader,
node configuration, frontend and auxiliary listener are retained. Previous
source snapshots/launchers remain available. Cyclic-exception copying and
supplementary-character JSON escapes remain separate diagnostics; neither is
claimed fixed or folded into passing conformance totals. Results-only commits
after this selection do not move the deployed checkout.
