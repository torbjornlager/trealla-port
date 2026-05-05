:- module(node,
       [ node/1                  % +Port
       ]).

/** <module> Node -- simple HTTP endpoint for toplevel queries

Exposes a small HTTP interface for evaluating Prolog goals through a
producer-actor model.  Requests are served at `/call`; the goal and
query options are passed as URL-encoded query parameters.

## Request format {#node-request}

```
GET /call?goal=<Goal>&template=<Template>&offset=<N>&limit=<N>&format=prolog
```

All parameters are URL-percent-encoded Prolog term atoms.  `goal` and
`template` are parsed as a single `Goal+Template` term so that
variables are shared between them (e.g. `goal=member(X,[a,b])&template=X`
correctly binds X in the template to the X in the goal).

Parameters and their defaults:

| Parameter  | Default        | Meaning                                  |
|------------|----------------|------------------------------------------|
| goal       | `''`           | Goal to call                             |
| template   | same as goal   | Term to collect for each solution        |
| offset     | `0`            | Number of solutions to skip              |
| limit      | `1000000000`   | Maximum solutions in this page           |
| format     | `prolog`       | Response format (`prolog` only for now)  |

Empty values for offset or limit are treated as if the parameter were
absent (i.e. the default is used), so URLs like `?offset=&limit=1`
are handled gracefully.

## Response format {#node-response}

The response body is a single Prolog term followed by `.\n`, readable
with `read_term_from_atom/3`:

  - `success(Slice, true).`  -- Slice is a list of Template bindings;
    more solutions exist.
  - `success(Slice, false).` -- Slice is a list of Template bindings;
    this is the final page.
  - `failure.`               -- Goal produced no solutions (for this
    offset/limit window).

## Caching and producer actors {#node-caching}

For paged queries, the server caches *suspended producer actors*
between requests.  A producer actor runs `call(Goal)` and pauses in
`receive({'$request'(C) -> C ! sol(Template) ; '$stop' -> ...})`
after each solution.  Because Trealla's `receive/1` blocks the OS
thread while preserving the complete WAM stack (including all open
choicepoints), the producer's state -- including backtracking
alternatives -- survives across HTTP requests.

When a new request arrives:

1.  The cache is checked for an entry `(GoalId, Offset, ProducerPid,
    Lookahead)`.  A cache hit means there is already a suspended
    producer positioned exactly at Offset with a possible pre-fetched
    solution (Lookahead).
2.  On a cache miss, a fresh producer actor is spawned and the first
    `Offset` solutions are skipped.
3.  Up to `Limit` solutions are collected from the producer.
4.  One extra request is sent to the producer to determine whether
    more solutions exist (the N+1 lookahead probe).
5.  If more exist, the producer is stored back in the cache at
    `Offset + Limit` together with the extra solution as a lookahead.

The cache is bounded by `cache_size/1` (default 100).  When the limit
is reached, the oldest entry is evicted (FIFO).

## Concurrency {#node-concurrency}

The server loop in node_loop/1 handles connections one at a time in
the calling thread.  For a production deployment each connection
should be handled in a separate actor.

## Trealla port notes {#node-trealla}

  - `library(http/thread_httpd)`, `library(http/http_dispatch)`, and
    `library(http/http_parameters)` are absent.  The server is built
    with Trealla's low-level `server/3` + `accept/2` loop, and query
    parameters are parsed manually from the request path.
  - `library(settings)` is absent; cache_size defaults are plain facts.
  - `compute_answer/5` uses `receive/1` (unlimited wait) because
    producer replies are guaranteed: the producer is a local actor
    we just spawned or resumed.  No timeout is needed.
  - `predicate_property(..., number_of_clauses(N))` is absent; the
    cache size is counted with `findall/3`.
  - Only the `prolog` response format is implemented.  Requests for
    `json` receive a brief "not yet implemented" notice.
*/


:- use_module(library(http)).
:- use_module(actors).


                /*******************************
                *           SETTINGS          *
                *******************************/

%!  cache_size(-N) is det.
%
%   Maximum number of suspended producer entries kept in the cache.
%   When the cache exceeds this limit the oldest entry is evicted.

cache_size(100).


                /*******************************
                *          URL DECODING       *
                *******************************/

%!  url_decode_chars(+Chars, -Decoded) is det.
%
%   Decode a URL percent-encoded character list.  Recognised sequences:
%
%     - `%XX` -- replaced by the character with hexadecimal code XX.
%     - `+`   -- replaced by a space character.
%     - other -- passed through unchanged.

url_decode_chars([], []).
url_decode_chars(['%', H1, H2 | Rest], [C | Decoded]) :- !,
    hex_val(H1, V1), hex_val(H2, V2),
    Code is V1 * 16 + V2,
    char_code(C, Code),
    url_decode_chars(Rest, Decoded).
url_decode_chars(['+' | Rest], [' ' | Decoded]) :- !,
    url_decode_chars(Rest, Decoded).
url_decode_chars([C | Rest], [C | Decoded]) :-
    url_decode_chars(Rest, Decoded).

%!  hex_val(+Digit, -Value) is det.
%
%   Convert a single hex digit character (0-9, a-f, A-F) to its
%   integer value 0-15.

hex_val(D, V) :-
    char_code(D, Code),
    ( Code >= 0'0, Code =< 0'9 -> V is Code - 0'0
    ; Code >= 0'a, Code =< 0'f -> V is Code - 0'a + 10
    ; Code >= 0'A, Code =< 0'F -> V is Code - 0'A + 10
    ).

%!  url_decode(+Chars, -Atom) is det.
%
%   Decode a URL-encoded character list and unify the result with Atom.

url_decode(Chars, Atom) :-
    url_decode_chars(Chars, Decoded),
    atom_chars(Atom, Decoded).


                /*******************************
                *       QUERY PARSING         *
                *******************************/

%!  parse_query(+Path, -Params) is det.
%
%   Extract URL-decoded key=value pairs from a request path such as
%   `"/call?goal=member(X,[a,b])&offset=0"`.  Params is a list of
%   Key=Value atoms, where each Value has been percent-decoded.  If
%   Path contains no `?`, Params is `[]`.

parse_query(Path, Params) :-
    ( split(Path, '?', _, QStr) -> true ; QStr = [] ),
    parse_pairs(QStr, Params).

%!  parse_pairs(+QStr, -Pairs) is det.
%
%   Split a query string character list on `&` separators and decode
%   each `key=value` pair.  If a pair has no `=`, the value is the
%   empty atom.

parse_pairs([], []).
parse_pairs(QStr, [Key=Val | Rest]) :-
    QStr \= [],
    ( split(QStr, '&', Pair, Remaining) -> true ; Pair = QStr, Remaining = [] ),
    ( split(Pair, '=', KChars, VChars) -> true ; KChars = Pair, VChars = [] ),
    atom_chars(Key, KChars),
    url_decode(VChars, Val),
    parse_pairs(Remaining, Rest).


                /*******************************
                *         HTTP SERVER         *
                *******************************/

%!  node(+Port) is det.
%
%   Start the node HTTP server on Port.  Opens a server socket, prints
%   a startup message, and enters node_loop/1.  Does not return.
%
%   The calling thread must be a registered actor (the top-level thread
%   always is) because compute_answer/5 uses receive/1 to collect
%   producer replies.  Concurrent connections are serialised; for a
%   production server each connection should be handled by a separate
%   spawn/3 actor.

node(Port) :-
    format(atom(Host), ':~w', [Port]),
    '$server'(Host, S, []),
    format("Node listening on port ~w~n", [Port]),
    node_loop(S).

%!  node_loop(+ServerSocket) is det.
%
%   Accept connections in a loop.  Each accepted connection is handled
%   by handle_connection/1.  Both exceptions thrown by
%   handle_connection/1 and clean failures are caught: an exception is
%   logged and the connection is closed; a failure also closes the
%   connection.  Either way the loop continues.

node_loop(S) :-
    '$accept'(S, C),
    (   catch(
            handle_connection(C),
            Error,
            ( format("node: error handling request: ~q~n", [Error]),
              close(C) )
        )
    ->  true
    ;   close(C)
    ),
    node_loop(S).


%!  handle_connection(+Client) is det.
%
%   Read one HTTP request from Client, dispatch to the appropriate
%   handler, and close the connection.  Only GET requests to `/call`
%   are handled; everything else gets a 404 response.
%
%   The method is normalised to uppercase by http_request/5.  The
%   path portion (before any `?`) is extracted with split/4 and
%   converted to an atom for matching.

handle_connection(C) :-
    http_request(C, Method, Path, Ver, _Hdrs),
    ( Method = "GET", split(Path, '?', PathPart, _)
    -> true
    ;  PathPart = Path
    ),
    atom_chars(PathAtom, PathPart),
    ( PathAtom == '/call'
    -> handle_call(C, Path, Ver)
    ;  http_reply(C, Ver, 404, 'Not Found',
                  'text/plain', 'Not found\n')
    ),
    close(C).


%!  handle_call(+Client, +Path, +Ver) is det.
%
%   Parse the query parameters from Path, evaluate the goal, and
%   send the answer back as an HTTP response.
%
%   `goal` and `template` are concatenated as `(Goal)+(Template)` and
%   read as a single term so that variables are shared between them.
%   Empty `offset` and `limit` values default to 0 and 1000000000
%   respectively (atom_number/2 throws syntax_error on the empty atom).

handle_call(C, Path, Ver) :-
    parse_query(Path, Params),
    param(goal,     Params, GoalAtom,     ''),
    param(template, Params, TemplateAtom, GoalAtom),
    param(offset,   Params, OffsetAtom,   '0'),
    param(limit,    Params, LimitAtom,    '1000000000'),
    param(format,   Params, Format,       prolog),
    (OffsetAtom == '' -> Offset = 0         ; atom_number(OffsetAtom, Offset)),
    (LimitAtom  == '' -> Limit  = 1000000000 ; atom_number(LimitAtom,  Limit)),
    % Parse Goal and Template as a single term so variables are shared
    atomic_list_concat([GoalAtom, +, TemplateAtom], QTAtom),
    read_term_from_atom(QTAtom, Goal+Template, []),
    compute_answer(Goal, Template, Offset, Limit, Answer),
    reply_answer(C, Ver, Format, Answer).


%!  param(+Key, +Params, -Val, +Default) is det.
%
%   Look up Key in the Params list (a list of Key=Value pairs).
%   Unifies Val with the associated value, or with Default if Key is
%   absent.

param(Key, Params, Val, Default) :-
    ( member(Key=Val, Params) -> true ; Val = Default ).


                /*******************************
                *        HTTP REPLIES         *
                *******************************/

%!  http_reply(+Client, +Ver, +Code, +Status, +CType, +Body) is det.
%
%   Write a minimal HTTP response to Client.  Ver is the HTTP version
%   string (e.g. `"1.1"`).  Body is written with `~w` so it must be
%   an atom or number.
%
%   Note: CType and Body must be atoms (not double-quoted char lists).
%   Trealla's double-quoted strings are char lists; passing one to `~w`
%   would produce list notation in the response.

http_reply(C, Ver, Code, Status, CType, Body) :-
    format(C, "HTTP/~s ~w ~w\r\nContent-Type: ~w\r\nConnection: close\r\n\r\n~w",
           [Ver, Code, Status, CType, Body]).

%!  reply_answer(+Client, +Ver, +Format, +Answer) is det.
%
%   Format and send an answer term.  Currently only `prolog` format is
%   supported.  The term is written with `~q` (quoted) so it can be
%   read back with `read_term_from_atom/3`.  JSON requests receive a
%   brief error message.

reply_answer(C, Ver, prolog, Answer) :- !,
    format(atom(AnswerAtom), "~q.\n",
           [Answer]),   % quoted so it round-trips through read_term_from_atom
    http_reply(C, Ver, 200, 'OK', 'text/plain; charset=UTF-8', AnswerAtom).
reply_answer(C, Ver, _, _) :-
    http_reply(C, Ver, 200, 'OK', 'text/plain; charset=UTF-8',
               'JSON output is not yet implemented\nUse format=prolog\n').


                /*******************************
                *       ANSWER COMPUTATION    *
                *******************************/

%!  compute_answer(+Goal, +Template, +Offset, +Limit, -Answer) is det.
%
%   Compute one page of answers using the producer-actor model.  If a
%   producer actor for this goal/template is cached at exactly Offset,
%   resume it -- the actor's WAM stack (and all of Goal's choicepoints)
%   are preserved across pages, so expensive computations (e.g.
%   sleep/1) are not repeated.  Otherwise spawn a fresh producer,
%   skipping the first Offset solutions.
%
%   After collecting Limit solutions, one extra `'$request'` is sent to
%   the producer to determine whether more solutions exist (N+1 lookahead
%   probe):
%
%     - If the producer replies `sol(Extra)`, there are more solutions.
%       The producer is stored in the cache at `Offset+Limit` with
%       `lookahead(Extra)`, and `Answer = success(Slice, true)`.
%     - If the producer replies `eos`, the stream is exhausted.
%       `Answer = success(Slice, false)` (or `failure` if Slice=[]).

compute_answer(Goal, Template, Offset, Limit, Answer) :-
    goal_id(Goal-Template, Gid),
    self(Self),
    (   cache_retract(Gid, Offset, ProducerPid, Lookahead)
    ->  true                            % resume suspended producer
    ;   spawn(run_goal_producer(Goal, Template), ProducerPid, [link(false)]),
        (Offset > 0 -> stream_skip(ProducerPid, Self, Offset) ; true),
        Lookahead = none
    ),
    stream_collect(ProducerPid, Self, Limit, Lookahead, Slice, Exhausted),
    (   Exhausted == true
    ->  (Slice == [] -> Answer = failure ; Answer = success(Slice, false))
    ;   % Probe for one extra solution to set the More flag accurately
        ProducerPid ! '$request'(Self),
        receive({
            sol(Extra) ->
                NextOffset is Offset + Limit,
                cache_update(Gid, NextOffset, ProducerPid, lookahead(Extra)),
                Answer = success(Slice, true)
            ; eos ->
                (Slice == [] -> Answer = failure ; Answer = success(Slice, false))
        })
    ).


%!  run_goal_producer(+Goal, +Template) is det.
%
%   Actor body for a solution producer.  Calls Goal via backtracking;
%   after each solution it pauses in receive waiting for either:
%
%     - `'$request'(C)` -- send `sol(Template)` to C, then fail to
%       backtrack to the next solution.
%     - `'$stop'`       -- throw `'$prod_stop'` to terminate cleanly.
%
%   When Goal is exhausted the `fail` at the end of the conjunction
%   causes the overall `call(Goal),...,fail` to fail, entering the
%   else branch which waits for the next `'$request'(C)` and replies
%   `eos`.  Subsequent requests for `'$request'` after `eos` will
%   block forever; the caller must not send more requests after
%   receiving `eos`.

run_goal_producer(Goal, Template) :-
    catch(
        (   call(Goal),
            receive({
                '$request'(C) -> C ! sol(Template)
                ; '$stop'     -> throw('$prod_stop')
            }),
            fail                        % backtrack for next solution
        ;   receive({
                '$request'(C) -> C ! eos
                ; '$stop'     -> throw('$prod_stop')
            })
        ),
        '$prod_stop',
        true
    ).


%!  stream_collect(+Pid, +Self, +N, +Lookahead, -Slice, -Exhausted) is det.
%
%   Collect at most N solutions from producer Pid into Slice (in the
%   original solution order).  Lookahead is `none` or `lookahead(T)`
%   for a pre-fetched solution from the previous page's probe.
%   Exhausted = true if the producer sent `eos` before N solutions were
%   collected.

stream_collect(Pid, Self, N, Lookahead, Slice, Exhausted) :-
    stream_collect_(Pid, Self, N, Lookahead, [], RevSlice, Exhausted),
    reverse(RevSlice, Slice).

%!  stream_collect_(+Pid, +Self, +N, +Lookahead, +Acc, -RevSlice, -Exhausted)
%
%   Accumulator-based worker for stream_collect/6.  Builds solutions
%   in reverse order (prepending to Acc); stream_collect/6 reverses at
%   the end.  Clause order:
%
%   1. N=0: limit reached; stop (not exhausted).
%   2. Lookahead=eos: stream already reported exhausted; stop.
%   3. Lookahead=lookahead(T): consume the pre-fetched solution first.
%   4. none + live producer: send '$request', wait for sol/eos.

stream_collect_(_, _, 0, _, Acc, Acc, false) :- !.
stream_collect_(_, _, _, eos, Acc, Acc, true) :- !.
stream_collect_(Pid, Self, N, lookahead(T), Acc, List, Exh) :- !,
    N1 is N - 1,
    stream_collect_(Pid, Self, N1, none, [T|Acc], List, Exh).
stream_collect_(Pid, Self, N, none, Acc, List, Exh) :-
    N > 0,
    Pid ! '$request'(Self),
    receive({
        sol(T) ->
            N1 is N - 1,
            stream_collect_(Pid, Self, N1, none, [T|Acc], List, Exh)
        ; eos ->
            List = Acc, Exh = true
    }).


%!  stream_skip(+Pid, +Self, +N) is det.
%
%   Discard the first N solutions from producer Pid.  Used when no
%   cached producer is available at the requested offset and solutions
%   must be skipped by re-running Goal from scratch.  `eos` before N
%   solutions terminates silently (the subsequent stream_collect/6 will
%   immediately see an empty producer and return an empty slice).

stream_skip(_, _, 0) :- !.
stream_skip(Pid, Self, N) :-
    N > 0,
    Pid ! '$request'(Self),
    receive({
        sol(_) -> N1 is N - 1, stream_skip(Pid, Self, N1)
        ; eos  -> true
    }).


                /*******************************
                *            CACHE            *
                *******************************/

:- dynamic(cache/4).   % cache(GoalId, Offset, ProducerPid, Lookahead)


%!  goal_id(+GoalTemplate, -Gid) is det.
%
%   Compute a ground hash key from a Goal-Template pair.  Variables are
%   replaced by numbered terms (via numbervars/3 on a copy) so that
%   structurally identical goals with different variable names hash the
%   same way, and different goal shapes hash differently.

goal_id(GoalTemplate, Gid) :-
    copy_term(GoalTemplate, GT0),
    numbervars(GT0, 0, _),
    term_hash(GT0, Gid).


%!  cache_retract(+Gid, +Offset, -Pid, -Lookahead) is semidet.
%
%   Remove and return the cache entry for (Gid, Offset), if one exists.
%   Fails if no matching entry is found.

cache_retract(Gid, Offset, Pid, Lookahead) :-
    once(retract(cache(Gid, Offset, Pid, Lookahead))).


%!  cache_update(+Gid, +Offset, +Pid, +Lookahead) is det.
%
%   Store a new cache entry for (Gid, Offset) and trim the cache if it
%   exceeds cache_size/1.

cache_update(Gid, Offset, Pid, Lookahead) :-
    assertz(cache(Gid, Offset, Pid, Lookahead)),
    trim_cache.


%!  trim_cache is det.
%
%   Evict cache entries until the cache size is within the limit.
%   Entries are evicted in insertion order (oldest first) because
%   assertz/retract maintain FIFO ordering.
%
%   Note: evicted producer actors are *not* explicitly stopped.  Their
%   `run_goal_producer/2` loop will block indefinitely in receive until
%   the Prolog process exits.  See the known issues in the module
%   header.

trim_cache :-
    cache_size(Size),
    findall(_, cache(_, _, _, _), Entries),
    length(Entries, Count),
    (   Count > Size
    ->  once(retract(cache(_, _, _, _))),
        trim_cache
    ;   true
    ).
