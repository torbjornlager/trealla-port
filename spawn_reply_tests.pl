% SPDX-License-Identifier: MIT
:- module(spawn_reply_tests,[run/0]).
:- use_module(web_prolog,[]).
run :-
    web_prolog:json_atom(J,'{"request_id":"first"}'),
    web_prolog:spawn_reply_context(spawn,J,request(first)),
    web_prolog:spawn_reply_context(toplevel_spawn,J,request(first)),
    web_prolog:spawn_reply_context(send,J,legacy),
    web_prolog:spawn_reply_context(spawn,pairs([]),legacy),
    web_prolog:json_atom(Bad,'{"request_id":42}'),
    catch(web_prolog:spawn_reply_context(spawn,Bad,_),E,true),
    E=error(type_error(string,number(42)),_),
    web_prolog:answer_event_json('$spawn_reply'(request(first),spawned(123)),false,A),
    web_prolog:json_text_field(A,request_id,first),
    web_prolog:json_text_field(A,type,spawned),
    web_prolog:answer_event_json('$spawn_reply'(request(second),error(test_error)),true,B),
    web_prolog:json_text_field(B,request_id,second),
    web_prolog:json_text_field(B,type,error),
    web_prolog:answer_event_json('$spawn_reply'(legacy,spawned(123)),false,C),
    \+web_prolog:json_field(C,request_id,_),
    web_prolog:answer_event_json('$spawn_reply'(legacy,error(test_error)),true,D),
    \+web_prolog:json_field(D,request_id,_),
    writeln('Per-command spawn reply IDs, errors and legacy encodings: ok').
