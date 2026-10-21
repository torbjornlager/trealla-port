% SPDX-License-Identifier: MIT
:- module(remote_toplevel_creation_tests,[run/0,live/2]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(distribution).
:- use_module(source_policy,[]).

run :-
    actors(Before),
    catch(toplevel_spawn(Bad,[node('http://127.0.0.1:1'),
          src_uri('http://invalid/source'),session(true),session(bad)]),Error,true),
    Error=error(type_error(boolean,bad),_),var(Bad),
    actors(After),sort(Before,Sorted),sort(After,Sorted),
    toplevel_spawn(Local,[node(localhost),session(false),session(true),
                         link(false),monitor(true)]),
    toplevel_call(Local,true),
    receive({success(Local,[true],false) -> true},[timeout(2),on_timeout(fail)]),
    down(Local),
    writeln('General toplevel creation: validation and local path unchanged').

copied(copied).
live(URL,URI) :-
    once(source_policy:parse_http_uri(URI,Scheme,Host,Port,_)),
    format(atom(Origin),'~w://~w:~w',[Scheme,Host,Port]),
    once(source_policy:configure_source_policy(
      [load_uri_allowed_origins([Origin]),load_uri_allowed_ip_ranges(['127.0.0.0/8'])],_)),
    setup_call_cleanup(true,
      (once(sources_and_paging(URL,URI)),once(targets_and_monitors(URL)),
       once(linked_parent(URL)),once(lifecycle_options(URL)),
       ordinary_actor(URL),
       format('General remote toplevel creation on ~w: passed~n',[URL])),
      (remote_drop_connection(URL),source_policy:reset_source_policy)).

sources_and_paging(URL,URI) :-
    toplevel_spawn(P,remote_toplevel_creation_tests:[node(URL),link(false),monitor(true),
      session(true),session(false),time_limit(infinite),time_limit(0.01),
      idle_limit(infinite),idle_limit(0.01),
      src_text('from_text(text).'),src_list([from_list(list)]),
      src_predicates([copied/1]),src_uri(URI)]),
    monitor(P,Own),
    setup_call_cleanup(true,
      (toplevel_call(P,(from_text(T),from_list(L),copied(C),uri_value(U),atom(U)),
          [template(row(T,L,C))]),
       receive({success(P,[row(text,list,copied)],false) -> true},
         [timeout(3),on_timeout(fail)]),
       toplevel_call_synch(P,member(X,[a,b,c]),First,[template(X-X),limit(1),timeout(3)]),
       First==success(P,[a-a],true),var(X),
       toplevel_next(P,[limit(2)]),
       receive({success(P,[b-b,c-c],false) -> true},[timeout(3),on_timeout(fail)])),
      stop_monitored(P,Own)),
    await_route_removed(P,100),
    writeln('text/list/copied/URI sources, sharing, paging and monitor cleanup: ok').

targets_and_monitors(URL) :-
    self(Parent),
    spawn((receive({Message -> send(Parent,forwarded(Message))}),
           receive({finish -> true})),Other,[link(false)]),
    monitor(Other,OtherRef),
    setup_call_cleanup(true,
      (toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true),
                        target(Other),target(Parent)]),
       monitor(P,Own),
       setup_call_cleanup(true,
         (toplevel_call(P,X=first,[template(X)]),
          receive({forwarded(success(P,[first],false)) -> true},[timeout(3),on_timeout(fail)]),
          toplevel_call(P,Y=second,[template(Y),target(Parent)]),
          receive({success(P,[second],false) -> true},[timeout(3),on_timeout(fail)]),
          toplevel_call_synch(P,Z=third,Answer,[template(Z),timeout(3)]),
          Answer==success(P,[third],false),var(X),var(Y),var(Z)),
         stop_monitored(P,Own))),
      (exit(Other,kill),
       receive({down(Other,OtherRef,_) -> true},[timeout(2),on_timeout(fail)]),
       demonitor(OtherRef,[flush]))),
    writeln('spawn/call targets, caller-owned monitors and unrelated monitor: ok').

linked_parent(URL) :-
    self(Caller),
    spawn((toplevel_spawn(Child,[node(URL),session(true),monitor(true)]),
           send(Caller,linked_toplevel(Child)),receive({finish -> true})),Parent,
          [link(false),monitor(true)]),
    setup_call_cleanup(true,
      (receive({linked_toplevel(P) -> true;
                down(Parent,Parent,Reason) -> throw(linked_start_failed(Reason))},
               [timeout(3),on_timeout(fail)]),
       setup_call_cleanup(monitor(P,Ref),
         (exit(Parent,kill),down(Parent),
          receive({down(P,Ref,_) -> true},[timeout(3),on_timeout(fail)])),
         (exit(P,kill),demonitor(Ref,[flush])))),
      exit(Parent,kill)),
    writeln('default remote link retains parent-termination propagation: ok').

lifecycle_options(URL) :-
    toplevel_spawn(P,[node(URL),session(false),session(true),link(false),monitor(true),
                     time_limit(0.1),time_limit(infinite)]),
    setup_call_cleanup(true,
      (toplevel_call(P,(repeat,fail)),
       receive({error(P,Error) -> nonvar(Error)},[timeout(3),on_timeout(fail)]),
       down(P)),exit(P,kill)),
    toplevel_spawn(Idle,[node(URL),session(true),link(false),monitor(true),
                        idle_limit(0.1),idle_limit(infinite)]),
    setup_call_cleanup(true,down(Idle),exit(Idle,kill)),
    writeln('session, computation and idle limits retain first-option precedence: ok').

ordinary_actor(URL) :-
    self(Parent),spawn(Parent ! ordinary_ok,P,[node(URL),link(false),monitor(true)]),
    receive({ordinary_ok -> true},[timeout(3),on_timeout(fail)]),down(P),
    writeln('ordinary remote actor spawning unchanged: ok').

stop_monitored(P,Own) :-
    exit(P,kill),down(P),
    receive({down(P,Own,_) -> true},[timeout(3),on_timeout(fail)]),
    demonitor(Own,[flush]).
down(P) :- receive({down(P,P,_) -> true},[timeout(3),on_timeout(fail)]).

% Down notifications precede the writer's asynchronous route retirement.
await_route_removed(P,Attempts) :-
    (distribution:remote_pid_writer(P,_,_) ->
      Attempts>0,sleep(0.01),Next is Attempts-1,await_route_removed(P,Next)
    ; true).
