% SPDX-License-Identifier: MIT
:- module(assert_goal_expansion_checks, [run/1]).

run(Case) :-
    case_kind(Case, Kind, Method),
    Quoted = 'O\'Brien\\path',
    format(atom(Source),
        'goal_expansion(eq(_,_),_) :- fail. goal_expansion(mark(X,Y),(Local=added,target(X,Y,Local))). goal_expansion(bad(_),_). target(~q,b,added). a1((H:-B),_) :- asserta((H:-B)). z1((H:-B),_) :- assertz((H:-B)). a2((H:-B),R) :- asserta((H:-B),R). z2((H:-B),R) :- assertz((H:-B),R).', [Quoted]),
    atom_chars(Source, Chars),
    in_temporary_module(assert_check_module,
        load_text(Chars, [module(assert_check_module)]),
        assert_goal_expansion_checks:check(Kind,Method,Quoted)).

case_kind(valid_a1, valid, a1).
case_kind(valid_z1, valid, z1).
case_kind(valid_a2, valid, a2).
case_kind(valid_z2, valid, z2).
case_kind(reject_a1, reject, a1).
case_kind(reject_z1, reject, z1).
case_kind(reject_a2, reject, a2).
case_kind(reject_z2, reject, z2).

store(Method, Clause, Ref) :-
    Goal =.. [Method, Clause, Ref],
    call(assert_check_module:Goal).

check(valid, Method, Quoted) :-
    read_term_from_atom('committed(X,X,Y) :- mark(X,Y), !.', Clause, []),
    term_variables(Clause, Vars),
    store(Method, Clause, Ref),
    check_ref(Method,Ref),
    maplist(var,Vars),
    assert_check_module:assertz(committed(fallback,fallback,fallback)),
    findall(A-B-C, assert_check_module:committed(A,B,C), Rows),
    Rows == [Quoted-Quoted-b],
    % The unexpanded reflected body must have no mark/2 left.
    assert_check_module:clause(committed(_,_,_), Body),
    \+ contains_mark(Body),
    writeq(passed(Method,Rows)),nl.

check(reject, Method, Quoted) :-
    read_term_from_atom('rejected(X) :- bad(X).', Clause, []),
    catch(store(Method,Clause,Ref), Error, true),
    ( nonvar(Error) -> true ; throw(assertion_silently_succeeded(Method)) ),
    var(Ref),
    ( current_predicate(assert_check_module:rejected/1)
    -> \+ assert_check_module:clause(rejected(_),_) ; true ),
    % A later, valid expansion still runs and its variables remain distinct.
    read_term_from_atom('after_error(X,X,Y) :- mark(X,Y).', Next, []),
    store(Method,Next,_),
    findall(A-B-C,assert_check_module:after_error(A,B,C),Rows),
    Rows == [Quoted-Quoted-b],
    writeq(rejected(Method,Error)),nl,
    writeq(recovered(Rows)),nl.

check_ref(a1,Ref) :- var(Ref).
check_ref(z1,Ref) :- var(Ref).
check_ref(a2,Ref) :- nonvar(Ref).
check_ref(z2,Ref) :- nonvar(Ref).

contains_mark(Term) :- nonvar(Term),
    ( Term = mark(_,_)
    ; compound(Term), Term =.. [_|Args], member(Arg,Args), contains_mark(Arg) ).
