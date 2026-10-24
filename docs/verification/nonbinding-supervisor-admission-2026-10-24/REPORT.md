# Trealla nonbinding supervisor admission — 24 October 2026

## Repair

The profile and sandbox checkers previously duplicated a traversal that unified
an unknown child with child(_,Options), created a start option through memberchk,
and bound its unknown start to server(_,_). This changed application variables
before a receive or constructor ran.

Both now use supervisor_admission.pl, which inspects only known structure and
leaves unknown specifications, options, entries, starts and partial tails opaque.
It returns the original goal variables rather than copies, preserving sharing and
first-start precedence. Whitelist admission still rejects opaque meta goals;
blacklist keeps its existing deferred admission behavior.

Prepared supervisor constructors and additions use sandbox_supervisor_call/5 to
recheck the eventual child goals under the same profile, mode and source context
before dispatch. Forbidden runtime-supplied starts cannot become unchecked merely
because admission did not yet know their values. The helper is reserved against
user redefinition. Source copying strips it to the original public constructor,
so copied helpers are prepared in their receiving context. Existing child-spec
validation, error forms and lifecycle policies remain in the supervisor API.
No engine patch, public API or protocol change was made. Blacklist mode remains
a prototype policy, not a complete security boundary.

## Verification

Eight targeted groups pass in their final applicable runs:

| Group | Evidence |
| --- | --- |
| New nonbinding/variable-sharing/opaque/safety/private-source/copied-helper regressions | nonbinding-final.log |
| Existing child-specification validation | child-specs.log |
| Supervisor source selection and variable receive | supervisor-source.log |
| All 20 supervisor behaviour cases | supervisor-behaviour-final.log |
| Remote supervisor receiver and policy regressions | remote-supervisor-policy.log |
| Profile group | profiles.log |
| Sandbox/source-policy group | sandbox.log |
| Isolation group | isolation.log |

regressions.json records the initial eight-group run. One test failed because it
expected sandbox preparation to return a constructor unchanged. That assertion
now explicitly requires the runtime guard; its profile rejection and forbidden
start assertions remain intact. regressions-final.json records the final new-test
and full behaviour-group reruns. Other groups were not retried to obtain passes.
All receive assertions/timeouts in existing behaviour cases remain unchanged.

A temporary git archive of the pre-repair source was tested with the same separate
v3.14.10 executable. pre-repair-control.log records the unwanted
child(_,[start(server(_,_))|_]) binding and exit 1 from the nonbinding assertion;
pre-repair-control.json identifies the exact source/command. That archive was
removed after the check. The repaired regression leaves those variables unbound.

During development of an additional new copied-helper fixture, copied receive
options produced an unrelated malformed source observation. It is qualified in
fixture-notes.md and was not repaired. The final copying regression focuses on
the constructor guard and uses parent-side bounded waits. Existing suites and
shared conformance assertions were not weakened to accommodate that observation.

## Shared conformance

The identical committed manifests were rerun on disposable native SWI and Trealla:

- Child specifications: Trealla **6/6**, SWI **1/6**, combined **7/12**. SWI's five
  runtime-bound initial-list admission failures remain required failures.
- Admission probes: **20 complete observations**, no diagnostic errors/timeouts.
  Trealla AP-006/008 now report PatternState=unbound and Matched=yes; the valid
  request adds its child and the invalid request catches missing_start_option.
  SWI's opaque-initial-list and literal-source ordering differences remain.
- Local creation-option runtime validation: **12/12**, preserving the separate
  literal-admission qualifications from the original pack.

New reports/matrices are in the sibling trinity-conformance repository under
reports/2026-10-24-trealla-nonbinding-child-specs,
reports/2026-10-24-trealla-nonbinding-admission-probes and
reports/2026-10-24-trealla-nonbinding-creation-validation. Historical matrices and
all manifests remain unchanged. All schema/accounting checks and 26 conformance
runner regressions pass. This is a finite checkpoint, not a stress test or a full
unit/interop/browser certification.

## Provenance and preservation

The engine is the separate exact unmodified Trealla v3.14.10 build
4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294 with its adjacent matching library;
regressions.json records the binary SHA and commands. patch-inputs.json identifies
base revision and final changed-file hashes. New code was uncommitted while tested;
those hashes and the eventual containing commit identify the repair.

Conformance fixtures use the existing separate SWI candidate and exact native
source dependency pin f316e65503bff863dfbd2e182f7487988c91480c. Their provenance
records both engine hashes, source status and all executed input hashes, including
new Trealla files. All patched .pl source hashes match the final fixtures' snapshots.
All fixture preservation checks are true, and both nodes stopped in each run.
Installed executable targets/hashes match the earlier preservation record; live
n3/n5 identities remain unchanged. No installation, launcher, restart, reload or
repository-access change occurred. Native SWI and browser code are unchanged.

Remaining work includes SWI's separate admission restrictions and source-order
finding, plus the unrelated copying observation. General lifecycle, remote
cancellation, whitelist expansion and full security certification are out of scope.
