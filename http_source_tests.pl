% SPDX-License-Identifier: MIT
:- module(http_source_tests,[run/1]).
:- use_module(rpc).
:- use_module(node).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(library(json)).
:- use_module(resource_policy).
:- use_module(library(http)).
:- use_module(library(uri),[www_form_encode/2]).
:- dynamic produced/1.
:- multifile actors:hook_spawn_reserved/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),assertz(http_source_tests:produced(Pid)).

run(Port) :-
    private_cache,admission,cleanup,
    thread_create(node:node(Port,none,[bind_address('127.0.0.1'),
       profile(actor),sandbox(blacklist),auth(open),time_limit(1)]),Listener,[]),
    setup_call_cleanup(wait_listening(Port,100),live(Port),
      (stop_node(Port),thread_join(Listener,Status),(Status==true;Status==false))),
    all_stopped,\+node:http_page_claim(_,_),\+node:cache(_,_,_,_),
    receive({_ -> fail},[timeout(0)]),
    note('HTTP private sources: all regressions passed').

prepared(Mode,Profile,Goal,Text,G,S) :-
    node:prepare_http_goal(Mode,Profile,Goal,Text,G,S).
page_goal(Mode,Profile,Goal,Text,Template,Once,Answer) :-
    prepared(Mode,Profile,Goal,Text,G,S),
    node:compute_answer(G,Template,0,10,Once,S,Answer).
all_stopped :- forall(produced(Pid),
    (\+actors:actor_thread(Pid,_),\+isolation:actor_module(Pid,_))).
wait_listening(Port,N) :-
    (node_running(Port) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_listening(Port,Next)).

private_cache :-
    Text='q(a). q(b). q(c).',
    prepared(blacklist,actor,q(X),Text,G,S),
    node:compute_answer(G,X,0,1,false,S,success([a],true)),
    node:http_goal_id(G,X,S,Key),node:cache(Key,1,Pid,_),
    isolation:actor_source_module(Pid,Module),
    prepared(whitelist,actor,q(W),Text,White,WhiteSource),
    node:http_goal_id(White,W,WhiteSource,WhiteKey),WhiteKey\==Key,
    % once(true) gets its own source environment and leaves the cached one.
    node:compute_answer(G,X,0,1,true,S,success([a],false)),
    node:cache(Key,1,Pid,_),
    % Same query shape, different source: never reuse the first continuation.
    prepared(blacklist,actor,q(Y),'q(x). q(y). q(z).',H,T),
    node:compute_answer(H,Y,1,1,false,T,success([y],true)),
    node:http_goal_id(H,Y,T,Other),Other\==Key,
    node:cache(Other,2,OtherPid,_),OtherPid\==Pid,
    node:compute_answer(G,X,1,10,false,S,success([b,c],false)),
    \+isolation:actor_module(Pid,Module),
    node:compute_answer(H,Y,2,10,false,T,success([z],false)),
    % A source-free request cannot see either private q/1 definition.
    catch(node:compute_answer(q(_),true,0,1,true,_),E,true),
    E=error(existence_error(procedure,_),_),all_stopped,
    note('cache identities separate sources; continuation keeps and retires its private module: ok').

admission :-
    forall(member(Mode,[blacklist,whitelist]),
      (page_goal(Mode,isobase,q(X),'q(a). q(b).',X,false,success([a,b],false)),
       page_goal(Mode,actor,q(X),'q(pair(A,A)).',X-X,true,
                 success([pair(V,V)-pair(V,V)],false)),var(V),var(X),
       catch(prepared(Mode,actor,q,'q :- open(bad,write,_).',_,_),E,true),
       nonvar(E),
       catch(page_goal(Mode,actor,q,
          'q :- G = open(bad,write,_), call(G).',true,false,_),Runtime,true),
       nonvar(Runtime),all_stopped)),
    page_goal(blacklist,actor,q(X),
      ':- dynamic item/1. q(X) :- assertz(item(ok)), item(X).',X,true,
      success([ok],false)),
    catch(prepared(blacklist,relation,true,'q(a).',_,_),Relation,true),nonvar(Relation),
    catch(prepared(blacklist,actor,q,'q(.',_,_),Syntax,true),nonvar(Syntax),
    setup_call_cleanup(configure_resource_policy([max_source_text_bytes(4)],_),
      (catch(prepared(blacklist,actor,q,'q(ok).',_,_),Size,true),nonvar(Size)),
      configure_resource_policy([],_)),
    % Text containing a blocked directive must not create a producer at all.
    findall(P,produced(P),Before),
    catch(prepared(blacklist,actor,q,':- initialization(true). q.',_,_),D,true),nonvar(D),
    findall(P,produced(P),Before),all_stopped,
    note('both sandbox modes, ISOBASE, shared variables, private mutation, syntax/size/directive rejection: ok').

cleanup :-
    page_goal(blacklist,actor,q,'q :- fail.',true,false,failure),
    catch(page_goal(blacklist,actor,q,'q :- throw(source_error).',true,false,_),E,true),
    E==source_error,
    setup_call_cleanup(configure_resource_policy([time_limit(0.1)],_),
      (catch(page_goal(blacklist,actor,q,'q :- between(1,100,_), sleep(0.02).',true,false,_),Timeout,true),
       Timeout=error(resource_error(time),_)),configure_resource_policy([],_)),
    all_stopped,note('failure, exception and deadline reclaim source namespaces and producers: ok').

live(Port) :-
    page(Port,'q(X)','X-X','q(a). q(b). q(c).',0,2,
         success([a-a,b-b],true)),
    page(Port,'q(X)','X-X','q(a). q(b). q(c).',2,2,
         success([c-c],false)),
    page(Port,'q(X)','X','q(pair(A,A)).',0,2,
         success([pair(V,V)],false)),var(V),
    page(Port,'q(X)','X','q(other).',0,2,success([other],false)),
    page(Port,'q(X)','X','',0,2,error(error(existence_error(procedure,_),_))),
    page(Port,'q','true','q :- open(bad,write,_).',0,2,error(_)),
    format(atom(Base),'http://127.0.0.1:~w',[Port]),
    findall(X,rpc:rpc(Base,q(X),[src_list([q(a),q(b),q(c)]),limit(2)]),[a,b,c]),
    rpc:promise(Base,q(X),Ref,[src_text('q(ok).'),template(pair(X,X))]),
    rpc:yield(Ref,success([pair(ok,ok)],false)),var(X),
    www_form_encode('(q(X))',JsonGoal),www_form_encode('q(ok).',JsonSource),
    format(atom(JsonURL),'~w/call?goal=~w&src_text=~w&format=json',
           [Base,JsonGoal,JsonSource]),
    setup_call_cleanup(http_open(JsonURL,JsonStream,[timeout(3)]),
                       getline(JsonStream,Chars),close(JsonStream)),
    phrase(json_chars(pairs(Pairs)),Chars),
    member(string("data")-list([pairs([string("X")-string("ok")])]),Pairs),
    all_stopped,note('public HTTP/RPC/promise source loading, JSON, paging, isolation and sharing: ok').
page(Port,Goal,Template,Text,Offset,Limit,Answer) :-
    format(atom(G0),'(~w)',[Goal]),format(atom(T0),'(~w)',[Template]),
    www_form_encode(G0,G),www_form_encode(T0,T),www_form_encode(Text,S),
    format(atom(URL),'http://127.0.0.1:~w/call?goal=~w&template=~w&src_text=~w&offset=~w&limit=~w',
           [Port,G,T,S,Offset,Limit]),
    setup_call_cleanup(http_open(URL,Stream,[timeout(3)]),
                       read_term(Stream,Answer,[]),close(Stream)).

note(Message) :- writeln(Message),flush_output.
