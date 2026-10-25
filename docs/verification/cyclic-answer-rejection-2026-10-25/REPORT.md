# Early computed-answer cycle rejection — Trealla

25 October 2026. Working-source candidate over
`9b7c9402b8653d79d34f86f2482c758cdaee71d7`, with the separate unmodified
Trealla v3.14.10 engine and matching libraries. Installed runtimes were not changed.

`answer_terms:check_answer_term/1` runs before PTCP copy/page storage and before
HTTP producer receive/message handoff. A computed cyclic template now reports
`error(representation_error(cyclic_term),_)` rather than an acyclic approximation.
A defensive handler check replaces any cycle still present in an escaping
exception with a finite envelope. No global occurs-check or unification behavior
is changed, and finite returned templates may use cycles during computation.

## Regression checks

[cyclic_answer_tests](regressions.log) passes, covering early guard behavior,
ordinary exception sharing, finite template/goal sharing, internal cycles,
later-page error/session recovery and HTTP producer-scope cleanup.

Five unchanged related groups pass. Their exact commands and exit statuses are
in [related-checks.json](related-checks.json):

- [Synchronous toplevel wrappers](synchronous.log)
- [Promise/yield correctness](promise.log)
- [HTTP once behavior and cleanup](http_once.log)
- [Whole-page deadline](http_deadline.log)
- [HTTP paging cleanup](http_cleanup.log)

The live cross-runtime candidate matrix records 31/31 required repair selections
passing with one separate engine diagnostic. It includes HTTP/WebSocket answer
rejection and all four caller/peer combinations for RPC/promise sharing,
cycle-error delivery and timeout-callback/retry controls. The full Trealla unit
and interop suites were not rerun.

The consolidated report, fixture commands, candidate runtime-source hashes,
node PIDs/ports, engine hashes and preservation checks are in
`trinity-conformance/reports/2026-10-25-cyclic-answer-rejection/`.

## Remaining exception-copying issue

The standalone [port-cyclic-exception-copy.pl](../../../reproducers/port-cyclic-exception-copy.pl)
imports no Web Prolog modules. It throws a cyclic payload and tests the term
received by the catch handler without printing the cycle itself.

- [Unmodified Trealla v3.14.10](exception-copy-trealla.log): cyclic before throw,
  acyclic after catch.
- [Separate SWI 10.1.18](exception-copy-swi.log): cyclic at both stages.

The candidate cannot recover the lost information in its handler. The live
Trealla HTTP cyclic-exception request still closes without an answer, followed
by a successful finite health query. This remains a diagnostic, not a passing
repair case. No global throw/catch rewriting or separate engine patch was added;
no upstream report was submitted.

Application message handling, the separate remote non-ground actor diagnostics,
installed runtimes, dependency pin and n3/n5 are unchanged. All disposable nodes
have stopped. The shared manual states the Trealla exception qualification.
