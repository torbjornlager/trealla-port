# Native SWI to Trealla: public synchronous toplevel follow-up

Assessed on 2026-10-21 through the demonstrator's public WebSocket API.
This is a port interoperability issue, not an established Trealla engine bug.
The installed engines were not modified. Local N5 was restarted with its
existing configuration to load the current port code.

## Passing paths

- Local synchronous calls in native SWI and native Trealla: both call arities,
  both next arities, paging, variable independence, failure/exception answers,
  timeout callback/retry, preservation of ordinary asynchronous replies.
- The same tutorial paging program in the actual demonstrator UI on native SWI,
  native Trealla, SWI-WASM main-thread mode and SWI-WASM Worker mode.
- Native Trealla to SWI: the same five public query groups as the local checks.
- Both SWI-WASM modes to SWI: actual UI call/next with two pages and explicit halt.

## Outgoing query qualification — repaired in native SWI

Native SWI now strips the outer caller qualification from remote `$call`
goals before serializing the whole envelope. Nested qualifications, original
options and shared variables are preserved; local execution is unchanged.
Fresh-process public WebSocket checks passed against both SWI and Trealla:
paging, default templates, failure/exception answers, timeout callback/retry,
asynchronous reply preservation and explicit goal/template variable sharing
(12 checks in total). The broader transport problems below remain separate.

The following records the pre-repair failure for comparison.

Use a fresh native SWI source node with ACTOR profile, blacklist sandbox and an
unmodified current Trealla peer. Creating a fresh disposable SWI node avoids an
old error already waiting on its cached transport. In that SWI node's terminal:

```prolog
toplevel_spawn(P, [session(true),node('http://localhost:3060')]),
toplevel_call_synch(P, member(X,[a,b,c]), First,
                    [template(X),limit(2),timeout(2)]),
toplevel_next_synch(P, Last, [timeout(2)]),
toplevel_halt(P).
```

The peer address above was a local UI proxy to Trealla on port 3062. Replace it
with the actual Trealla node URI when testing elsewhere. Expected: `First` is
`success(P,[a,b],true)` and `Last` is `success(P,[c],false)`.

A fresh disposable SWI source node instead returned:

```prolog
First = error(P,error(existence_error(module,actor_2741903526),(:)/2))
```

`Last` was unbound after its wait timed out. The quoted actor module belonged to
the SWI caller, not the peer. The transmitted `$call` retains this outer module
qualification; the Trealla receiver consequently tries to enter a module that
is absent. A repair should normalize the caller qualification at the remote
query boundary, preserving local query/source context, nested qualifications,
explicit templates and goal/template variable sharing. This is distinct from
the local sandbox default-template repair made in this batch.

## Independent uncorrelated-error problem — repaired for negotiated peers

Native SWI and Trealla now negotiate `web-prolog-sync-spawn-v1`. Both clients
send fresh spawn request IDs and require a matching response on these
connections. Untagged errors are diagnostics, not spawn failures. The original
serialized fallback remains for older peers; without IDs their errors remain
ambiguous. Connection loss retains its previous behavior. Regression tests
cover both paths, and live checks pass in all four SWI/Trealla client/peer
combinations, including reuse after unrelated errors and genuine startup errors.

The following records the historical failure; receiver-side lineage support is
now implemented as described below.

Close the source client connection and try another remote creation through the
same source node's cached connection. A later creation can fail with a previous
transport command's error, for example:

```prolog
error(remote_spawn_failed(
  "error(domain_error(web_prolog_command,lineage_close),profile_policy:profile_check_command/2)"),_)
```

A fresh-source check also observed an error about access to an already retired
remote pid being reported as a later spawn failure.

At the time of that assessment, Trealla's command catalog/receiver had no
`lineage_close` handler. Native SWI
sends that command when a delegated lineage is reclaimed. Before this repair,
it also forwarded unreferenced peer errors to the spawn queue; the spawn waiter
accepted these as legacy spawn errors even when its own request carried an ID.
The error can therefore outlive the command that caused it and poison a later
creation. Suppressing `lineage_close` alone would not resolve all such errors.

## Repair boundaries

1. Completed: normalize outgoing toplevel caller qualification without changing
   local execution, nested explicit qualifications or variable sharing.
2. Completed for negotiated peers: isolate spawn replies using the explicit
   combined capability; preserve legacy startup errors on fallback connections.
   Toplevel correlation alone is not treated as a spawn-correlation guarantee.
3. Completed for the receiving node: validated authenticated lineage contexts,
   local actor/registration/promise cleanup, and rejection after closure.
   `receiver_lineage_tests.pl` and `swi_lineage_compat.pl` cover this boundary.
   Forwarding delegated ownership or cleanup to further remote nodes remains
   separate; accepting a close command does not imply network-wide cancellation.

The original assessment changed no transport behavior. The native SWI
qualification repair and SWI/Trealla spawn-correlation repair did not change
lineage behavior. The subsequent receiver-side repair adds the bounded support
described in the runtime README.
Local synchronous calls and the tutorial are usable independently of these
remaining interoperability issues. The existing upstream module-table crash
report (#1173) concerns a separate engine defect.
