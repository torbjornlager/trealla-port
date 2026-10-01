# Cross-implementation change ledger

This ledger tracks features and fixes that may need to move between the
SWI-Prolog, Trealla Prolog, and GNU Prolog Web Prolog nodes. It distinguishes
shared Web Prolog behavior from adaptations required by one Prolog system.

The implementation in which a change was first discovered is its *origin*,
not automatically the specification. Observable behavior becomes shared only
after the implementations agree on it and the corresponding test belongs in
the conformance suite.

Status terms:

- **Implemented**: present in that implementation.
- **Candidate**: worth backporting or porting, but not yet adopted.
- **Not assessed**: applicability or implementation has not yet been checked.
- **Runtime-local**: intentionally specific to one Prolog system.
- **N/A**: not applicable to that implementation or to conformance.

## Current ledger

| Change | Origin | SWI-Prolog | Trealla | GNU Prolog | Conformance |
|---|---|---|---|---|---|
| Version-1 actor WebSocket protocol and cross-node PID routing | SWI | Implemented | Implemented | Not assessed | Partial; expand with GNU Prolog when available |
| Controlled distribution failover via `remote_drop_connection/1` | SWI | Implemented | Implemented | Not assessed | Candidate |
| Bounded listener shutdown with active-connection cleanup | SWI runtime (`http_stop_server/2`) | Implemented | Implemented via `stop_node/1-2` | Not assessed | Candidate operational test |
| Profile, sandbox, resource, authentication, and per-principal governance policies | SWI | Implemented | Implemented | Not assessed | Partial |
| IP allow/block lists and temporary rate-limit bans | SWI | Implemented | Implemented | Not assessed | Candidate |
| Resolve-check-connect source egress with a public-only default and explicit IP-range pinning | Trealla port | Candidate | Implemented | Not assessed | Needed before adoption as shared behavior |
| Explicit `trusted_proxy_ranges/1` boundary for forwarded client, scheme, and identity headers | Trealla port | Candidate | Implemented | Not assessed | Needed before adoption as shared behavior |
| Live IP strike and temporary-ban state in `/admin/runtime` | Trealla port | Candidate | Implemented | Not assessed | Candidate; admin-only behavior |
| IPv4 wildcard bind to avoid incorrect dual-stack peer addresses | Trealla port | N/A | Runtime-local workaround for BUG-013 | Not assessed | N/A |
| Pair a locally built executable with its sibling standard library in the test runner | Trealla port | N/A | Runtime-local | N/A | N/A |

## Promotion rules

1. Record a behavior here when one implementation adds or intentionally
   changes something another implementation may need.
2. Decide whether it is shared protocol semantics, shared operational policy,
   or a runtime-local adaptation.
3. For shared observable behavior, add implementation-neutral conformance
   tests before, or together with, adoption by the other nodes.
4. Preserve runtime-specific regression tests even when a shared conformance
   test exists.
5. Record intentional deviations explicitly; no implementation silently
   becomes the specification merely by shipping first.

The GNU Prolog column is deliberately **Not assessed** at present. Entries
should be updated as that port establishes its supported profiles and runtime
capabilities rather than assuming that an SWI- or Trealla-specific mechanism
can be copied unchanged.
