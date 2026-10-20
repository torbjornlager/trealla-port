% SPDX-License-Identifier: MIT
:- module(http_once_tests,[run/1,live/1]).
:- use_module(node).
:- use_module(actors).
:- use_module(resource_policy).
:- use_module(library(http)).
:- use_module(library(uri),[www_form_encode/2]).
:- use_module(library(json)).
:- dynamic produced/1.
:- multifile actors:hook_spawn_reserved/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),assertz(http_once_tests:produced(Pid)).

run(Port) :-
    boundary,sharing,cache_isolation,monitor_isolation,terminal_cleanup,deadlines,
    format(atom(URL),'http://127.0.0.1:~w',[Port]),
    thread_create(node:node(Port,none,[bind_address('127.0.0.1'),
       profile(actor),auth(open),time_limit(2)]),Listener,[]),
    setup_call_cleanup(wait_listening(Port,100),(live(URL),validation(URL)),
      (stop_node(Port),thread_join(Listener,Status),(Status==true;Status==false))),
    all_stopped,\+node:http_page_claim(_,_),\+node:cache(_,_,_,_),
    receive({_ -> fail},[timeout(0)]),
    writeln('HTTP server once: all regressions passed').

all_stopped :- forall(produced(Pid),\+actors:actor_thread(Pid,_)).
wait_listening(Port,N) :-
    (node_running(Port) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_listening(Port,Next)).

% The third/fourth alternatives must never be evaluated, even eagerly.
boundary :-
    self(Self),
    node:compute_answer((X=a;X=b;send(Self,beyond_slice),throw(beyond_slice)),
                        X,0,2,true,success([a,b],false)),
    node:compute_answer((Y=a;Y=b;Y=c;send(Self,beyond_slice),receive({never -> true})),
                        Y,2,1,true,success([c],false)),
    receive({beyond_slice -> fail},[timeout(0)]),all_stopped,
    writeln('first slice and offset stop before side effects, exceptions or blocking alternatives: ok').

sharing :-
    node:compute_answer(member(X,[pair(V,V),pair(V,V),other]),X-V,0,2,true,Answer),
    Answer=success([pair(A,A)-A,pair(B,B)-B],false),var(A),var(B),var(X),var(V),
    all_stopped,writeln('non-ground template/goal sharing is preserved: ok').

cache_isolation :-
    Goal=member(X,[cached_a,cached_b,cached_c,cached_d]),
    node:compute_answer(Goal,X,0,2,success([cached_a,cached_b],true)),
    node:goal_id(Goal-X,Gid),node:cache(Gid,2,Pid,Lookahead),
    findall(cache(G,O,P,L),node:cache(G,O,P,L),Before),
    node:compute_answer(Goal,X,2,1,true,success([cached_c],false)),
    findall(cache(G,O,P,L),node:cache(G,O,P,L),Before),
    node:cache(Gid,2,Pid,Lookahead),actors:actor_thread(Pid,_),
    node:compute_answer(Goal,X,2,2,success([cached_c,cached_d],false)),all_stopped,
    writeln('same-goal ordinary continuation retains its pid, offset and lookahead: ok').

monitor_isolation :-
    self(Parent),spawn_runtime(http_once_tests:request(Parent),Request,
      [monitor(true),link(false),'$entry_context'(caller)]),
    receive({once_producer(Pid) -> true},[timeout(3),on_timeout(fail)]),
    monitor(Pid,Ref),send(Parent,'$http_page_reply'(unrelated,sol(keep))),
    send(Pid,continue),
    receive({once_result(Answer) -> Answer==success([a,b],false)},
            [timeout(3),on_timeout(fail)]),
    \+actors:actor_thread(Pid,_),
    receive({down(Pid,Ref,_) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(Request,Request,true) -> true},[timeout(2),on_timeout(fail)]),
    receive({'$http_page_reply'(unrelated,sol(keep)) -> true},[timeout(0),on_timeout(fail)]),
    writeln('producer is retired before return; application monitor and unrelated reply survive: ok').
request(Parent) :-
    node:compute_answer(http_once_tests:blocked(Parent,X),X,0,2,true,Answer),
    send(Parent,once_result(Answer)).
blocked(Parent,X) :-
    self(Pid),send(Parent,once_producer(Pid)),receive({continue -> true}),
    member(X,[a,b,c]).

terminal_cleanup :-
    node:compute_answer(fail,x,0,2,true,failure),
    node:compute_answer(true,ok,0,2,true,success([ok],false)),
    node:compute_answer(member(X,[a]),X,3,2,true,failure),
    catch(node:compute_answer(throw(once_error),x,0,2,true,_),Error,true),
    Error==once_error,
    \+node:compute_answer(true,ok,0,1,true,wrong),
    all_stopped,writeln('failure, short slices, offsets past end, errors and output mismatch reclaim producers: ok').

slow(X) :- between(1,20,X),sleep(0.05).
deadlines :-
    setup_call_cleanup(configure_resource_policy([time_limit(0.2)],_),
      (catch(node:compute_answer(http_once_tests:slow(X),X,0,10,true,_),E1,true),
       nonvar(E1),E1=error(resource_error(time),_),all_stopped,
       catch(node:compute_answer(http_once_tests:slow(Y),Y,10,2,true,_),E2,true),
       nonvar(E2),E2=error(resource_error(time),_),all_stopped,
       catch(node:compute_answer(sleep(0.5),true,0,1,true,_),E3,true),
       nonvar(E3),E3=error(resource_error(time),_),all_stopped),
      reset_resource_policy),
    writeln('collection and skipping retain the whole-page deadline and cleanup: ok').

% Public HTTP checks can also run unchanged against native SWI.
live(URL) :-
    page(URL,'member(X,[a,b,c,d,e])','X',0,2,'&once=true',
         success([a,b],false)),
    page(URL,'member(X,[a,b,c,d,e])','X',2,2,'&once=true',
         success([c,d],false)),
    page(URL,'(X=a;X=b;throw(after_slice))','X',0,2,'&once=true',
         success([a,b],false)),
    page(URL,'fail','true',0,2,'&once=true',failure),
    page(URL,'throw(once_error)','true',0,2,'&once=true',error(once_error)),
    page(URL,'member(X,[a,b,c,d,e])','X',0,2,'&once=false',success([a,b],true)),
    page(URL,'member(X,[a,b,c,d,e])','X',2,3,'',success([c,d,e],false)),
    request_url(URL,'member(X,[a,b,c])','X',0,2,'&once=true&format=json',JSONURL),
    setup_call_cleanup(http_open(JSONURL,S,[timeout(3)]),getline(S,Chars),close(S)),
    phrase(json_chars(pairs(Pairs)),Chars),
    member(string("type")-string("success"),Pairs),
    member(string("more")-boolean(false),Pairs),
    member(string("data")-list([_,_]),Pairs),
    format('HTTP once Prolog/JSON, offset, failure/error and ordinary paging on ~w: ok~n',[URL]).

validation(URL) :-
    page(URL,'true','true',0,1,'&once=bad',
         error(error(domain_error(boolean,bad),_))),
    page(URL,'true','true',0,1,'&once=true&once=bad',
         error(error(domain_error(boolean,bad),_))),
    page(URL,'member(X,[first,second])','X',0,1,'&once=true&once=false',
         success([first],false)),
    writeln('HTTP once validates every occurrence and preserves first-value precedence: ok').

page(URL,Goal,Template,Offset,Limit,Options,Answer) :-
    atom_concat(Options,'&format=prolog',PrologOptions),
    request_url(URL,Goal,Template,Offset,Limit,PrologOptions,Request),
    setup_call_cleanup(http_open(Request,S,[timeout(3)]),read_term(S,Answer,[]),close(S)).
request_url(URL,Goal,Template,Offset,Limit,Options,Request) :-
    www_form_encode(Goal,G),www_form_encode(Template,T),
    format(atom(Request),'~w/call?goal=~w&template=~w&offset=~w&limit=~w~w',
           [URL,G,T,Offset,Limit,Options]).
