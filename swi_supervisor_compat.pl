% SPDX-License-Identifier: MIT
:- module(swi_supervisor_compat,[run/3]).
:- use_module(library(http/websocket), []).
run(HomePort,PeerPort,NodeFile) :-
    use_module(NodeFile),
    file_directory_name(NodeFile,Dir),directory_file_path(Dir,'supervisor_actor.pl',SupFile),
    use_module(SupFile),node:node(HomePort,[profile(actor),auth(open)]),
    format(atom(URL),'http://localhost:~w',[PeerPort]),
    thread_create(swi_supervisor_compat:exercise(URL),Thread,[]),
    thread_join(Thread,Status),
    (Status==true -> true ; throw(error(compatibility_check_failed(Status),run/3))).
exercise(URL) :-
    wire_checks(URL),
    named_checks(URL),
    forall(between(1,10,_),halt_cycle(URL)),
    supervisor_actor:supervisor_spawn([],Empty,[node(URL),link(false),monitor(true)]),
    supervisor_actor:supervisor_count_children(Empty,Counts),memberchk(active-0,Counts),
    stop_supervisor(Empty),
    supervisor_actor:supervisor_spawn(swi_supervisor_compat:[
        child(sourced,[start(swi_source_waiter),restart(temporary)])],Sup,
        [node(URL),name(swi_sourced_supervisor),link(false),monitor(true),src_text('swi_source_waiter :- receive({finish -> true}).')]),
    supervisor_actor:supervisor_count_children(Sup,More),memberchk(active-1,More),
    stop_supervisor(Sup),
    writeln('Native SWI remote supervisor constructor -> Trealla: ok').
swi_source_waiter :- receive({finish -> true}).

% A normal down may overtake the reply; supervisor_halt must handle it itself.
% This check requires the acknowledgement and never accepts supervisor_down.
stop_supervisor(Sup) :-
    supervisor_actor:supervisor_halt(Sup),
    actors:receive({down(Sup,_,true) -> true},[timeout(5),on_timeout(fail)]).

% Exercise the public wire independently of native distribution's bookkeeping.
wire_checks(URL) :-
    atom_concat(URL,'/ws',WSURL),
    setup_call_cleanup(websocket:http_open_websocket(WSURL,WS,[]),
        wire_cases(WS),catch(websocket:ws_close(WS,1000,"done"),_,true)).
wire_cases(WS) :-
    wire_case(WS,_{command:spawn,goal:"receive({stop -> true})",request_id:"actor-1"},spawned,"actor-1",A),
    wire_case(WS,_{command:toplevel_spawn,request_id:"session-2"},spawned,"session-2",_),
    wire_case(WS,_{command:spawn,goal:"shell(true)",request_id:"sandbox-3"},error,"sandbox-3",_),
    wire_case(WS,_{command:spawn,goal:"true",options:"[unknown(1)]",request_id:"options-4"},error,"options-4",_),
    wire_case(WS,_{command:toplevel_spawn,options:"[time_limit(0)]",request_id:"options-5"},error,"options-5",_),
    wire_case(WS,_{command:spawn,goal:"true",options:"[src_text('broken( .')]",request_id:"startup-6"},error,"startup-6",_),
    wire_case(WS,_{command:toplevel_spawn,options:"[src_text('broken( .')]",request_id:"startup-7"},error,"startup-7",_),
    wire_case(WS,_{command:spawn,goal:"true",request_id:42},error,legacy,_),
    wire_case(WS,_{command:spawn,goal:"receive({stop -> true})"},spawned,legacy,_),
    wire_case(WS,_{command:toplevel_spawn},spawned,legacy,_),
    wire_case(WS,_{command:spawn,goal:"shell(true)"},error,legacy,_),
    % Monitor notifications remain untagged even for a correlated spawn.
    websocket:ws_send(WS,json(_{command:exit,pid:A.pid,reason:"kill"})),
    next_down(WS,A.pid,Down),\+get_dict(request_id,Down,_),
    writeln('Spawn success/admission/startup errors, legacy replies and monitors: ok').
wire_case(WS,Command,Type,Id,Reply) :-
    websocket:ws_send(WS,json(Command)),next_event(WS,Type,Reply),
    (Id==legacy -> \+get_dict(request_id,Reply,_) ; Reply.request_id==Id).
next_event(WS,Type,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    (Frame.opcode==close -> throw(unexpected_close(Frame))
    ; atom_string(Type,Frame.data.type) -> Reply=Frame.data
    ; next_event(WS,Type,Reply)).

next_down(WS,Pid,Down) :-
    next_event(WS,down,Event),
    (Event.pid==Pid -> Down=Event ; next_down(WS,Pid,Down)).

named_checks(URL) :-
    Name=swi_named_supervisor,
    supervisor_actor:supervisor_spawn([],Sup,[node(URL),name(Name),link(false),monitor(true)]),
    actors:whereis(Name,Sup),
    catch(supervisor_actor:supervisor_spawn([],_,[node(URL),name(Name),link(false)]),Duplicate,true),
    Duplicate==name_is_in_use(Name),
    supervisor_actor:supervisor_count_children(Sup,Counts),memberchk(active-0,Counts),
    stop_supervisor(Sup),actors:whereis(Name,undefined),
    % A rejected source must release the alias; the same name can be reused.
    catch(supervisor_actor:supervisor_spawn([],_,[node(URL),name(Name),link(false),src_text('broken( .')]),Failed,true),
    Failed=error(remote_spawn_failed(Reason),_),
    Reason\==uncorrelated_spawn_reply,Reason\==connection_closed,
    actors:whereis(Name,undefined),
    supervisor_actor:supervisor_spawn([],Again,[node(URL),name(Name),link(false),monitor(true)]),
    actors:whereis(Name,Again),stop_supervisor(Again),actors:whereis(Name,undefined),
    writeln('Native SWI named creation, duplicate rejection, failed-start reuse and monitors: ok').

halt_cycle(URL) :-
    supervisor_actor:supervisor_spawn([],Sup,[node(URL),link(false),monitor(true)]),
    stop_supervisor(Sup).
