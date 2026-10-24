# Trealla promise timeout callback context — 24 October 2026

## Repair

Source-less actor sessions have an execution/bootstrap module but no supplied
source-module registration. yield/3 previously used the outgoing-source resolver
for callbacks, falling back to user. In the public node fixture user does not
import !/2; ordinary queries execute where the actor imports are present. Thus
on_timeout((Self ! seen, Answer=waiting)) raised an undefined !/2 error while
unification-only callbacks worked. Importing the actor API into user in a test
process masks this defect and is not representative of the public node.

rpc.pl now resolves callback context independently: explicit option qualification
wins, then the actor source module, then its execution/bootstrap module, then
the existing user fallback for trusted non-actor callers. Remote source loading
continues to use its original resolver. Public sandbox preparation routes yield/3
through a small guarded adapter that validates options, checks and prepares
callbacks under the caller's profile/policy, and passes the execution context
explicitly. Computed options follow the same path. Preparation commits before
yield so it introduces no extra query alternative. Its rewrite clause follows
the variable-goal guard and cannot instantiate an unknown meta-goal.

Copied private source converts the internal guarded-yield form back to public
yield before reusing it in another actor, matching the existing synchronous
wrapper/source-copy convention. The helper name is reserved against application
replacement. This adds no public predicate or protocol. Callback invocation
remains once, its variables stay shared, and callback failure/exception or local
wait timeout leaves the promise available for retry.

The runtime README and shared language manual describe the execution context.
Book examples, installed executables/libraries, launchers and n3/n5 are unchanged.

## Verification

Exact separate unmodified Trealla v3.14.10 and matching libraries were used;
no engine rebuild, installation or live-node restart occurred.

- New callback regressions pass: source-less sending; shared callback variables;
  one callback and unrelated-message preservation; timeout then collection;
  private helpers; copied guarded-yield helper source; explicit option/callback
  qualification; permitted callbacks; computed forbidden callbacks rejected
  before claim; and uninstantiated variable-goal rewriting.
- Existing promise correctness, client options, promise lifecycle, ownership,
  synchronous waits, source isolation and profile groups pass.
- A minimal original-source negative probe (without actor imports into user)
  reproduces undefined !/2. It uses a disposable source copy; current sources
  and installed engines are untouched by that control.
- Final public conformance passes all **24/24 PY** selections and **8/8 HC**
  selections unchanged in all four caller/peer directions. Three PYD controls
  complete in all directions. Twelve reports validate; all 13 conformance-runner
  regressions pass. See the sibling conformance repository's
  `reports/2026-10-24-promise-callback-context/COVERAGE.md`.
- Final production-file hashes match those tested in conformance. Selected
  engines/libraries, native SWI sources and n3/n5 identities are preserved, and
  all disposable nodes stopped. Installed alias/executable hashes still match
  the preceding preservation record (`preservation.json`).

No existing runtime assertion or receive timeout was weakened. The new test is
registered in tools/test.sh. The focused runner uses the existing 30-second
outer watchdog and records every exit, including failures.

## Separate intermittent sandbox cascade timeout

The broader sandbox group is not uniformly green: t145_cascade_timeout remains
in results.json and sandbox.log. Its independent original/repaired comparison,
fixed-batch results and unresolved cause are recorded in the separate
[cascade-timeout investigation](../sandbox-cascade-timeout-2026-10-24/REPORT.md).
Those findings are not callback conformance failures or part of this runtime
repair. No lifecycle or test-timeout change is included.

## Development evidence

The first adapter left query choice points; unchanged conformance assertions
caught them. Adding the preparation cut fixes that. Another development check
caught a misplaced rewrite clause before the variable-goal guard; it was moved
and a targeted regression added. Neither required weakening a test. Initial
and intermediate conformance records remain in development-conformance/.

An initial negative fixture imported the actor API and therefore masked the
callback-context defect; its expectation failure is retained in the initial
runner logs. The final minimal negative probe avoids that import and reproduces
the intended error. The final expanded callback test uses parsed public-style
goals and explicitly tests private/copy context. Only production changes are
rpc.pl, sandbox_policy.pl and one source-copy clause in isolation.pl.
