% SPDX-License-Identifier: MIT
:- module(page_size_tests,[run/1]).
:- use_module(actors).
:- use_module(rpc).
:- use_module(node).
:- use_module(toplevel_actors).
:- use_module(resource_policy).
:- use_module(library(http)).

run(Port) :-
    retired_setting,
    setup_call_cleanup(configure_resource_policy([time_limit(5)],_),
      (toplevel_pages,toplevel_omitted_limit),reset_resource_policy),
    http_pages(Port),
    writeln('Caller-controlled page sizes: all regressions passed').

retired_setting :-
    current_resource_policy(Before),
    catch(configure_resource_policy([max_solutions(2)],_),Error,true),
    Error=error(domain_error(retired_resource_option,max_solutions),_),
    current_resource_policy(Before),
    effective_solution_limit(2005,2005),
    catch(effective_solution_limit(0,_),Invalid,true),
    Invalid=error(domain_error(limit,0),_),
    writeln('retired max_solutions is rejected without changing policy; positive limits stay valid: ok').

toplevel_pages :-
    self(Self),
    toplevel_spawn(Pid,[target(Self),session(true),link(false)]),
    setup_call_cleanup(true,
      (toplevel_call(Pid,between(1,2005,X),[template(X),limit(1002)]),
       receive({success(Pid,First,true) -> true},[timeout(5),on_timeout(fail)]),
       length(First,1002),First=[1|_],last(First,1002),
       toplevel_next(Pid,[limit(1001)]),
       receive({success(Pid,Second,true) -> true},[timeout(5),on_timeout(fail)]),
       length(Second,1001),Second=[1003|_],last(Second,2003),
       toplevel_next(Pid,[limit(7)]),
       receive({success(Pid,Final,false) -> true},[timeout(5),on_timeout(fail)]),
       Final==[2004,2005]),
      exit(Pid,kill)),
    writeln('PTCP call and next honour sizes above the old default cap and preserve ordering: ok').

toplevel_omitted_limit :-
    self(Self),toplevel_spawn(Pid,[target(Self),session(true),link(false)]),
    setup_call_cleanup(true,
      (toplevel_call(Pid,between(1,1005,X),[template(X)]),
       receive({success(Pid,All,false) -> true},[timeout(5),on_timeout(fail)]),
       length(All,1005),All=[1|_],last(All,1005)),
      exit(Pid,kill)),
    writeln('PTCP omitted limit no longer silently splits at 1000: ok').

http_pages(Port) :-
    format(atom(URL),'http://127.0.0.1:~w',[Port]),
    thread_create(node:node(Port,page_size_tests:unused,
      [bind_address('127.0.0.1'),node_url(URL),profile(actor),auth(open),
       time_limit(5)]),Listener,[]),
    setup_call_cleanup(wait_listening(Port,100),
      (http_page(URL,'&limit=1002',0,success(First,true)),
       length(First,1002),First=[1|_],last(First,1002),
       http_page(URL,'&limit=1500',1002,success(Last,false)),
       length(Last,1003),Last=[1003|_],last(Last,2005),
       http_page(URL,'',0,success(All,false)),
       length(All,2005),All=[1|_],last(All,2005)),
      (stop_node(Port),thread_join(Listener,Status),(Status==true;Status==false))),
    node_connection_count(Port,0),
    writeln('HTTP honours requested sizes and omitted limits; short final pages resume correctly: ok').

http_page(URL,Limit,Offset,Answer) :-
    format(atom(Request),
      '~w/call?goal=between%281%2C2005%2CX%29&template=X&offset=~w&format=prolog~w',
      [URL,Offset,Limit]),
    setup_call_cleanup(http_open(Request,Stream,[]),read_term(Stream,Answer,[]),close(Stream)).
wait_listening(Port,N) :-
    (node_running(Port) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_listening(Port,Next)).
unused(_,_).
