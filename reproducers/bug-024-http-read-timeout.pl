% SPDX-License-Identifier: MIT
:- module(bug_024_http_read_timeout,[reproducer/1]).
:- use_module(library(http)).

% The peer sends nothing for 1.2 seconds. A 0.2-second read timeout
% should interrupt the request rather than return its eventual response.
reproducer(URL) :-
    get_time(Start),
    (catch((setup_call_cleanup(http_open(URL,Stream,[timeout(0.2)]),
                               getline(Stream,Body),close(Stream)),
            Outcome=success(Body)),Error,Outcome=error(Error))
     -> true ; Outcome=failure),
    get_time(End),Elapsed is End-Start,
    format('~q after ~3f seconds~n',[Outcome,Elapsed]).
