% SPDX-License-Identifier: MIT
:- module(swi_lineage_compat,[run/3]).
:- use_module(library(http/websocket), []).
:- use_module(library(option)).
:- use_module(library(sgml)).
:- dynamic test_peer/1.
:- multifile distribution:hook_transport_options/2.
distribution:hook_transport_options(URL,[request_header('Authorization'='Bearer lineage-test-peer')]) :-
    swi_lineage_compat:test_peer(URL).

run(HomePort,PeerPort,NodeFile) :-
    use_module(NodeFile),
    node:node(HomePort,[profile(actor),auth(open)]),
    format(atom(URL),'http://127.0.0.1:~w',[PeerPort]),
    atom_concat(URL,'/ws',WSURL),
    setup_call_cleanup(
        websocket:http_open_websocket(WSURL,Observer,[]),
        once(swi_lineage_compat:checks(URL,WSURL,Observer)),
        catch(websocket:ws_close(Observer,1000,"done"),_,true)).

peer_options([request_header('Authorization'='Bearer lineage-test-peer')]).
a("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").
b("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").
checks(URL,WSURL,Observer) :-
    send(Observer,_{command:toplevel_spawn,options:"[session(true)]"}),
    event(Observer,spawned,O),
    % Ordinary anonymous callers cannot supply transport lineage.
    a(A),send(Observer,_{command:spawn,goal:"true",lineage:A,request_id:"denied"}),
    event(Observer,error,Denied),Denied.request_id=="denied",
    sub_string(Denied.data,_,_,_,"permission"),
    peer_options(Opts),
    setup_call_cleanup(websocket:http_open_websocket(WSURL,WS,Opts),
        once(swi_lineage_compat:wire_checks(WS,Observer,O.pid)),
        (websocket:ws_close(WS,1000,"done"),Closed=true)),
    cleanup_completed(Closed),
    reconnected_scope(WSURL),
    eventually_query(Observer,O.pid,"whereis(lineage_child_b,undefined),whereis(lineage_root_b,undefined)",50),
    connection_cleanup_checks(WSURL,Observer,O.pid,graceful),
    connection_cleanup_checks(WSURL,Observer,O.pid,eof),
    native_checks(URL,Observer,O.pid),
    writeln('Native SWI -> Trealla delegated lineage compatibility: all checks passed').

wire_checks(WS,Observer,O) :-
    a(A),b(B),
    spawn_family(WS,A,"a",RootA),spawn_family(WS,B,"b",RootB),
    send(WS,_{command:spawn,goal:"self(Me),register(lineage_legacy,Me),receive({finish -> true})",request_id:"legacy"}),
    event(WS,spawned,Legacy),
    scoped_top(WS,A,TopA),scoped_top(WS,B,TopB),scoped_top(WS,none,TopLegacy),
    scoped_query(WS,TopA,A,"whereis(lineage_child_a,P),P\\==undefined,whereis(lineage_child_b,undefined),whereis(lineage_legacy,undefined)",50),
    scoped_query(WS,TopB,B,"whereis(lineage_child_b,P),P\\==undefined,whereis(lineage_child_a,undefined)",50),
    scoped_query(WS,TopLegacy,none,"whereis(lineage_legacy,P),P\\==undefined,whereis(lineage_child_a,undefined)",50),
    eventually_query(Observer,O,"whereis(lineage_child_a,undefined),whereis(lineage_child_b,undefined),whereis(lineage_legacy,undefined)",50),
    send(WS,_{command:exit,pid:RootB,lineage:A,reason:"kill"}),
    event(WS,error,Cross),sub_string(Cross.data,_,_,_,"permission"),
    send(WS,_{command:exit,pid:RootA,reason:"kill"}),
    event(WS,error,Unscoped),sub_string(Unscoped.data,_,_,_,"permission"),
    send(WS,_{command:monitor,pid:RootB,lineage:B,ref:"kept(b)"}),
    % A must not remove B's monitor, even with its exact reference.
    send(WS,_{command:demonitor,lineage:A,ref:"kept(b)"}),
    send(WS,_{command:lineage_close,lineage:A}),
    down(WS,RootA,_),
    scoped_query(WS,TopB,B,"whereis(lineage_child_b,P),P\\==undefined,whereis(lineage_root_a,undefined),whereis(lineage_child_a,undefined)",50),
    scoped_query(WS,TopLegacy,none,"whereis(lineage_legacy,P),P\\==undefined",50),
    send(WS,_{command:lineage_close,lineage:A}),
    send(WS,_{command:spawn,lineage:A,goal:"true",request_id:"late"}),
    event(WS,error,Late),Late.request_id=="late",sub_string(Late.data,_,_,_,"closed_namespace"),
    send(WS,_{command:exit,lineage:B,pid:RootB,reason:"kill"}),
    down_ref(WS,RootB,"kept(b)"),
    send(WS,_{command:lineage_close,lineage:B}),
    scoped_query(WS,TopLegacy,none,"whereis(lineage_child_b,undefined),whereis(lineage_legacy,L),L\\==undefined",50),
    % Closing either lineage did not end the legacy actor.
    send(WS,_{command:send,pid:Legacy.pid,message:"finish"}),down(WS,Legacy.pid,_),
    % Reopen a different lineage to test connection-wide cleanup too.
    C="cccccccccccccccccccccccccccccccc",
    spawn_family(WS,C,"b",_),scoped_top(WS,C,TopC),
    scoped_query(WS,TopC,C,"whereis(lineage_child_b,P),P\\==undefined",50),

    writeln('Wire authority, multiplexing, late admission, legacy and monitor isolation: ok').

% Scope probes travel on the same connection and lineage as the actors.
% The independent observer must see no ordinary names. A reconnect gets a
% fresh context even with the same token; actor disposal is covered separately
% by receiver_lineage_tests:connection_cleanup and native close notifications.
scoped_send(WS,none,Dict) :- !,send(WS,Dict).
scoped_send(WS,Lineage,Dict) :- put_dict(lineage,Dict,Lineage,Command),send(WS,Command).
scoped_top(WS,Lineage,Pid) :-
    scoped_send(WS,Lineage,_{command:toplevel_spawn,options:"[session(true)]"}),
    event(WS,spawned,Reply),Pid=Reply.pid.
scoped_query(WS,Pid,Lineage,Goal,N) :-
    scoped_send(WS,Lineage,_{command:toplevel_call,pid:Pid,goal:Goal,options:"[template(ok),limit(1)]"}),
    query_result(WS,Reply),
    (Reply.type=="success" -> true
    ; N>0,sleep(0.02),Next is N-1,scoped_query(WS,Pid,Lineage,Goal,Next)).

reconnected_scope(WSURL) :-
    peer_options(Opts),C="cccccccccccccccccccccccccccccccc",
    setup_call_cleanup(websocket:http_open_websocket(WSURL,Fresh,Opts),
        (scoped_top(Fresh,C,Top),
         scoped_query(Fresh,Top,C,"whereis(lineage_root_b,undefined),whereis(lineage_child_b,undefined)",50),
         scoped_query(Fresh,Top,C,"self(Me),register(lineage_root_b,Me),whereis(lineage_root_b,Found),Found==Me",50)),
        catch(websocket:ws_close(Fresh,1000,"done"),_,true)).

spawn_family(WS,Lineage,Suffix,Pid) :-
    format(string(Goal),'self(Me),register(lineage_root_~s,Me),spawn((self(C),register(lineage_child_~s,C),receive({finish -> true})),_,[link(false)]),receive({finish -> true})',[Suffix,Suffix]),
    send(WS,_{command:spawn,lineage:Lineage,goal:Goal,request_id:Suffix}),
    event(WS,spawned,Reply),Reply.request_id==Suffix,Pid=Reply.pid.

native_checks(URL,Observer,O) :-
    % Use native distribution's normal encoder and reader, not hand-built JSON.
    asserta(test_peer(URL),Hook),
    setup_call_cleanup(true,swi_lineage_compat:native_owned_spawn(URL,Observer,O),
        (erase(Hook),distribution:remote_drop_connection(URL))).
native_owned_spawn(URL,Observer,O) :-
    a(A),atom_string(Token,A),
    Context=ctx(global,delegated(peer,Token),Token,false,none),
    writeln('Native lineage: spawning actor'),
    node_lifetime:with_context(Context,
        actors:spawn((self(Me),register(native_lineage_root,Me),receive({finish -> true})),
                     Pid,[node(URL),link(false),monitor(true)])),
    writeln('Native lineage: spawning toplevel'),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_spawn(Top,[node(URL),session(true),monitor(true),link(false)])),
    writeln('Native lineage: paged query'),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_call_synch(Top,member(X,[a,b]),Answer,
                                           [template(X),limit(1),timeout(3)])),
    (Answer=success(Top,[a],true),var(X) -> true
    ; throw(unexpected_native_toplevel_answer(Answer,X,Top))),
    writeln('Native lineage: scoped lookup'),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_next_synch(Top,Last,[timeout(3)])),
    Last=success(Top,[b],false),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_call_synch(Top,
            (whereis(native_lineage_root,Found),Found\==undefined),Lookup,
            [template(ok),limit(1),timeout(3)])),
    Lookup=success(Top,[ok],false),
    % Keep the original close-while-paged condition after the extra scope probe.
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_call_synch(Top,member(Y,[a,b]),Paged,
            [template(Y),limit(1),timeout(3)])),
    Paged=success(Top,[a],true),var(Y),
    writeln('Native lineage: closing paged lineage'),
    eventually_query(Observer,O,"whereis(native_lineage_root,undefined)",50),
    node_lifetime:with_context(Context,
        distribution:remote_send_command(URL,_{command:lineage_close})),
    actors:receive({down(Pid,Pid,_) -> true},[timeout(5),on_timeout(fail)]),
    actors:receive({down(Top,Top,_) -> true},[timeout(5),on_timeout(fail)]),
    eventually_query(Observer,O,"whereis(native_lineage_root,undefined)",50),
    writeln('Native distribution encoding, spawn-time monitor and lineage_close: ok').

send(WS,Dict) :- websocket:ws_send(WS,json(Dict)).
event(WS,Type,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    (Frame.opcode==close -> throw(unexpected_close(Frame))
    ; atom_string(Type,Frame.data.type) -> Reply=Frame.data
    ; event(WS,Type,Reply)).
down(WS,Pid,Reply) :- event(WS,down,R),(R.pid==Pid -> Reply=R ; down(WS,Pid,Reply)).
down_ref(WS,Pid,Ref) :- down(WS,Pid,R),(R.ref==Ref -> true ; down_ref(WS,Pid,Ref)).
eventually_query(WS,Pid,Goal,N) :-
    send(WS,_{command:toplevel_call,pid:Pid,goal:Goal,options:"[template(ok),limit(1)]"}),
    query_result(WS,Reply),
    (Reply.type=="success" -> true
    ; N>0,sleep(0.02),Next is N-1,eventually_query(WS,Pid,Goal,Next)).
query_result(WS,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    (memberchk(Frame.data.type,["success","failure","error"]) -> Reply=Frame.data
    ; query_result(WS,Reply)).

% Commit each setup body before awaiting effects of its cleanup. A successful
% nondeterministic body otherwise leaves setup_call_cleanup/3's close pending.
% Names disappearing on a new connection is not evidence of actor termination:
% use independent language-level monitors with exact references instead.
connection_cleanup_checks(URL,Observer,O,Mode) :-
    peer_options(Opts),
    setup_call_cleanup(websocket:http_open_websocket(URL,Kept,Opts),
        once(cleanup_kept(URL,Kept,Observer,O,Mode)),
        (websocket:ws_close(Kept,1000,"done"),Closed=true)),
    cleanup_completed(Closed),
    cleanup_result(Observer),
    format('Connection cleanup (~w): roots, unlinked children, toplevels and independent connection: ok~n',[Mode]).

cleanup_kept(URL,Kept,Observer,O,Mode) :-
    C="dddddddddddddddddddddddddddddddd",
    cleanup_family(Kept,C,O,kept,KeptRoot),scoped_top(Kept,C,KeptTop),
    peer_options(Opts),
    setup_call_cleanup(websocket:http_open_websocket(URL,Closing,Opts),
        once((cleanup_family(Closing,C,O,closing,Root),scoped_top(Closing,C,Top),
              arm_cleanup(Observer,O,Root,Top,KeptRoot,KeptTop))),
        (close_probe_socket(Mode,Closing),Closed=true)),
    cleanup_completed(Closed),
    % The observer acknowledges down for the closed family, then proves both
    % unlinked survivors answer a message before we close the other connection.
    cleanup_marker(Observer,cleanup_first_closed),
    scoped_query(Kept,KeptTop,C,"true",0).

cleanup_completed(Closed) :-
    ( Closed==true -> true ; throw(connection_cleanup_still_pending) ).

close_probe_socket(graceful,WS) :- websocket:ws_close(WS,1000,"done").
close_probe_socket(eof,WS) :- close(WS).

cleanup_family(WS,C,O,Tag,Root) :-
    % Child reports readiness to its root before the observer can monitor it.
    % Both actors are unlinked; neither should survive their owning connection.
    atomic_list_concat([
        'self(R),spawn((send(R,child_ready),',
        'receive({ping(F)->send(F,pong(~w,child)),receive({finish->true})})),Child,[link(false)]),',
        'receive({child_ready->send(~d,family(~w,R,Child))}),',
        'receive({ping(F)->send(F,pong(~w,root)),receive({finish->true})})'
    ],Format),
    format(string(Goal),Format,[Tag,O,Tag,Tag]),
    send(WS,_{command:spawn,lineage:C,goal:Goal,options:"[link(false)]",request_id:Tag}),
    event(WS,spawned,Reply),Root=Reply.pid.

arm_cleanup(WS,O,Root,Top,KeptRoot,KeptTop) :-
    atomic_list_concat([
        'receive({family(closing,_,Child)->true},[timeout(5),on_timeout(throw(missing_closing_family))]),',
        'receive({family(kept,_,KeptChild)->true},[timeout(5),on_timeout(throw(missing_kept_family))]),',
        'monitor(~d,R1),monitor(Child,R2),monitor(~d,R3),',
        'monitor(~d,K1),monitor(KeptChild,K2),monitor(~d,K3),writeln(cleanup_armed),',
        'receive({down(_,R1,kill)->true},[timeout(5),on_timeout(throw(missing_root_down))]),',
        'receive({down(_,R2,kill)->true},[timeout(5),on_timeout(throw(missing_child_down))]),',
        'receive({down(_,R3,kill)->true},[timeout(5),on_timeout(throw(missing_top_down))]),',
        'self(Me),send(~d,ping(Me)),send(KeptChild,ping(Me)),',
        'receive({pong(kept,root)->true},[timeout(5),on_timeout(throw(missing_kept_pong))]),',
        'receive({pong(kept,child)->true},[timeout(5),on_timeout(throw(missing_kept_child_pong))]),',
        'writeln(cleanup_first_closed),',
        'receive({down(_,K1,kill)->true},[timeout(5),on_timeout(throw(missing_kept_root_down))]),',
        'receive({down(_,K2,kill)->true},[timeout(5),on_timeout(throw(missing_kept_child_down))]),',
        'receive({down(_,K3,kill)->true},[timeout(5),on_timeout(throw(missing_kept_top_down))])'
    ],Format),
    format(string(Goal),Format,[Root,Top,KeptRoot,KeptTop,KeptRoot]),
    send(WS,_{command:toplevel_call,pid:O,goal:Goal,options:"[template(ok),limit(1)]"}),
    cleanup_marker(WS,cleanup_armed).

cleanup_marker(WS,Marker) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    ( Frame.opcode==close -> throw(unexpected_close(Frame))
    ; Frame.data.type=="io_request" ->
        send(WS,_{command:browser_io_reply,request_id:Frame.data.request_id,status:"ok"}),
        cleanup_marker_event(WS,Marker,Frame.data.event)
    ; cleanup_marker_event(WS,Marker,Frame.data)
    ).
cleanup_marker_event(WS,Marker,Event) :-
    atom_string(Marker,Text),
    ( Event.type=="output",sub_string(Event.data,_,_,_,Text) -> true
    ; memberchk(Event.type,["success","failure","error"]) -> throw(cleanup_observer_failed(Event))
    ; cleanup_marker(WS,Marker)
    ).
cleanup_result(WS) :-
    query_result(WS,Reply),
    ( Reply.type=="success",Reply.more==false -> true
    ; throw(cleanup_observer_failed(Reply)) ).
