# Private/shared predicate shadowing on n5 — 2026-10-25

The reported `permission_error(modify,static_procedure,ping_pong)` is reproduced
and repaired. The unchanged `06 ping-pong.pl` now loads through the actual n5
example drawer; plain `ping_pong.` returns `true`, prints the three alternating
exchanges and prints both finishing messages. n3 was not restarted or changed.

## Cause and bounded repair

The node bootstrap consults the benchmark shared DB in the host and also loads
shared clauses into each private actor namespace. The example deliberately
shadows shared `ping_pong/0` and `ping/2`. The public sandbox converts supplied
text into clause-list options. Terms on this path can retain a lookup of the
same-named host predicate. Unqualified loader operations consequently reached
the static host definition, even though their intended target was private.

A one-clause `ping_pong :- true.` public source reproduces the load error. Direct
text loading without the sandbox's clause-list conversion did not reproduce it.
The initial explicit-private `retractall/1` repair removed the load error, but
end-to-end testing exposed related dispatch/copy lookups: a plain call could run
the host benchmark, and copied workers could select its nonprinting code.

The complete adapter repair is limited to the generated private-source helpers:

- Qualify shared-clause replacement with the private actor module.
- For recorded source predicates, rebuild the dispatched goal with `=../2` and
  call it in that module. This discards the retained lookup while preserving
  argument/variable sharing. Existing special built-in/control routing and
  explicitly qualified goals retain their earlier paths.
- Qualify `clause/2` when materialising private `src_predicates/1` copies.
- Qualify source-clause retirement during namespace cleanup.

No engine, protocol, example program or sandbox admission rule changed. Host
static definitions remain static and unchanged; other actors retain their own
shared clauses. The source-copy and dispatch tests exercise actual definitions,
not permission-error suppression or a fallback to the host predicate.

## Regression and public verification

`shared_shadow_tests.pl` is registered in the ordinary unit runner. It covers
blacklist/whitelist source admission, private zero/unary definitions, parsed
public-style entries in blacklist mode, exact copied private clauses, host
static-definition preservation and an independent actor's shared view. It
consumes its own monitor notifications and uses bounded waits. Whitelist public
query admission is not broadened or claimed by the parsed-query check.

[checks.json](checks.json) records the failing before control and passing repaired
regression, source-declaration, concurrent source-capture and synchronous-toplevel
suites. [additional-checks.json](additional-checks.json) records unchanged complete
isolation and sandbox groups passing. [interop-checks.json](interop-checks.json)
records all 29 public interoperability smoke checks passing after deployment.

The exact unchanged ping-pong source passes temporary-port and public n5 checks,
with browser I/O negotiation/acknowledgements and both finish messages required:
[preflight](preflight-events.json), [live](live-events.json). The final check uses
plain `ping_pong`, rather than replacing the entry with explicit worker spawns.
[Actual UI observation](ui-check.json) confirms drawer load and terminal output.
The program's existing reply/output ordering remains unchanged.

## Deployment and preserved state

n5 now runs PID **11084**, advertised at <http://localhost:3060/portal>, with the
same Trealla v3.14.10 binary, matching libraries and node settings. The immutable
final source snapshot and launcher are under:

```
~/.local/share/trinity-local-nodes/shared-shadow-dispatch-2026-10-25/
```

The normal n5 launcher selects it. The prior first-stage loader-only snapshot
(PID 10267 while it ran) and its rollback launcher remain under
`shared-shadow-2026-10-25`; the pre-batch snapshot (former PID 8862) remains under
`portable-text-live-2026-10-25`. No rollback deletes those snapshots. The final
launcher contains both loader and dispatch/copy repairs, as confirmed by the
[source hash record](source-record.json).

n3 PID 8855, frontend PID 91509 and auxiliary listener PID 97669 preserve their
process identities/start times. Installed engines and the dependency pin are
unchanged. [restart.json](restart.json) records the final restart and engine hash.
No commit, push or upstream report was submitted. Temporary development probes
were removed; the reproducible failing control, focused tests and final evidence
are retained.
