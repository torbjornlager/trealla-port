% SPDX-License-Identifier: MIT
:- module(websocket_activation_tests,[run/0]).
:- use_module(actors).
:- use_module(web_prolog,[]).
:- use_module(isolation,[]).
:- use_module(websocket,[]).
:- dynamic observer/1.
:- multifile isolation:prepare_activation_goal/5.

% Observe the actual framework entry before activation, without replacing it.
isolation:prepare_activation_goal(_,Module,_,Goal0,_) :-
    websocket_activation_tests:observer(Observer),
    strip_module(Goal0,_,Goal),functor(Goal,relay_start,5),
    actors:send(Observer,relay_entry_context(Module)),fail.

run :-
    self(Self),
    setup_call_cleanup(assertz(observer(Self)),ready_relay(Self),retractall(observer(_))),
    forall(member(Goal,[fail,throw(activation_fixture)]),failed_activation(Goal)),
    failed_welcome(Self),
    stopped_relay_error_frame,
    writeln('WebSocket relay context, activation, death and correlated welcome waits: passed').

ready_relay(Self) :-
    web_prolog:spawn_browser_relay(no_socket,principal(local,[admin]),local,false,none,Relay),
    setup_call_cleanup(true,
        (receive({relay_entry_context(web_prolog)->true},
                 [timeout(1),on_timeout(throw(wrong_relay_entry_context))]),
         web_prolog:browser_relay(Relay),
         isolation:actor_module(Relay,_),
         \+isolation:actor_source_module(Relay,_),
         \+actors:monitor(Self,Relay,_)),
        web_prolog:close_connection(Relay)),
    \+web_prolog:browser_relay(Relay),\+actors:actor_thread(Relay,_).

failed_activation(Goal) :-
    actors:spawn_scoped(Goal,Relay,[link(false),monitor(true),'$shared_db'(false)],none,internal),
    setup_call_cleanup(true,
        (catch(web_prolog:await_browser_relay(Relay),Error,true),
         nonvar(Error),Error=error(existence_error(websocket_relay,Relay),web_prolog_handler/2)),
        demonitor(Relay,[flush])).

failed_welcome(Self) :-
    actors:spawn_scoped(websocket_activation_tests:die_on_hello(Self),Relay,
        [link(false),'$shared_db'(false),'$entry_context'(caller)],none,internal),
    receive({fixture_ready(Relay)->true},[timeout(1),on_timeout(throw(fixture_not_ready))]),
    make_ref(Other),
    send(Self,unrelated(Other)),send(Self,'$transport_ready'(Other)),
    send(Self,down(Relay,Other,unrelated)),
    thread_self(Reader),web_prolog:object([version-number(1)],JSON),
    catch(web_prolog:dispatch(transport_hello,JSON,Relay,Reader,actor,blacklist),Error,true),
    nonvar(Error),Error=error(existence_error(websocket_relay,Relay),web_prolog_handler/2),
    \+actors:monitor(Self,Relay,_),
    receive({unrelated(Other)->true},[timeout(0),on_timeout(throw(lost_unrelated))]),
    receive({'$transport_ready'(Other)->true},[timeout(0),on_timeout(throw(lost_other_ready))]),
    receive({down(Relay,Other,unrelated)->true},[timeout(0),on_timeout(throw(lost_other_down))]).

die_on_hello(Parent) :-
    self(Self),send(Parent,fixture_ready(Self)),
    actors:receive_qualified(websocket_activation_tests:{
        '$transport_hello'(_,_,_,_,_,_)->fail
    },[]).

stopped_relay_error_frame :-
    make_ref(Relay),format(atom(File),'/tmp/relay-error-~w.frame',[Relay]),
    Error=error(existence_error(websocket_relay,Relay),web_prolog_handler/2),
    setup_call_cleanup(true,
        (setup_call_cleanup(open(File,write,S,[type(binary)]),
            (websocket:ws_open(S,WS,[role(server)]),
             catch(web_prolog:read_dispatch_error(WS,Relay,Error),Caught,true),
             Caught==Error),close(S)),
         setup_call_cleanup(open(File,read,R,[type(binary)]),
            (websocket:ws_open(R,Client,[role(client)]),
             websocket:ws_receive(Client,text(Text)),
             web_prolog:json_atom(JSON,Text),
             web_prolog:json_atom_field(JSON,type,error),
             web_prolog:json_atom_field(JSON,data,ErrorText),
             sub_atom(ErrorText,_,_,_,'existence_error(websocket_relay,')),close(R))),
        catch(delete_file(File),_,true)).
