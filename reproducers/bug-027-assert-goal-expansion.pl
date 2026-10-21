% SPDX-License-Identifier: MIT
% Standalone Trealla assertion/expansion reproducer; no Web Prolog code.
:- module(assert_goal_expansion_reproducer,[run/0, control/0]).
run :- fixture(assert_goal_expansion_reproducer:check).
control :- fixture(assert_goal_expansion_reproducer:check_ground).
fixture(Goal) :-
    Source = 'goal_expansion(eq(_,_),_) :- fail. goal_expansion(mark(X,Y),(Local=added,target(X,Y,Local))). goal_expansion(ground_marker,true). target(a,b,added). store((Head:-Body)) :- assertz((Head:-Body)).',
    atom_chars(Source,Chars),
    in_temporary_module(probe_module,
       load_text(Chars,[module(probe_module)]),
       Goal).
check :-
    read_term_from_atom('probe(X,X,Y) :- eq(X,Y).',Clause,[]),
    probe_module:store(Clause),
    probe_module:assertz(eq(a,a)),
    findall(A-B-C,probe_module:probe(A,B,C),Rows),
    writeq(first(Rows)),nl,
    ground_result(Ground),
    read_term_from_atom('after(X,X,Y) :- mark(X,Y).',Next,[]),
    probe_module:store(Next),
    catch(findall(A-B-C,probe_module:after(A,B,C),After),E,After=error(E)),
    writeq(after(After)),nl,
    After == [a-a-b], Ground == ok.

check_ground :- ground_result(Result), Result == ok.
ground_result(Result) :-
    probe_module:store((ground_recovery :- ground_marker)),
    catch((probe_module:ground_recovery -> Result=ok ; Result=failed),
          Error, Result=error(Error)),
    writeq(ground(Result)),nl.
