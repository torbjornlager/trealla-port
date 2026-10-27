% SPDX-License-Identifier: MIT
:- module(http_paging_offset_tests,[run/1]).
:- use_module(actors).
:- use_module(rpc).
:- use_module(node).
:- dynamic produced/1.
:- multifile actors:hook_spawn_reserved/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),
    assertz(http_paging_offset_tests:produced(Pid)).

run(Port) :-
    cache_offsets,
    format(atom(URL),'http://127.0.0.1:~w',[Port]),
    thread_create(node:node(Port,http_paging_offset_tests:unused,
      [bind_address('127.0.0.1'),node_url(URL),profile(actor),auth(open),
       time_limit(5)]),Listener,[]),
    setup_call_cleanup(wait_listening(Port,100),
      (retractall(produced(_)),
       findall(X,rpc:rpc(URL,X=ok,[limit(1)]),[ok]),
       findall(A-B,rpc:rpc(URL,(A=left,B=right),[limit(1)]),[left-right]),
       writeln('HTTP operator goals and shared template variables: ok'),
       retractall(produced(_)),
       findall(X,rpc:rpc(URL,member(X,[a,b,c,d,e]),[limit(2)]),Answers),
       Answers==[a,b,c,d,e],
       findall(P,produced(P),Pids),Pids=[Only],
       \+actors:actor_thread(Only,_),
       writeln('HTTP paging returns every answer and reuses one producer: ok'),
       % Model a peer's already-received short non-final page. This can arise
       % before a pending error; it does not depend on this node clamping pages.
       findall(V,rpc:rpc_answer(success([a,b],true),V,0,5,
         'member(X,[a,b,c,d,e])','X',URL,[],''),All),
       All==[a,b,c,d,e],
       % Nonzero starting offset: the short initial page is already received.
       findall(T,rpc:rpc_answer(success([b],true),T,1,5,
         'member(X,[a,b,c,d,e])','X',URL,[],''),Tail),
       Tail==[b,c,d,e],
       writeln('short page at a nonzero offset advances by its actual length: ok')),
      (stop_node(Port),thread_join(Listener,Status),(Status==true;Status==false))),
    node_connection_count(Port,0),
    forall(produced(Pid),\+actors:actor_thread(Pid,_)),
    writeln('HTTP paging offsets: all regressions passed').

cache_offsets :-
    Goal=member(X,[offset_a,offset_b,offset_c,offset_d,offset_e]),
    node:goal_id(Goal-X,Gid),
    node:compute_answer(Goal,X,0,2,success([offset_a,offset_b],true)),
    node:cache(Gid,2,Pid,lookahead(offset_c)),
    node:compute_answer(Goal,X,2,1,success([offset_c],true)),
    node:cache(Gid,3,Pid,lookahead(offset_d)),
    node:compute_answer(Goal,X,3,5,success([offset_d,offset_e],false)),
    \+node:cache(Gid,_,_,_),\+actors:actor_thread(Pid,_),
    writeln('changing page sizes resumes the same producer at returned-answer offsets: ok').

wait_listening(Port,N) :-
    (node_running(Port) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_listening(Port,Next)).
unused(_,_).
