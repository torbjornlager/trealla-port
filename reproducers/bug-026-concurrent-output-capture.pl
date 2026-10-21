% SPDX-License-Identifier: MIT
% Standalone: no Web Prolog modules, networking or source loading.
:- module(concurrent_output_capture, [run/0]).

run :-
    thread_self(Parent),
    thread_create(concurrent_output_capture:worker(Parent), Child, []),
    thread_get_message(ready),
    with_output_to(atom(MainText),
        ( write(beta),
          thread_send_message(Child, go),
          thread_get_message(wrote) )),
    thread_send_message(Child, finish),
    thread_get_message(result(ChildText)),
    thread_join(Child, true),
    writeq(actual(MainText, ChildText)), nl,
    MainText == beta,
    ChildText == alphaomega.

worker(Parent) :-
    with_output_to(atom(Text),
        ( write(alpha),
          thread_send_message(Parent, ready),
          thread_get_message(go),
          write(omega),
          thread_send_message(Parent, wrote),
          thread_get_message(finish) )),
    thread_send_message(Parent, result(Text)).
