% SPDX-License-Identifier: MIT
:- module(receive_caller_tests, [run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(isolation, []).
:- use_module(toplevel_actors, []).

run :-
    submitted('self(S),send(S,guard_probe),receive({guard_probe if runtime_property(persistent(true))->Result=accepted},[timeout(0),on_timeout(Result=lost)])', Result),
    require(Result==accepted,submitted_guard_api_lost),
    submitted('self(S),send(S,rpc(data,data)),receive({rpc(A,B)->runtime_property(persistent(true)),Result=pair(A,B)},[timeout(0),on_timeout(throw(body_lost))])', Pair),
    require(Pair==pair(data,data),pattern_or_body_changed),
    submitted('receive({},[timeout(0),on_timeout((runtime_property(persistent(true)),Result=expired))])', Expired),
    require(Expired==expired,timeout_api_lost),
    writeln('PASS submitted receive guards, bodies and timeout API dispatch; message patterns remain data'),
    sourced((self(S1),send(S1,p),findall(X1,receive({p->runtime_property(persistent(true)),member(X1,[a,b])},[timeout(0),on_timeout(throw(body_lost))]),R1)),R1,[a,b]),
    sourced((self(S2),send(S2,p),findall(X2,receive({p->rc_private(X2)},[timeout(0),on_timeout(throw(body_lost))]),R2)),R2,[1,2]),
    sourced((self(S3),send(S3,p),findall(X3,receive({p if rc_private(_)->X3=bound},[timeout(0),on_timeout(throw(body_lost))]),R3)),R3,[bound]),
    sourced((self(S4),send(S4,p),once(receive({p->runtime_property(persistent(true)),rc_private(R4)},[timeout(0),on_timeout(throw(body_lost))]))),R4,1),
    sourced((self(S5),send(S5,p),catch(receive({p->rc_private(_),throw(seen)},[timeout(0),on_timeout(throw(body_lost))]),seen,rc_private(R5))),R5,1),
    sourced((self(S6),send(S6,p),bagof(X6,receive({p->rc_private(X6)},[timeout(0),on_timeout(throw(body_lost))]),R6)),R6,[1,2]),
    sourced((findall(X7,receive({},[timeout(0),on_timeout(rc_private(X7))]),R7)),R7,[1,2]),
    writeln('PASS receive under findall/3, bagof/3, once/1 and catch/3 in a sourced actor keeps the API, private source and bindings').

% A toplevel with private source runs queries in its own actor module. A
% receive nested in an opaque meta-call must keep the same callback context
% as a receive called directly (conformance RC-009).
sourced(Goal, Template, Expected) :-
    self(Self),
    toplevel_spawn(Pid,[target(Self),session(true),link(false),monitor(true),
                        src_text('rc_private(1). rc_private(2).')]),
    setup_call_cleanup(true,
      (toplevel_call_synch(Pid,Goal,Answer,
         [template(Template),limit(1),
          timeout(3),on_timeout(throw(sourced_receive_timeout))]),
       (Answer=success(Pid,[Actual],_) -> require(Actual==Expected,sourced(Goal,Actual))
       ; throw(sourced(Goal,Answer)))),
      (exit(Pid,kill),receive({down(Pid,Pid,_) -> true},
                           [timeout(3),on_timeout(fail)]))).

submitted(Text, Result) :-
    read_term_from_atom(Text, Goal, [variable_names(Names)]),
    memberchk('Result'=Result,Names),
    isolation:execution_goal(Goal, Prepared),
    call(Prepared).

require(Goal, Error) :- (call(Goal)->true;throw(Error)).
