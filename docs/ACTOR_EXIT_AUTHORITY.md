# Submitted actor termination authority

Public client ownership is checked at `actors:exit/2`, before local signalling
or a distribution hook can take over. WebSocket command authorization alone
does not protect predicates invoked by an admitted submitted goal.

The policy hook in `actor_authority.pl` uses the actor's inherited client
namespace, including delegated `ws_lineage` contexts. Siblings in one namespace
can terminate one another. A separate connection is a separate scope even
when the authenticated account is the same. A known remote route alone does
not grant termination authority: linked remote work must belong to a parent
in the caller's scope, or the caller must have node-owner authority.

Authenticated administrator namespaces retain broader authority. Their marker
is maintained by trusted connection/request setup, retained while cached HTTP
actors remain, and retired after their last actor stops. Standalone unscoped
local callers retain the unrestricted library API. Admission still restricts
which actor operations a public profile can express; ISOBASE HTTP does not
admit exit/2, including for an administrator.

The core uses a multifile hook and does not import the upper node policy.
`web_prolog.pl` and the HTTP node composition load the policy. Existing wire
ownership restrictions remain independent. Application sends and monitors
do not acquire exit authority.

`actor_authority_tests.pl` is part of `./tools/test.sh unit`. The shared
`trinity-conformance` ownership-lifecycle-0.1 pack adds public two-principal
submitted-goal checks, survival probes, authorised owner controls and monitored
socket-close cascades. See its 31 October before/after report.
