% SPDX-License-Identifier: MIT
:- module(supervisor_intensity_tests,[run/0]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/actors.pl').
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/supervisor_actor.pl').
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/server_actor.pl').
% Reuse the real server startup counters and stop observations from the
% restart tests, rather than simulating replacement success in this suite.
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/supervisor_restart_tests.pl',[]).

run :-
    accounting,
    forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]),exhaustion(Strategy,0,normal)),
    exhaustion(one_for_one,2,normal),
    exhaustion(one_for_one,0,policies),
    exhaustion(one_for_one,0,cleanup_error),
    local_monitor_isolation,
    abort_control,
    writeln('Supervisor restart-intensity exhaustion cleanup: all regressions passed').

accounting :-
    \+supervisor_actor:check_intensity(0,5,[],_),
    supervisor_actor:check_intensity(2,5,[],One),length(One,1),
    supervisor_actor:check_intensity(2,5,One,Two),length(Two,2),
    \+supervisor_actor:check_intensity(2,5,Two,_),
    get_time(Now),Old is Now-100,Recent is Now+100,
    supervisor_actor:check_intensity(1,5,[Old],Pruned),length(Pruned,1),
    \+supervisor_actor:check_intensity(1,5,[Recent,Old],_),
    \+supervisor_actor:recent_restart(10,10),supervisor_actor:recent_restart(10,11),
    writeln('zero/positive limits, allowed restart count, period pruning and strict boundary preserved: ok').

exhaustion(Strategy,Max,Mode) :-
    supervisor_restart_tests:reset,
    thread_self(Observer),assertz(supervisor_restart_tests:observer(Observer)),self(Self),
    (Mode==policies -> AP=0.02,CP=brutal_kill;AP=infinity,CP=0.1),
    supervisor_restart_tests:child(a,AP,A),
    supervisor_restart_tests:child(b,0.1,B),
    supervisor_restart_tests:child(c,CP,C),
    (Mode==policies -> A=child(a,AOpts),select(start(server(CB,Opts)),AOpts,Rest),
       ASource=child(a,[start(server(CB,[initial_state(Self)|Opts]))|Rest]);ASource=A),
    supervisor_spawn(supervisor_restart_tests:[ASource,B,C],Sup,
       [strategy(Strategy),intensity(Max),period(100),monitor(true),link(false)]),
    setup_call_cleanup(true,
      (supervisor_which_children(Sup,[info(a,PA,_,_),info(b,PB,_,_),info(c,PC,_,_)]),
       monitor(PA,RA),monitor(PC,RC),monitor(Sup,ExtraSup),
       allowed_restarts(Max,Sup,PB,Last),
       (Mode==policies -> make_ref(Request),send(PA,'$call'(Self,Request,hold)),
          receive({held -> true},[timeout(2),on_timeout(fail)]);true),
       (Mode==cleanup_error -> assertz(supervisor_restart_tests:stop_fault(c,cleanup_error(c)));true),
       monitor(Last,RB),server_halt(Last,_),
       receive({down(Sup,Sup,shutdown) -> true},[timeout(4),on_timeout(throw(exhaustion_missing(Strategy,Mode)))]),
       receive({down(Sup,ExtraSup,shutdown) -> true},[timeout(0),on_timeout(fail)]),
       receive({down(Last,RB,true) -> true},[timeout(1),on_timeout(fail)]),
       (Mode==policies -> AR=shutdown,CR=kill
       ; Mode==cleanup_error -> AR=true,CR=shutdown
       ; AR=true,CR=true),
       receive({down(PA,RA,AR) -> true},[timeout(1),on_timeout(fail)]),
       receive({down(PC,RC,CR) -> true},[timeout(1),on_timeout(fail)]),
       BStarts is Max+1,supervisor_restart_tests:attempts(b,BStarts),
       supervisor_restart_tests:attempts(a,1),supervisor_restart_tests:attempts(c,1),
       forall(supervisor_restart_tests:identities(P,_,_),\+actors:actor_thread(P,_)),
       whereis(a,undefined),whereis(b,undefined),whereis(c,undefined),
       supervisor_restart_tests:find_stops(Stops),
       (Mode==normal -> expected_stops(Max,Expected),Stops==Expected;true)),
      exit(Sup,kill)),
    supervisor_restart_tests:reset,
    format('~w intensity(~w), ~w: no excess replacements, reverse policy cleanup and shutdown reason: ok~n',[Strategy,Max,Mode]).

allowed_restarts(0,_,Pid,Pid) :- !.
allowed_restarts(N,Sup,Pid,Last) :-
    monitor(Pid,Ref),server_halt(Pid,_),
    receive({down(Pid,Ref,true) -> true},[timeout(2),on_timeout(fail)]),
    % Requests are processed after the down that triggers replacement, so this
    % is a barrier for replacement admission and avoids timing-based sleeps.
    supervisor_which_children(Sup,[info(a,_,_,_),info(b,New,_,_),info(c,_,_,_)]),
    New\==Pid,ground(New),N1 is N-1,allowed_restarts(N1,Sup,New,Last).
expected_stops(0,[b-1,c-1,a-1]).
expected_stops(2,[b-1,b-2,b-3,c-1,a-1]).

% Check same-mailbox application monitors/messages at the cleanup boundary.
% An external actor supplies the supervisor identity, keeping exit(shutdown)
% away from the test runner's own actor state.
local_monitor_isolation :-
    self(Self),spawn_runtime(supervisor_intensity_tests:isolated_exhaustion(Self),Pid,
      [monitor(true),link(false),'$entry_context'(caller)]),
    receive({isolation_ok -> true},[timeout(3),on_timeout(fail)]),
    receive({down(Pid,Pid,shutdown) -> true},[timeout(3),on_timeout(fail)]),
    writeln('exhaustion cleanup preserves additional child monitors and unrelated queued messages: ok').
isolated_exhaustion(Observer) :-
    server_spawn(supervisor_restart_tests:callback,[],Child,[name(intensity_monitor)]),
    monitor(Child,AppRef),self(Self),send(Self,down(unrelated,application,unrelated_reason)),
    Spec=spec(intensity_monitor,server(supervisor_restart_tests:callback,[]),temporary,0.1,worker),
    catch(supervisor_actor:intensity_exhausted([ch(intensity_monitor,Child,Spec)]),actor_exit,true),
    receive({down(Child,AppRef,true) -> true},[timeout(0),on_timeout(fail)]),
    receive({down(unrelated,application,unrelated_reason) -> true},[timeout(0),on_timeout(fail)]),
    % Exit was caught only to inspect the mailbox. Its committed public reason
    % is still shutdown; the enclosing fixture checks that reason as well.
    send(Observer,isolation_ok).

abort_control :-
    catch(supervisor_startup:cleanup_child_error('$abort_goal'),Error,true),Error=='$abort_goal',
    writeln('runtime abort control remains a control transfer: ok').
