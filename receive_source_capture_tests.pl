% SPDX-License-Identifier: MIT
:- module(receive_source_capture_tests, [run/0]).
:- use_module(actors).
:- use_module(sandbox_policy).
:- use_module(isolation, []).

% Tutorial 07 copies greeter/0 and husband/2 from a private toplevel.
% Assert the inferred binding as well as the fallback, including a second
% generation of copying, so accepting the spawn alone cannot hide a bad guard.
run :-
    forall(member(Mode,[blacklist,whitelist]),
      (copied_guard(Mode,direct),copied_guard(Mode,nested),
       forbidden_guard(Mode),private_helper_is_not_public(Mode))),
    writeln('PASS copied receive guards retain private inference and sandbox checks').

source(Text) :-
    atomic_list_concat([
        'husband(xantippa,socrates).',
        'greeter :-',
        '    receive({',
        '        hello(From,W) if husband(W,H) -> From ! matched(W,H), greeter ;',
        '        hello(From,W) -> From ! fallback(W), greeter ;',
        '        stop -> true',
        '    }).',
        'roundtrip(ReplyTo) :-',
        '    self(Self),',
        '    spawn(greeter,Child,[src_predicates([greeter/0,husband/2]),monitor(true)]),',
        '    Child ! hello(Self,xantippa),',
        '    receive({matched(xantippa,socrates)->true},',
        '            [timeout(2),on_timeout(throw(missing_inference_reply))]),',
        '    Child ! hello(Self,plato),',
        '    receive({fallback(plato)->true},',
        '            [timeout(2),on_timeout(throw(missing_fallback_reply))]),',
        '    Child ! stop,',
        '    receive({down(Child,Child,true)->true},',
        '            [timeout(2),on_timeout(throw(missing_greeter_down))]),',
        '    ReplyTo ! roundtrip_ok.'
    ],'\n',Text).

copied_guard(Mode,Kind) :-
    source(Source),
    (Kind==direct -> Work=roundtrip(Self)
    ; Work=(spawn(roundtrip(Self),Middle,
                  [src_predicates([roundtrip/1,greeter/0,husband/2]),monitor(true)]),
            receive({down(Middle,Middle,true)->true},
                    [timeout(3),on_timeout(throw(missing_middle_down))]))),
    Goal=(self(Self),Work,
          receive({roundtrip_ok->true},[timeout(0),on_timeout(throw(missing_roundtrip))])),
    sandbox_prepare_spawn(Mode,actor,actor_context,Goal,
                          [src_text(Source),monitor(true)],Prepared,Options),
    setup_call_cleanup(spawn(Prepared,Session,Options),
      (receive({down(Session,Session,Reason)->true},
               [timeout(5),on_timeout(throw(missing_guard_session))]),
       require(Reason==true,guard_copy_failed(Mode,Kind,Reason))),
      (catch(exit(Session,kill),_,true),catch(demonitor(Session,[flush]),_,true))).

forbidden_guard(Mode) :-
    Text="bad :- receive({go if open('/must-not-open',read,_)->true}).",
    catch(sandbox_prepare_spawn(Mode,actor,actor_context,bad,[src_text(Text)],_,_),Error,true),
    require(nonvar(Error),forbidden_guard_accepted(Mode)),
    require(Error=error(permission_error(call,sandboxed,_),_),unexpected_guard_error(Error)).

private_helper_is_not_public(Mode) :-
    catch(sandbox_check_goal(Mode,actor,actor_context,
             isolation:call_actor_leaf(other_private_module,true)),Error,true),
    require(nonvar(Error),private_helper_accepted(Mode)),
    require(Error=error(permission_error(call,sandboxed,_),_),unexpected_helper_error(Error)).

require(Goal,Error) :- (call(Goal)->true;throw(Error)).
