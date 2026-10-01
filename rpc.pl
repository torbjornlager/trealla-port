% SPDX-License-Identifier: MIT

:- module(rpc,
       [ rpc/2,                  % +URI, :Goal
         rpc/3,                  % +URI, :Goal, +Options
         promise/3,              % +URI, :Goal, -Reference
         promise/4,              % +URI, :Goal, -Reference, +Options
         promise_cleanup/1,      % +Reference
         yield/2,                % +Reference, -Answer
         yield/3                 % +Reference, -Answer, +Options
       ]).

/** <module> RPC -- simple HTTP-based remote Prolog calls

Client-side wrapper around the node `/call` endpoint.  A goal is
serialised into URL query parameters, sent to a remote node, and its
solutions are yielded back to the caller one by one on backtracking.

When the first answer reports that more solutions exist, rpc/2-3
automatically fetches the next page (with an incremented offset) until
all solutions have been consumed or the caller stops backtracking.

## Examples {#rpc-examples}

```prolog
?- rpc('http://localhost:3060', member(X, [a,b,c])).
X = a ;
X = b ;
X = c.

% The following example tests whether server-side caching is in effect:
% the sleep/1 should only fire once regardless of how many pages are fetched.

?- rpc('http://localhost:3060', (sleep(2), X=a ; X=b), [limit(1)]).
X = a ;
X = b.
```

## Protocol {#rpc-protocol}

rpc/2,3 extracts the variables from Goal, wraps them in a `v(...)` template,
and sends both `goal` and `template` as URL-encoded atoms to the node.
The node returns `success(Slice, More)`, `failure`, or `error(E)` as a
quoted Prolog term.  rpc/2,3 then unifies the template with each element of
Slice in turn, yielding solutions one by one.  When More=true the next page
is fetched automatically on backtracking.

## Trealla port notes {#rpc-trealla}

  - The request URL is assembled from the base URI and handed directly to
    the current `http_open/3`. This avoids Trealla's removed private
    `'$parse_url'/2` predicate.
  - `http_open/3` is wrapped in `once/1`: the current implementation leaves
    internal socket-opening choicepoints that must not be revisited while
    rpc/3 yields remote answers on backtracking.
  - The response body is read with getline/2, which reads one line.
    This works because the node sends the entire answer on a single
    line ending with `.\n`.  Multi-line terms in the response would be
    truncated.
  - Goal and template atoms are URL-percent-encoded before embedding in
    the query string.

@author Torbjorn Lager
*/


:- use_module(library(http)).
:- use_module(actors, [self/1,make_ref/1]).
:- use_module(isolation, [actor_source_module/2,load_options_text/3]).

:- dynamic promise_queue_store/2.

:- meta_predicate
    rpc(+, :),
    rpc(+, :, +),
    promise(+, :, -),
    promise(+, :, -, +).


                /*******************************
                *         URL ENCODING        *
                *******************************/

%!  url_encode(+Plain, -Encoded) is det.
%
%   Percent-encode an atom for safe embedding as a URL query-parameter
%   value.  Unreserved characters (A-Z, a-z, 0-9, `-`, `_`, `.`, `~`)
%   are passed through unchanged; all other characters are replaced by
%   `%XX` where XX is the uppercase hexadecimal byte value.

url_encode(Plain, Encoded) :-
    atom_chars(Plain, Chars),
    maplist(encode_char, Chars, Parts),
    atomic_list_concat(Parts, Encoded).

%!  encode_char(+Char, -Encoded) is det.
%
%   Encode a single character.  Unreserved characters pass through;
%   everything else is encoded as `%XX`.

encode_char(C, E) :-
    char_code(C, Code),
    (   unreserved_code(Code)
    ->  E = C
    ;   Hi is Code >> 4,  Lo is Code /\ 0xf,
        hex_digit(Hi, D1), hex_digit(Lo, D2),
        atom_chars(E, ['%', D1, D2])
    ).

%!  unreserved_code(+Code) is semidet.
%
%   True if Code is an unreserved URL character (RFC 3986):
%   A-Z (65-90), a-z (97-122), 0-9 (48-57), `-` (45), `_` (95),
%   `.` (46), `~` (126).

unreserved_code(C) :-
    ( C >= 65, C =< 90  -> true   % A-Z
    ; C >= 97, C =< 122 -> true   % a-z
    ; C >= 48, C =< 57  -> true   % 0-9
    ; memberchk(C, [45, 95, 46, 126])  % - _ . ~
    ).

%!  hex_digit(+N, -Digit) is det.
%
%   Convert an integer 0-15 to its uppercase hexadecimal digit character.

hex_digit(N, D) :-
    ( N < 10 -> Ch is N + 48 ; Ch is N - 10 + 65 ),
    char_code(D, Ch).


                /*******************************
                *         URI PARSING         *
                *******************************/

%!  base_path_prefix(+ParseUrlPath, -Prefix) is det.
%
%   Convert the `path(...)` element returned by parse_url/2 (which
%   always begins with `/`) into the prefix that precedes
%   `call?...` in the request path, with no leading `/` (http_open
%   adds it back) and a trailing `/` when non-empty.
%
%     '/'        -> ''        (root: just "call?...")
%     '/api'     -> 'api/'
%     '/api/'    -> 'api/'
%     '/a/b/c'   -> 'a/b/c/'

base_path_prefix('/', '') :- !.
base_path_prefix(BasePath, Prefix) :-
    atom_chars(BasePath, ['/'|Cs]),
    (   append(_, ['/'], Cs)
    ->  atom_chars(Prefix, Cs)
    ;   atom_chars(P0, Cs), atom_concat(P0, '/', Prefix)
    ).


                /*******************************
                *             RPC             *
                *******************************/

%!  rpc(+URI, :Goal) is nondet.
%!  rpc(+URI, :Goal, +Options) is nondet.
%
%   Call Goal against the node identified by URI, yielding solutions
%   one at a time on backtracking.  URI is an atom such as
%   `'http://localhost:3060'`.  Options:
%
%     - limit(+Positive)
%       Maximum number of solutions to fetch per HTTP request (page
%       size).  Smaller values yield more requests but lower latency
%       per solution.  Default: a very large number (effectively no
%       paging).
%     - timeout(+Seconds), request_header(+Name=Value), and the remaining
%       Trealla `http_open/3` client options are forwarded to the transport.
%       The HTTP library parses `https://` when Trealla is built with TLS;
%       hostname verification remains subject to BUG-005 in
%       `UPSTREAM_REPORTS.md`.
%     - src_text(+Text), src_list(+Terms), src_predicates(+PIs), src_uri(+URI)
%       Materialize application code locally and send it as the request's
%       src_text payload. src_uri fetching remains subject to source_policy.
%
%   The goal's free variables are collected with term_variables/2 and
%   wrapped in a `v(...)` template.  Both goal and template are
%   pretty-printed with `~q` (quoted, wrapped in parentheses to
%   preserve operator structure) and URL-encoded before embedding in
%   the query string.

rpc(URI, Goal) :-
    rpc(URI, Goal, []).

rpc(URI, Goal0, Options) :-
    strip_module(Goal0, _, Goal),
    term_variables(Goal, Vars),
    Template =.. [v|Vars],
    format(atom(GoalAtom),     "(~q)", [Goal]),
    format(atom(TemplateAtom), "(~q)", [Template]),
    option(limit(Limit), Options, 10000000000),
    rpc_source_module(SourceModule),
    load_options_text(SourceModule, Options, LoadText),
    rpc_page(Template, 0, Limit, GoalAtom, TemplateAtom, URI, Options,
             LoadText).

rpc_source_module(Module) :-
    self(Pid),
    actor_source_module(Pid, Module),
    !.
rpc_source_module(user).


%!  rpc_page(+Template, +Offset, +Limit, +GoalAtom, +TemplateAtom,
%!           +BaseURI, +Options) is nondet.
%
%   Fetch one page of results from the node and yield each solution.
%   On backtracking after the last solution on this page, fetches the
%   next page (if More=true) by recursing with Offset incremented by
%   Limit.

rpc_page(Template, Offset, Limit, GoalAtom, TemplateAtom, BaseURI, Options,
         LoadText) :-
    url_encode(GoalAtom,     GoalEnc),
    url_encode(TemplateAtom, TemplEnc),
    strip_trailing_slash(BaseURI, RootURI),
    format(atom(URL0),
           '~w/call?goal=~w&template=~w&offset=~w&limit=~w&format=prolog',
           [RootURI, GoalEnc, TemplEnc, Offset, Limit]),
    rpc_source_url(URL0, LoadText, URL),
    rpc_http_options(Options, HTTPOptions),
    once(http_open(URL, S, HTTPOptions)),
    setup_call_cleanup(true, getline(S, BodyChars), close(S)),
    atom_chars(BodyAtom, BodyChars),
    read_term_from_atom(BodyAtom, Answer, []),
    rpc_answer(Answer, Template, Offset, Limit,
               GoalAtom, TemplateAtom, BaseURI, Options, LoadText).

rpc_source_url(URL, '', URL) :- !.
rpc_source_url(URL0, LoadText, URL) :-
    url_encode(LoadText, Encoded),
    format(atom(URL), '~w&src_text=~w', [URL0, Encoded]).

strip_trailing_slash(URI, Root) :-
    atom_concat(Root0, '/', URI), !,
    strip_trailing_slash(Root0, Root).
strip_trailing_slash(URI, URI).

rpc_http_options([], []).
rpc_http_options([limit(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([template(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([offset(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([once(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([src_text(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([src_list(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([src_predicates(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([src_uri(_)|Options], HTTPOptions) :- !,
    rpc_http_options(Options, HTTPOptions).
rpc_http_options([Option|Options], [Option|HTTPOptions]) :-
    rpc_http_options(Options, HTTPOptions).


%!  rpc_answer(+Answer, +Template, +Offset, +Limit, ...) is nondet.
%
%   Dispatch on the answer term received from the node:
%
%     - `success(Slice, true)` -- yield each solution in Slice via
%       member/2, then on backtracking fetch the next page.
%     - `success(Slice, false)` -- yield each solution in Slice via
%       member/2; no further pages.
%     - `failure` -- no solutions; fail.
%     - `error(Error)` -- re-throw Error.

rpc_answer(success(Slice, true), Template, Offset, Limit,
           GoalAtom, TemplateAtom, BaseURI, Options, LoadText) :- !,
    (   member(Template, Slice)
    ;   NewOffset is Offset + Limit,
        rpc_page(Template, NewOffset, Limit,
                 GoalAtom, TemplateAtom, BaseURI, Options, LoadText)
    ).
rpc_answer(success(Slice, false), Template, _, _, _, _, _, _, _) :-
    member(Template, Slice).
rpc_answer(failure, _, _, _, _, _, _, _, _) :-
    fail.
rpc_answer(error(Error), _, _, _, _, _, _, _, _) :-
    throw(Error).


                /*******************************
                *       PROMISE AND YIELD      *
                *******************************/

%!  promise(+URI, :Goal, -Reference) is det.
%!  promise(+URI, :Goal, -Reference, +Options) is det.
%
%   Start one stateless HTTP RPC request in a detached Trealla thread. The
%   complete protocol answer is placed in a private message queue and can be
%   collected later with yield/2-3. A timed-out yield deliberately retains
%   the mapping so a later yield can still collect the answer.

promise(URI, Goal, Reference) :-
    promise(URI, Goal, Reference, []).

promise(URI, Goal0, Reference, Options) :-
    strip_module(Goal0, _, Goal),
    option(template(Template), Options, Goal),
    option(offset(Offset), Options, 0),
    option(limit(Limit), Options, 10000000000),
    integer(Offset), Offset >= 0,
    integer(Limit), Limit > 0,
    format(atom(GoalAtom), "(~q)", [Goal]),
    format(atom(TemplateAtom), "(~q)", [Template]),
    rpc_source_module(SourceModule),
    load_options_text(SourceModule, Options, LoadText),
    rpc_http_options(Options, HTTPOptions),
    make_ref(Reference),
    message_queue_create(Queue),
    assertz(promise_queue_store(Reference, Queue)),
    thread_create(rpc:promise_worker(URI, GoalAtom, TemplateAtom,
                                     Offset, Limit, LoadText,
                                     HTTPOptions, Queue),
                  _, [detached(true)]),
    thread_create(rpc:promise_auto_cleanup(Reference, 300),
                  _, [detached(true)]),
    !.

promise_worker(URI, GoalAtom, TemplateAtom, Offset, Limit, LoadText,
               HTTPOptions, Queue) :-
    catch(rpc_fetch_answer(URI, GoalAtom, TemplateAtom, Offset, Limit,
                           LoadText, HTTPOptions, Answer),
          Error,
          Answer = error(Error)),
    catch(thread_send_message(Queue, Answer), _, true).

rpc_fetch_answer(BaseURI, GoalAtom, TemplateAtom, Offset, Limit, LoadText,
                 HTTPOptions, Answer) :-
    url_encode(GoalAtom, GoalEnc),
    url_encode(TemplateAtom, TemplateEnc),
    strip_trailing_slash(BaseURI, RootURI),
    format(atom(URL0),
           '~w/call?goal=~w&template=~w&offset=~w&limit=~w&format=prolog',
           [RootURI, GoalEnc, TemplateEnc, Offset, Limit]),
    rpc_source_url(URL0, LoadText, URL),
    once(http_open(URL, Stream, HTTPOptions)),
    setup_call_cleanup(true, getline(Stream, BodyChars), close(Stream)),
    atom_chars(BodyAtom, BodyChars),
    read_term_from_atom(BodyAtom, Answer, []).

promise_auto_cleanup(Reference, Seconds) :-
    sleep(Seconds),
    retractall(promise_queue_store(Reference, _)).

promise_cleanup(Reference) :-
    must_be(integer, Reference),
    retractall(promise_queue_store(Reference, _)).

%!  yield(+Reference, -Answer) is semidet.
%!  yield(+Reference, -Answer, +Options) is semidet.
%
%   Wait for a promise answer. Supported waiting options mirror receive/2:
%   timeout(+Seconds) and on_timeout(+Goal). A timeout does not consume or
%   cancel the promise.

yield(Reference, Answer) :-
    must_be(integer, Reference),
    promise_queue_store(Reference, Queue),
    thread_get_message(Queue, Answer),
    retract(promise_queue_store(Reference, Queue)),
    !.

yield(Reference, Answer, Options) :-
    must_be(integer, Reference),
    must_be(list, Options),
    ( promise_queue_store(Reference, Queue) ->
        option(timeout(Timeout), Options, infinite),
        yield_wait(Timeout, Queue, Message),
        ( Message = '$promise_timeout' ->
            option(on_timeout(OnTimeout), Options, true),
            call(OnTimeout)
        ; Answer = Message,
          retract(promise_queue_store(Reference, Queue))
        )
    ; option(on_timeout(OnTimeout), Options, true),
      call(OnTimeout)
    ),
    !.

yield_wait(infinite, Queue, Message) :- !,
    thread_get_message(Queue, Message).
yield_wait(Timeout, Queue, Message) :-
    number(Timeout), Timeout >= 0,
    ( thread_get_message(Queue, Message0, [timeout(Timeout)]) ->
        Message = Message0
    ; Message = '$promise_timeout'
    ).
