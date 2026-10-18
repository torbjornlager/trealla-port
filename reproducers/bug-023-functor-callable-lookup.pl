% SPDX-License-Identifier: MIT
% Run without Web Prolog:
% tpl -f reproducers/bug-023-functor-callable-lookup.pl -g "reproducer,halt"
% All four cases should succeed. Trealla v3.13.10 fails the functor cases.

reproducer :-
    functor(Goal1, '=', 2), arg(1, Goal1, X1), arg(2, Goal1, ok),
    outcome(call(Goal1), Result1),
    writeq(functor_goal(Result1, X1)), nl,
    Goal2 =.. ['=', X2, ok],
    outcome(call(Goal2), Result2),
    writeq(univ_goal(Result2, X2)), nl,
    functor(Expr1, '+', 2), arg(1, Expr1, 2), arg(2, Expr1, 3),
    outcome((Value1 is Expr1), Result3),
    writeq(functor_arithmetic(Result3, Value1)), nl,
    Expr2 =.. ['+', 2, 3],
    outcome((Value2 is Expr2), Result4),
    writeq(univ_arithmetic(Result4, Value2)), nl.

outcome(Goal, Result) :-
    catch((call(Goal) -> Result = success ; Result = failure),
          Error, Result = exception(Error)).
