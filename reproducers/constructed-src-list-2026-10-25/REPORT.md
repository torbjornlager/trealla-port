# Constructed src_list admission failure — 25 October 2026

**Follow-up:** the authorized bounded repair and verification are now recorded
in [REPAIR.md](REPAIR.md), with results in [COVERAGE.md](COVERAGE.md). The account
below preserves the initial investigation before that repair.

Investigation only: no runtime repair applied. Installed runtimes and n3/n5
are unchanged. Probes use exact unmodified Trealla v3.14.10 and archived root
Prolog files from Trealla-port commit `d0993e422be4fad74f957c5bcd12a400475fb6dc`.
Pending Boolean/URI edits are excluded. The public fixture is disposable,
loopback-only, ACTOR/blacklist/auth(open), and was stopped after the probes.

## Confirmed cause

Static sandbox admission traverses a query before executing earlier goals.
For `(Clauses=[p(1)],spawn(p(_),_,[src_list(Clauses)]))`, the source argument
is still a variable when `sandbox_policy:check_nested_spawn/6` calls
`profile_policy:profile_check_spawn_options/2`. Its source-content checker
immediately executes `must_be(list,Terms)` and raises an instantiation error.
The query never reaches its list construction, child creation or loader.
Even an outer `catch/3` inside the submitted query cannot catch this admission
error because the query has not started executing.

This is a Web Prolog adapter admission-order defect. It is not evidence of a
Trealla engine bug, numeric-list conversion or lost source-variable sharing.

## Controls

The [direct preparation probes](admission-probe.pl) and
[results](admission-results.json) show:

- Profile checking with an unbound source list raises the exact observed error.
- Admission of an earlier-assignment/inline-source-option query raises it too.
- A literal source list passes admission.
- Runtime preparation with an already constructed source list passes.
- Prepared clauses can contain numeric lists and repeated variables; the
  preparation control leaves the caller's variable unbound.
- A source list still unbound at actual runtime preparation correctly errors.

The [public probes](public-probe.py) and [results](public-results.json) confirm:

- Unchanged TXT-014 returns the instantiation error.
- Moving only option-list construction into an earlier goal makes the exact
  numeric-list, character-list, sharing and termination assertions succeed.
  This uses the existing blacklist path that defers an opaque options variable
  to the runtime wrapper; it is a diagnostic control, not a proposed workaround
  to bake into the conformance test.
- A literal source-list child starts and reports normal termination.
- The outer-catch version is rejected before query execution.
- A truly unresolved list at runtime gives a catchable spawn-option error,
  without binding the source variable or creating a child pid.

Whitelist runtime execution and HTTP admission have not been probed in this
investigation. No broader portability claim is inferred from these controls.

## Smallest proposed repair

Distinguish static admission from execution-time source validation. Retain
checks that can safely be performed from known option/profile structure, but
defer source-content and source-dependent child-goal checks when the list is
constructed at runtime. Reuse the existing `sandbox_spawn/7` path: it validates
options, resolves source context, prepares/checks supplied clauses and the child
goal, then calls `actors:spawn/3`. Reject unresolved or malformed lists there
before creating the child. Admission must not bind caller variables or mark
unknown child predicates permanently safe. Preserve the whitelist restriction
on completely opaque options and test source-dependent admission separately.

Focused regression coverage should include unchanged TXT-014, literal and
runtime-bound lists, numeric data and repeated variables, catchable bad lists,
forbidden supplied bodies/child goals, lower-profile restrictions, and both
sandbox policies. Keep the source loader, JSON codec, actor copying and general
spawn lifecycle unchanged. No upstream engine report is indicated by this trace.

Native SWI's existing deferred nested-source admission is a useful implementation
reference; its original TXT-014 result already passes. Its static pre-check
defers non-ground source-like options to the runtime guarded spawn path.

[Preservation checks](preservation.json) compare against the preceding recorded
source/binary/library/pin/live-node snapshot and all pass. New files are only
probes, results and this investigation record.
