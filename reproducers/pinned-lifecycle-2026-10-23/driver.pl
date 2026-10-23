% SPDX-License-Identifier: MIT
% Consult rpc_lifecycle_tests.pl first; this driver changes no runtime code.
focused_lifecycle(Kind,N) :-
    assertz(lifecycle_diagnostics),
    forall(between(1,N,I),
        (lifecycle_stage(iteration(Kind,I)),
         lifecycle_step(case(Kind,I),focused_case(Kind)))),
    writeln('all regressions passed').
focused_case(hard_cancel) :- lifecycle_hard_cancel_cleanup.
focused_case(delivery) :- delivery_cleanup_once.
