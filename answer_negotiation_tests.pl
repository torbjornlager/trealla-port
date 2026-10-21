% SPDX-License-Identifier: MIT
:- module(answer_negotiation_tests,[run/0]).
:- use_module(web_prolog,[]).

run :-
    \+ node:current_connection_answer_terms(_),
    setup_call_cleanup(true,local_context_checks,node:clear_connection_governance),
    thread_self(Parent),
    setup_call_cleanup(thread_create(answer_negotiation_tests:worker(Parent,true),A,[]),
      setup_call_cleanup(thread_create(answer_negotiation_tests:worker(Parent,false),B,[]),
        (thread_get_message(Parent,ready(A,true),[timeout(3)]),
         thread_get_message(Parent,ready(B,false),[timeout(3)]),
         \+ node:current_connection_answer_terms(_)),
        finish(B)),finish(A)),
    \+ node:current_connection_answer_terms(_),
    writeln('Answer negotiation context, exceptional cleanup and thread isolation: ok').

local_context_checks :-
    node:set_connection_answer_terms([]),node:current_connection_answer_terms(false),
    node:set_connection_answer_terms(['x-web-prolog-protocol'-'1']),
    node:current_connection_answer_terms(true),
    % The header must not establish a principal or grant any capabilities.
    \+ node:current_connection_governance(_,_),
    catch(setup_call_cleanup(true,throw(probe),node:clear_connection_governance),Error,true),
    Error==probe,\+node:current_connection_answer_terms(_),
    node:set_connection_answer_terms([]),node:current_connection_answer_terms(false).

worker(Parent,Enabled) :-
    setup_call_cleanup(true,
      ( (Enabled==true -> Headers=['x-web-prolog-protocol'-'1'] ; Headers=[]),
        node:set_connection_answer_terms(Headers),
        node:current_connection_answer_terms(Value),thread_self(Self),
        thread_send_message(Parent,ready(Self,Value)),
        thread_get_message(Self,release,[timeout(3)]),
        node:current_connection_answer_terms(Enabled)),
      node:clear_connection_governance),
    \+ node:current_connection_answer_terms(_).

finish(Thread) :-
    thread_send_message(Thread,release),thread_join(Thread,Status),Status==true.
