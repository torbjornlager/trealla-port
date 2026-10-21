% SPDX-License-Identifier: MIT
:- module(source_capture_tests, [run/0]).
:- use_module(actors).
:- use_module(isolation, []).
:- use_module(web_prolog, []).
:- use_module(node, []).

run :-
    snapshot(Expected),
    check_quoting,
    check_bootstrap_quoting,
    thread_self(Parent),
    setup_call_cleanup(
        thread_create(source_capture_tests:worker(Parent, Expected), Worker, []),
        ( thread_get_message(ready),
          thread_send_message(Worker, go),
          catch(repeat_snapshot(100, Expected), Error, Main = error(Error)),
          thread_get_message(finished(Other)),
          ( var(Main) -> true ; throw(Main) ),
          must_equal(Other, ok, worker)
        ),
        thread_join(Worker, true)),
    capture_boundary(Expected),
    writeln('Concurrent bootstrap and reply serialization: all regressions passed').

worker(Parent, Expected) :-
    thread_send_message(Parent, ready),
    thread_get_message(go),
    catch((repeat_snapshot(100, Expected), Result = ok), E, Result = error(E)),
    thread_send_message(Parent, finished(Result)).

repeat_snapshot(0, _) :- !.
repeat_snapshot(N, Expected) :-
    snapshot(Actual),
    must_equal(Actual, Expected, concurrent_snapshot),
    Next is N-1,
    repeat_snapshot(Next, Expected).

snapshot(snapshot(Full, Minimal, WS, HTTP)) :-
    isolation:bootstrap_text('capture\'quote\\slash', Full),
    isolation:minimal_bootstrap_text(probe, Minimal),
    payload(Term, X, Y),
    web_prolog:named_term_wire_atom(Term, ['Named'=X], WS),
    node:named_term_json_string(Term, ['Named'=X], HTTP),
    must_equal(WS, HTTP, serializer_agreement),
    ( var(X), var(Y), X \== Y -> true ; throw(bound_input_variables) ).

payload(payload('O\'Brien\\path', X, X, Y, [Y,X]), X, Y).

check_quoting :-
    payload(Term, X, _),
    web_prolog:named_term_wire_atom(Term, ['Named'=X], Text),
    read_term_from_atom(Text, Read, [variable_names(Names)]),
    Read = payload(Atom, A, B, C, [D,E]),
    must_equal(Atom, 'O\'Brien\\path', quoted_atom),
    ( var(A), A == B, A == E, var(C), C \== A, var(D), D \== C
    -> true ; throw(reply_variable_sharing) ),
    memberchk('Named'=Named, Names),
    ( Named == A -> true ; throw(reply_variable_name) ),
    % Existing serializer deliberately renders unnamed variables as '_'.
    % Canonical answers preserve their sharing separately.
    web_prolog:canonical_answer_text(Term, Canonical),
    read_term_from_atom(Canonical, payload(_, Q,Q,R,[R,Q]), []),
    ( var(Q), var(R), Q \== R -> true ; throw(canonical_sharing) ).

capture_boundary(Expected) :-
    thread_self(Parent),
    setup_call_cleanup(
        thread_create(source_capture_tests:boundary_worker(Parent, Expected), Worker, []),
        ( with_output_to(atom(Text),
              ( write(before), thread_send_message(Worker, go),
                thread_get_message(boundary(Result)), write(after) )),
          must_equal(Result, ok, capture_boundary_worker),
          must_equal(Text, beforeafter, surrounding_output)
        ),
        thread_join(Worker, true)).

boundary_worker(Parent, Expected) :-
    thread_get_message(go),
    catch((repeat_snapshot(3, Expected), Result=ok), E, Result=error(E)),
    thread_send_message(Parent, boundary(Result)).

must_equal(Actual, Expected, Label) :-
    ( Actual == Expected -> true ; throw(mismatch(Label)) ).

check_bootstrap_quoting :-
    Module = 'capture\'quote\\slash',
    isolation:bootstrap_text(Module, Text),
    setup_call_cleanup(open_string(Text, Stream), read_terms(Stream, Terms), close(Stream)),
    member((parallel(Goals) :- parallel:parallel_in(Module, Goals)), Terms),
    !.

read_terms(Stream, Terms) :-
    read_term(Stream, Term, []),
    ( Term == end_of_file -> Terms = []
    ; Terms = [Term|Rest], read_terms(Stream, Rest) ).
