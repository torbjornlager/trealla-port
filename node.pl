% SPDX-License-Identifier: MIT

:- module(node,
       [ node/1,                 % +Port
         node/2,                 % +Port, :WebSocketHandler
         node/3                  % +Port, :WebSocketHandler, +Options
       ]).

:- op(800, xfx, !).
:- op(1000, xfy, if).

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
| limit      | `1000000000`   | Requested page size (owner-clamped)       |
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

## HTTP and WebSocket on one port {#node-websocket}

`node(Port)` serves the existing `/call` HTTP endpoint. The
`node(Port, WebSocketHandler)` form additionally enables `/ws`; after a
successful RFC 6455 upgrade it calls `WebSocketHandler(WebSocket, '/ws')`.
Accepted HTTP and WebSocket connections run in independent detached threads.

## Trealla port notes {#node-trealla}

  - The server uses `library(sockets)` directly so it can hand an upgraded
    stream to the WebSocket protocol instead of closing it after an HTTP
    response. Query parameters and request headers are parsed locally.
  - `library(settings)` is absent; cache_size defaults are plain facts.
  - `compute_answer/5` uses `receive/1` (unlimited wait) because
    producer replies are guaranteed: the producer is a local actor
    we just spawned or resumed.  No timeout is needed.
  - `predicate_property(..., number_of_clauses(N))` is absent; the
    cache size is counted with `findall/3`.
  - Only the `prolog` response format is implemented.  Requests for
    `json` receive a brief "not yet implemented" notice.
*/


:- use_module(library(sockets)).
:- use_module(actors).
:- use_module(profile_policy).
:- use_module(auth_policy).
:- use_module(governance_policy).
:- use_module(sandbox_policy).
:- use_module(resource_policy).
:- use_module(websocket).

:- meta_predicate(node(+, 2)).
:- meta_predicate(node(+, 2, +)).

:- dynamic connection_governance/3.


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
%   Start the HTTP-only node server on Port. Connections are dispatched to
%   detached threads. Use node/2 to enable the `/ws` upgrade route.

node(Port) :-
    node_server(Port, none, []).

%!  node(+Port, :WebSocketHandler) is det.
%
%   Start the node with a `/ws` WebSocket endpoint on the same listener as
%   `/call`. Each upgraded connection calls
%   `WebSocketHandler(WebSocket, Path)` in its own thread.

node(Port, WebSocketHandler) :-
    node_server(Port, WebSocketHandler, []).

%!  node(+Port, :WebSocketHandler, +Options) is det.
%
%   Options include `profile(Profile)`, `sandbox(Mode)`, `auth(Mode)`,
%   `principal(Id, Capabilities)`, `bearer_token(Id, Token, Capabilities)`,
%   `ws_allowed_origins(Origins)`, `relations(Patterns)`,
%   `rate_window_seconds(Seconds)`, `max_call_requests_per_window(Count)`,
%   `max_session_spawns_per_window(Count)`,
%   `max_ws_commands_per_window(Count)`, `max_inflight_calls(Count)`,
%   `max_ws_actors_per_principal(Count)`,
%   `time_limit(Seconds)`, `idle_limit(Seconds)`, `max_actors(Count)`,
%   `max_solutions(Count)`, `max_term_text_bytes(Bytes)`,
%   `max_source_text_bytes(Bytes)`, `max_ws_frame_bytes(Bytes)`, `ssl(true)`,
%   `keyfile(File)`, `certfile(File)`, and `websocket_options(Options)` (for
%   example subprotocol negotiation).  Defaults are `profile(workbench)` and
%   `sandbox(blacklist)`.

node(Port, WebSocketHandler, Options) :-
    node_server(Port, WebSocketHandler, Options).

node_server(Port, WebSocketHandler, Options) :-
    option(profile(Profile0), Options, workbench),
    normalize_profile(Profile0, Profile),
    option(sandbox(Sandbox0), Options, blacklist),
    normalize_sandbox_mode(Sandbox0, Sandbox),
    option(relations(RelationPatterns0), Options, []),
    normalize_relation_patterns(RelationPatterns0, RelationPatterns),
    configure_auth_policy(Options, AuthPolicy),
    AuthPolicy = auth_config(AuthMode, _, _, _, _, _, _, _),
    configure_governance_policy(Options, _GovernancePolicy),
    configure_resource_policy(Options, _ResourcePolicy),
    node_socket_options(Options, SocketOptions),
    option(websocket_options(WebSocketOptions0), Options, []),
    resource_websocket_options(WebSocketOptions0, WebSocketOptions),
    socket_server_open(Port, S, SocketOptions),
    format("Node listening on port ~w (profile ~w, sandbox ~w, auth ~w)~n",
           [Port, Profile, Sandbox, AuthMode]),
    node_loop(S, WebSocketHandler, WebSocketOptions,
              Profile, Sandbox, RelationPatterns).

node_socket_options(Options, SocketOptions) :-
    node_copy_option(ssl, Options, [], O1),
    node_copy_option(keyfile, Options, O1, O2),
    node_copy_option(certfile, Options, O2, SocketOptions).

node_copy_option(Name, Options, Input, Output) :-
    Option =.. [Name, _Value],
    ( memberchk(Option, Options) -> append(Input, [Option], Output)
    ; Output = Input
    ).

%!  node_loop(+ServerSocket, :WebSocketHandler) is det.
%
%   Accept continuously, starting an independent thread for each HTTP or
%   WebSocket connection.

node_loop(S, WebSocketHandler, WebSocketOptions, Profile, Sandbox,
          RelationPatterns) :-
    ( catch(socket_server_accept(S, Peer, C, [type(binary)]), Error,
            ( format(user_error, "node: accept error: ~q~n", [Error]), fail ))
    -> ( catch(thread_create(node_serve(C, Peer, WebSocketHandler, WebSocketOptions,
                                       Profile, Sandbox, RelationPatterns), _,
                             [detached(true)]),
               ThreadError,
               ( close(C), throw(ThreadError) ))
       -> true
       ; close(C)
       )
    ; true
    ),
    node_loop(S, WebSocketHandler, WebSocketOptions,
              Profile, Sandbox, RelationPatterns).

node_serve(C, Peer, WebSocketHandler, WebSocketOptions, Profile, Sandbox,
           RelationPatterns) :-
    catch(handle_connection(C, Peer, WebSocketHandler, WebSocketOptions,
                            Profile, Sandbox, RelationPatterns), Error,
          format(user_error, "node: error handling request: ~q~n", [Error])),
    catch(close(C), _, true).


%!  handle_connection(+Client, :WebSocketHandler) is det.
%
%   Dispatch `/call` as ordinary HTTP and `/ws` as an RFC 6455 socket
%   handoff. Other paths receive a 404 response.

handle_connection(C, Peer, WebSocketHandler, WebSocketOptions,
                  Profile, Sandbox, RelationPatterns) :-
    node_http_request(C, Method, Path, Ver, Headers),
    ( split(Path, '?', PathPart, _)
    -> true
    ;  PathPart = Path
    ),
    atom_chars(PathAtom, PathPart),
    ( Method == get, PathAtom == '/call'
    -> handle_call_route(C, Path, Ver, Peer, Headers,
                         Profile, Sandbox, RelationPatterns)
    ; Method == get, PathAtom == '/ws', WebSocketHandler \== none
    -> handle_ws_route(C, Ver, Peer, Headers, WebSocketHandler,
                       WebSocketOptions, Profile, PathAtom)
    ;  http_reply(C, Ver, 404, 'Not Found',
                  'text/plain', 'Not found\n')
    ).

handle_call_route(C, Path, Ver, Peer, Headers,
                  Profile, Sandbox, RelationPatterns) :-
    catch(( request_principal(Peer, Headers, Principal),
            require_route_access(Principal, call),
            profile_check_route(Profile, call) ), RouteError, true),
    ( var(RouteError)
    -> quota_identity(Principal, Peer, http, Identity),
       catch(handle_governed_call(C, Path, Ver, Principal, Identity,
                                  Profile, Sandbox, RelationPatterns),
             GovernanceError,
             reply_governance_denied(C, Ver, GovernanceError))
    ;  reply_policy_denied(C, Ver, RouteError)
    ).

handle_governed_call(C, Path, Ver, Principal, Identity,
                     Profile, Sandbox, RelationPatterns) :-
    enforce_call_request_rate_limit(Principal, Identity),
    effective_profile_for_route(Profile, call, EffectiveProfile),
    with_inflight_call_limit(
        Principal, Identity,
        catch(handle_call(C, Path, Ver, EffectiveProfile, Sandbox,
                          RelationPatterns),
              Error,
              reply_answer(C, Ver, prolog, error(Error)))).

handle_ws_route(C, Ver, Peer, Headers, WebSocketHandler,
                WebSocketOptions, Profile, PathAtom) :-
    catch(( ws_require_allowed_origin(Peer, Headers),
            request_principal(Peer, Headers, Principal),
            require_route_access(Principal, ws),
            profile_check_route(Profile, ws) ), Error, true),
    ( var(Error)
    -> quota_identity(Principal, Peer, websocket, Identity),
       setup_call_cleanup(
           set_connection_governance(Principal, Identity),
           ( ws_accept(C, Headers, WebSocket, WebSocketOptions),
             call(WebSocketHandler, WebSocket, PathAtom) ),
           clear_connection_governance)
    ; reply_policy_denied(C, Ver, Error)
    ).

set_connection_governance(Principal, Identity) :-
    thread_self(Thread),
    retractall(connection_governance(Thread, _, _)),
    assertz(connection_governance(Thread, Principal, Identity)).

clear_connection_governance :-
    thread_self(Thread),
    retractall(connection_governance(Thread, _, _)).

current_connection_governance(Principal, Identity) :-
    thread_self(Thread),
    connection_governance(Thread, Principal, Identity), !.

reply_policy_denied(C, Ver, Error) :-
    Error = error(authentication_required(_), _), !,
    format(atom(Body), '~q.\n', [error(Error)]),
    http_reply(C, Ver, 401, 'Unauthorized',
               'text/plain; charset=UTF-8', Body,
               ['WWW-Authenticate'-'Bearer realm="web-prolog"']).
reply_policy_denied(C, Ver, Error) :-
    reply_profile_denied(C, Ver, Error).

reply_governance_denied(C, Ver,
                        error(rate_limit_exceeded(Id, Resource, Limit, Window),
                              Context)) :- !,
    Error = error(rate_limit_exceeded(Id, Resource, Limit, Window), Context),
    format(atom(Body), '~q.\n', [Error]),
    format(atom(RetryAfter), '~w', [Window]),
    http_reply(C, Ver, 429, 'Too Many Requests',
               'text/plain; charset=UTF-8', Body,
               ['Retry-After'-RetryAfter]).
reply_governance_denied(C, Ver,
                        error(resource_limit_exceeded(Id, Resource, Limit),
                              Context)) :- !,
    Error = error(resource_limit_exceeded(Id, Resource, Limit), Context),
    format(atom(Body), '~q.\n', [Error]),
    http_reply(C, Ver, 429, 'Too Many Requests',
               'text/plain; charset=UTF-8', Body).
reply_governance_denied(C, Ver, Error) :-
    reply_answer(C, Ver, prolog, error(Error)).

reply_profile_denied(C, Ver, Error) :-
    format(atom(Body), '~q.\n', [error(Error)]),
    http_reply(C, Ver, 403, 'Forbidden',
               'text/plain; charset=UTF-8', Body).


%!  node_http_request(+Stream, -Method, -Path, -Version, -Headers) is det.
%
%   Parse one HTTP/1.x request without consuming bytes past the header block.
%   Header names are normalized to lowercase atoms for ws_accept/3.

node_http_request(Stream, Method, Path, Version, Headers) :-
    node_http_line(Stream, RequestLine),
    atom_codes(RequestAtom, RequestLine),
    atomic_list_concat([Method0, Target, HTTPVersion], ' ', RequestAtom),
    node_downcase_atom(Method0, Method),
    atom_concat('HTTP/', Version, HTTPVersion),
    atom_chars(Target, Path),
    node_http_headers(Stream, Headers).

node_http_headers(Stream, Headers) :-
    node_http_line(Stream, Line),
    ( Line == [] -> Headers = []
    ; node_http_header(Line, Header),
      Headers = [Header|Rest],
      node_http_headers(Stream, Rest)
    ).

node_http_header(Codes, Name-Value) :-
    append(NameCodes, [0':|RawValue], Codes),
    node_trim_space(RawValue, ValueCodes),
    atom_codes(Name0, NameCodes), node_downcase_atom(Name0, Name),
    atom_codes(Value, ValueCodes).

node_http_line(Stream, Line) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> throw(error(unexpected_eof, node_http_request/5))
    ; Byte =:= 13 ->
        get_byte(Stream, LF),
        ( LF =:= 10 -> Line = []
        ; throw(error(bad_http_line_ending, node_http_request/5)) )
    ; Line = [Byte|Rest], node_http_line(Stream, Rest)
    ).

node_trim_space(Codes, Trimmed) :-
    node_drop_space(Codes, Left), reverse(Left, Reversed),
    node_drop_space(Reversed, ReversedTrimmed), reverse(ReversedTrimmed, Trimmed).

node_drop_space([C|Cs], Rest) :- (C =:= 32 ; C =:= 9), !,
    node_drop_space(Cs, Rest).
node_drop_space(Cs, Cs).

node_downcase_atom(Atom, Lower) :-
    atom_codes(Atom, Codes), node_lower_codes(Codes, LowerCodes),
    atom_codes(Lower, LowerCodes).

node_lower_codes([], []).
node_lower_codes([C|Cs], [L|Ls]) :-
    ( C >= 65, C =< 90 -> L is C + 32 ; L = C ),
    node_lower_codes(Cs, Ls).


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
    handle_call(C, Path, Ver, isobase, blacklist, []).

handle_call(C, Path, Ver, Profile, Sandbox, RelationPatterns) :-
    parse_query(Path, Params),
    param(goal,     Params, GoalAtom,     ''),
    param(template, Params, TemplateAtom, GoalAtom),
    param(offset,   Params, OffsetAtom,   '0'),
    param(limit,    Params, LimitAtom,    '1000000000'),
    param(format,   Params, Format,       prolog),
    check_term_text_size(goal, GoalAtom),
    check_term_text_size(template, TemplateAtom),
    (OffsetAtom == '' -> Offset = 0         ; atom_number(OffsetAtom, Offset)),
    (LimitAtom  == '' -> RequestedLimit = 1000000000
    ; atom_number(LimitAtom, RequestedLimit)),
    ( integer(Offset), Offset >= 0 -> true
    ; throw(error(domain_error(offset, Offset), node:handle_call/6)) ),
    effective_solution_limit(RequestedLimit, Limit),
    % Parse Goal and Template as a single term so variables are shared
    atomic_list_concat([GoalAtom, +, TemplateAtom], QTAtom),
    read_term_from_atom(QTAtom, Goal+Template, []),
    profile_check_goal(Profile, Goal, RelationPatterns),
    sandbox_prepare_goal(Sandbox, Profile, user, Goal, ExecutionGoal),
    compute_answer(ExecutionGoal, Template, Offset, Limit, Answer),
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
    http_reply(C, Ver, Code, Status, CType, Body, []).

http_reply(C, Ver, Code, Status, CType, Body, ExtraHeaders) :-
    atom_codes(Body, BodyCodes), node_utf8_encode(BodyCodes, BodyBytes),
    length(BodyBytes, Length),
    http_extra_headers(ExtraHeaders, ExtraHeaderText),
    format(atom(Header),
           'HTTP/~w ~w ~w\r\nContent-Type: ~w\r\nContent-Length: ~w\r\n~wConnection: close\r\n\r\n',
           [Ver, Code, Status, CType, Length, ExtraHeaderText]),
    atom_codes(Header, HeaderBytes),
    node_write_bytes(C, HeaderBytes), node_write_bytes(C, BodyBytes),
    flush_output(C).

http_extra_headers([], '').
http_extra_headers([Name-Value|Headers], Text) :-
    format(atom(Line), '~w: ~w\r\n', [Name, Value]),
    http_extra_headers(Headers, Rest),
    atom_concat(Line, Rest, Text).

node_write_bytes(_, []).
node_write_bytes(Stream, [B|Bs]) :-
    put_byte(Stream, B), node_write_bytes(Stream, Bs).

node_utf8_encode([], []).
node_utf8_encode([C|Cs], Bytes) :-
    node_utf8_code(C, Head), append(Head, Rest, Bytes),
    node_utf8_encode(Cs, Rest).

node_utf8_code(C, [C]) :- C =< 127, !.
node_utf8_code(C, [B1,B2]) :- C =< 2047, !,
    B1 is 192 \/ (C >> 6), B2 is 128 \/ (C /\ 63).
node_utf8_code(C, [B1,B2,B3]) :- C =< 65535, !,
    B1 is 224 \/ (C >> 12), B2 is 128 \/ ((C >> 6) /\ 63),
    B3 is 128 \/ (C /\ 63).
node_utf8_code(C, [B1,B2,B3,B4]) :-
    B1 is 240 \/ (C >> 18), B2 is 128 \/ ((C >> 12) /\ 63),
    B3 is 128 \/ ((C >> 6) /\ 63), B4 is 128 \/ (C /\ 63).

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
    ;   spawn(run_goal_producer_guarded(Goal, Template), ProducerPid,
              [link(false)]),
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
            ; producer_error(Error) ->
                throw(Error)
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
    current_resource_policy(Policy),
    policy_time_limit(Policy, TimeLimit),
    setup_call_cleanup(
        create_resource_timer(TimeLimit, Timer),
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
        true),
        disarm_resource_timer(Timer)).

% Execute a producer while preserving exceptions as a reply to the next
% outstanding page request.  Public sandbox runtime guards can reject a goal
% only after variables become concrete, so dropping an actor exception here
% would otherwise leave the HTTP worker blocked forever.
run_goal_producer_guarded(Goal, Template) :-
    catch(run_goal_producer(Goal, Template), Error0,
          ( normalize_resource_exception(Error0, Error),
            producer_error_reply(Error) )).

producer_error_reply(Error) :-
    receive({
        '$request'(C) -> C ! producer_error(Error)
        ; '$stop' -> true
    }).


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
        ; producer_error(Error) ->
            throw(Error)
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
        ; producer_error(Error) -> throw(Error)
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
