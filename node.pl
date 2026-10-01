% SPDX-License-Identifier: MIT

:- module(node,
       [ node/1,                 % +Port
         node/2,                 % +Port, :WebSocketHandler
         node/3,                 % +Port, :WebSocketHandler, +Options
         stop_node/1,            % +Port
         stop_node/2,            % +Port, +Options
         node_running/1,         % ?Port
         node_connection_count/2,% +Port, -Count
         set_node_maintenance/2, % +Port, +Boolean
         node_maintenance/2      % +Port, -Boolean
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
| format     | `prolog`       | Response format (`prolog` or `json`)     |

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
Accepted HTTP and WebSocket connections run in independent tracked detached
threads. `stop_node/1-2` closes the listener and active client streams and
waits for their normal cleanup under a bounded timeout.

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
  - JSON responses use Trinity's named-binding shape and ignore the explicit
    template parameter, as the SWI implementation does.
*/


:- use_module(library(sockets)).
:- use_module(library(json), [json_chars//1]).
:- use_module(actors).
:- use_module(profile_policy).
:- use_module(auth_policy).
:- use_module(governance_policy).
:- use_module(observability).
:- use_module(node_tokens).
:- use_module(sandbox_policy).
:- use_module(resource_policy).
:- use_module(source_policy).
:- use_module(ip_policy).
:- use_module(websocket).

:- meta_predicate(node(+, 2)).
:- meta_predicate(node(+, 2, +)).

:- dynamic connection_governance/4.
:- dynamic node_listener/4.
:- dynamic node_connection/4.
:- dynamic node_stopping/1.
:- dynamic node_configuration/7.
:- dynamic node_in_maintenance/1.

:- catch(mutex_create(_, [alias('$node_lifecycle')]),
         error(permission_error(create, mutex, '$node_lifecycle'), _),
         true).


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
%   `node_url(PublicURL)`, `tutorial_sections(Sections)`,
%   `ws_allowed_origins(Origins)`, `relations(Patterns)`,
%   `rate_window_seconds(Seconds)`, `max_call_requests_per_window(Count)`,
%   `max_session_spawns_per_window(Count)`,
%   `max_ws_commands_per_window(Count)`, `max_inflight_calls(Count)`,
%   `max_ws_actors_per_principal(Count)`,
%   `log_capacity(Count)`, `audit_log_file(File)`,
%   `max_audit_log_bytes(Bytes)`, `max_audit_log_backups(Count)`,
%   (the last three also accept their SWI names `interaction_log_file/1`,
%   `max_interaction_log_bytes/1`, and `max_interaction_log_backups/1`),
%   `tokens_file(File)` (alias `token_store_file(File)`),
%   `time_limit(Seconds)`, `idle_limit(Seconds)`, `max_actors(Count)`,
%   `max_solutions(Count)`, `max_term_text_bytes(Bytes)`,
%   `max_source_text_bytes(Bytes)`, `max_ws_frame_bytes(Bytes)`, `ssl(true)`,
%   `load_uri_allowed_origins(Origins)`,
%   `load_uri_allowed_ip_ranges(Patterns)`, `source_fetch_timeout(Seconds)`,
%   `max_source_redirects(Count)`, `allow_unverified_https(Boolean)`,
%   `ip_blocklist(Patterns)`, `ip_allowlist(Patterns)`,
%   `trusted_proxy_ranges(Patterns)`, `auto_ban_threshold(Count)`,
%   `auto_ban_window_seconds(Seconds)`, `auto_ban_seconds(Seconds)`,
%   `bind_address(Address)` (default `'0.0.0.0'`),
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
    configure_token_store(Options),
    configure_ip_policy(Options, _IPPolicy),
    configure_auth_policy(Options, AuthPolicy),
    AuthPolicy = auth_config(AuthMode, _, _, _, _, _, WSAllowedOrigins, _),
    configure_governance_policy(Options, _GovernancePolicy),
    configure_resource_policy(Options, _ResourcePolicy),
    configure_source_policy(Options, _SourcePolicy),
    configure_observability(Options, _ObservabilityPolicy),
    node_socket_options(Options, SocketOptions),
    option(websocket_options(WebSocketOptions0), Options, []),
    resource_websocket_options(WebSocketOptions0, WebSocketOptions),
    option(bind_address(BindAddress0), Options, '0.0.0.0'),
    node_bind_address(BindAddress0, BindAddress),
    option(node_url(PublicURL0), Options, none),
    node_public_url(PublicURL0, PublicURL),
    option(tutorial_sections(TutorialSections0), Options, []),
    normalize_metadata_atoms(tutorial_sections, TutorialSections0,
                             TutorialSections),
    socket_server_open(BindAddress:Port, S, SocketOptions),
    setup_call_cleanup(
        register_node_listener(Port, S, BindAddress, SocketOptions,
                               Profile, Sandbox, AuthMode, PublicURL,
                               TutorialSections, WSAllowedOrigins),
        ( format("Node listening on port ~w (profile ~w, sandbox ~w, auth ~w)~n",
                 [Port, Profile, Sandbox, AuthMode]),
          catch(node_loop(Port, S, WebSocketHandler, WebSocketOptions,
                          Profile, Sandbox, RelationPatterns),
                '$node_shutdown', true) ),
        cleanup_node_listener(Port, S)).

node_bind_address(Address, Address) :- atom(Address), Address \== '', !.
node_bind_address(Address, Atom) :-
    is_list(Address), atom_chars(Atom, Address), Atom \== '', !.
node_bind_address(Address, _) :-
    throw(error(domain_error(bind_address, Address), node:node/3)).

node_public_url(none, none) :- !.
node_public_url(URL0, URL) :-
    ( atom(URL0) -> URL1 = URL0
    ; is_list(URL0) -> atom_chars(URL1, URL0)
    ; throw(error(domain_error(node_url, URL0), node:node/3))
    ),
    ( atom_concat(URL, '/', URL1) -> true ; URL = URL1 ),
    ( atom_concat('http://', _, URL) ; atom_concat('https://', _, URL) ), !.
node_public_url(URL, _) :-
    throw(error(domain_error(node_url, URL), node:node/3)).

normalize_metadata_atoms(_, [], []) :- !.
normalize_metadata_atoms(Name, Values, Atoms) :-
    must_be(list, Values),
    normalize_metadata_atom_list(Name, Values, Atoms).

normalize_metadata_atom_list(_, [], []).
normalize_metadata_atom_list(Name, [Value0|Values], [Value|Atoms]) :-
    ( atom(Value0) -> Value = Value0
    ; is_list(Value0) -> atom_chars(Value, Value0)
    ; throw(error(domain_error(Name, Value0), node:node/3))
    ),
    normalize_metadata_atom_list(Name, Values, Atoms).

node_socket_options(Options, SocketOptions) :-
    node_copy_option(ssl, Options, [], O1),
    node_copy_option(keyfile, Options, O1, O2),
    node_copy_option(certfile, Options, O2, SocketOptions).

node_copy_option(Name, Options, Input, Output) :-
    Option =.. [Name, _Value],
    ( memberchk(Option, Options) -> append(Input, [Option], Output)
    ; Output = Input
    ).

%!  node_loop(+Port, +ServerSocket, :WebSocketHandler, +WebSocketOptions,
%!            +Profile, +Sandbox, +Relations) is det.
%
%   Accept continuously, starting an independent thread for each HTTP or
%   WebSocket connection.

node_loop(Port, S, WebSocketHandler, WebSocketOptions, Profile, Sandbox,
          RelationPatterns) :-
    ( node_is_stopping(Port)
    -> true
    ; accept_node_connection(Port, S, ReportedPeer, C)
    -> ( node_is_stopping(Port)
       -> safe_close_stream(C)
       ; node_connection_peer(C, ReportedPeer, Peer),
         dispatch_node_connection(Port, C, Peer, WebSocketHandler,
                                  WebSocketOptions, Profile, Sandbox,
                                  RelationPatterns),
         node_loop(Port, S, WebSocketHandler, WebSocketOptions,
                   Profile, Sandbox, RelationPatterns)
       )
    ; node_is_stopping(Port)
    -> true
    ; node_loop(Port, S, WebSocketHandler, WebSocketOptions,
                Profile, Sandbox, RelationPatterns)
    ).

accept_node_connection(Port, S, Peer, C) :-
    catch(socket_server_accept(S, Peer, C, [type(binary)]), Error,
          accept_node_error(Port, Error)).

accept_node_error(Port, _) :- node_is_stopping(Port), !, fail.
accept_node_error(_, Error) :-
    format(user_error, "node: accept error: ~q~n", [Error]), fail.

dispatch_node_connection(Port, C, Peer, WebSocketHandler, WebSocketOptions,
                         Profile, Sandbox, RelationPatterns) :-
    make_ref(Key),
    register_node_connection(Port, Key, C),
    catch(thread_create(
              node_serve_tracked(Port, Key, C, Peer, WebSocketHandler,
                                 WebSocketOptions, Profile, Sandbox,
                                 RelationPatterns),
              Thread, [detached(true)]),
          Error,
          ( unregister_node_connection(Key),
            catch(close(C), _, true), throw(Error) )),
    set_node_connection_thread(Key, Thread).

node_serve_tracked(Port, Key, C, Peer, WebSocketHandler, WebSocketOptions,
                   Profile, Sandbox, RelationPatterns) :-
    setup_call_cleanup(
        true,
        node_serve(Port, C, Peer, WebSocketHandler, WebSocketOptions,
                   Profile, Sandbox, RelationPatterns),
        unregister_node_connection(Key)).

% Older installed library(sockets) releases returned the accepted stream in
% the Client argument.  The v3.12 runtime already records the actual peer on
% that stream, so recover it directly and retain the public result as a
% fallback.  Binding the listener to IPv4 avoids BUG-013's IPv6-family decode.
node_connection_peer(Stream, _Reported, Address:Port) :-
    catch('$peer_addr'(Stream, Address, Port), _, fail), !.
node_connection_peer(_, Reported, Reported).

node_serve(Port, C, Peer, WebSocketHandler, WebSocketOptions, Profile, Sandbox,
           RelationPatterns) :-
    catch(handle_connection(Port, C, Peer, WebSocketHandler, WebSocketOptions,
                            Profile, Sandbox, RelationPatterns), Error,
          report_node_connection_error(Port, Error)),
    catch(close(C), _, true).

report_node_connection_error(Port, _) :- node_is_stopping(Port), !.
report_node_connection_error(_, Error) :-
    format(user_error, "node: error handling request: ~q~n", [Error]).


                 /*******************************
                 *       NODE LIFECYCLE         *
                 *******************************/

register_node_listener(Port, S, BindAddress, SocketOptions,
                       Profile, Sandbox, AuthMode, PublicURL,
                       TutorialSections, WSAllowedOrigins) :-
    ( memberchk(ssl(true), SocketOptions) -> SSL = true ; SSL = false ),
    with_mutex('$node_lifecycle',
        ( retractall(node_stopping(Port)),
          retractall(node_in_maintenance(Port)),
          retractall(node_configuration(Port, _, _, _, _, _, _)),
          assertz(node_configuration(Port, Profile, Sandbox, AuthMode,
                                     PublicURL, TutorialSections,
                                     WSAllowedOrigins)),
          retractall(node_listener(Port, _, _, _)),
          assertz(node_listener(Port, S, BindAddress, SSL)) )).

cleanup_node_listener(Port, S) :-
    safe_close_server(S),
    close_node_connections(Port),
    with_mutex('$node_lifecycle',
        ( retractall(node_listener(Port, _, _, _)),
          retractall(node_stopping(Port)),
          retractall(node_in_maintenance(Port)),
          retractall(node_configuration(Port, _, _, _, _, _, _)) )).

register_node_connection(Port, Key, Stream) :-
    with_mutex('$node_lifecycle',
               assertz(node_connection(Port, Key, Stream, pending))).

set_node_connection_thread(Key, Thread) :-
    with_mutex('$node_lifecycle',
        ( retract(node_connection(Port, Key, Stream, pending))
        -> assertz(node_connection(Port, Key, Stream, Thread))
        ; true
        )).

unregister_node_connection(Key) :-
    with_mutex('$node_lifecycle',
               retractall(node_connection(_, Key, _, _))).

node_running(Port) :-
    with_mutex('$node_lifecycle', node_listener(Port, _, _, _)).

node_connection_count(Port, Count) :-
    with_mutex('$node_lifecycle',
        ( findall(Key, node_connection(Port, Key, _, _), Keys),
          length(Keys, Count) )).

%!  set_node_maintenance(+Port, +Boolean) is det.
%
%   Enter or leave drain mode. Existing work is left alone; new `/call` and
%   `/ws` execution requests receive 503 while readiness reports not-ready.

set_node_maintenance(Port, Boolean) :-
    must_be(integer, Port), must_be(boolean, Boolean),
    ( node_running(Port) -> true
    ; throw(error(existence_error(node, Port), node:set_node_maintenance/2))
    ),
    with_mutex('$node_lifecycle', set_node_maintenance_locked(Port, Boolean)).

set_node_maintenance_locked(Port, true) :-
    ( node_in_maintenance(Port) -> true ; assertz(node_in_maintenance(Port)) ).
set_node_maintenance_locked(Port, false) :-
    retractall(node_in_maintenance(Port)).

node_maintenance(Port, Boolean) :-
    with_mutex('$node_lifecycle',
        ( node_in_maintenance(Port) -> Boolean = true ; Boolean = false )).

node_accepting_work(Port) :-
    node_running(Port),
    \+ node_is_stopping(Port),
    node_maintenance(Port, false).

node_is_stopping(Port) :-
    with_mutex('$node_lifecycle', node_stopping(Port)).

%!  stop_node(+Port) is det.
%
%   Stop accepting new connections, close every tracked client socket, and
%   wait up to five seconds for detached handlers to run their cleanup.

stop_node(Port) :- stop_node(Port, [timeout(5)]).

%!  stop_node(+Port, +Options) is det.
%
%   `timeout(Seconds)` bounds the drain wait. A timeout leaves shutdown
%   requested and raises `resource_error(node_shutdown_timeout(Port, Count))`.

stop_node(Port, Options) :-
    must_be(integer, Port), must_be(list, Options),
    option(timeout(Timeout0), Options, 5),
    node_shutdown_timeout(Timeout0, Timeout),
    begin_node_shutdown(Port, Wake, Streams),
    close_node_streams(Streams),
    ( nonvar(Wake) -> wake_node_listener(Wake, Port)
    ; true
    ),
    get_time(Now), Deadline is Now + Timeout,
    wait_node_shutdown(Port, Deadline).

node_shutdown_timeout(Value, Value) :- number(Value), Value >= 0, !.
node_shutdown_timeout(Value, _) :-
    throw(error(domain_error(node_shutdown_timeout, Value), node:stop_node/2)).

begin_node_shutdown(Port, Wake, Streams) :-
    with_mutex('$node_lifecycle',
        ( ( node_listener(Port, _, BindAddress, SSL)
          -> Wake = wake(BindAddress, SSL),
             ( node_in_maintenance(Port) -> true
             ; assertz(node_in_maintenance(Port)) ),
             ( node_stopping(Port) -> true ; assertz(node_stopping(Port)) )
          ; Wake = _
          ),
          findall(Stream, node_connection(Port, _, Stream, _), Streams) )).

wake_node_listener(wake(BindAddress, SSL), Port) :-
    % Trealla BUG-014: closing a listener from another thread does not wake
    % its blocked accept. A local connection lets the owner observe the stop
    % flag and close its own listening stream. Match TLS so accept can finish.
    listener_wake_address(BindAddress, Address),
    listener_wake_options(SSL, Options),
    ( catch(socket_client_open(Address:Port, Stream, Options), _, fail)
    -> safe_close_stream(Stream)
    ; true
    ).

listener_wake_address('0.0.0.0', '127.0.0.1') :- !.
listener_wake_address(Address, Address).

listener_wake_options(true, [ssl(true),type(binary)]).
listener_wake_options(false, [type(binary)]).

close_node_connections(Port) :-
    with_mutex('$node_lifecycle',
        findall(Stream, node_connection(Port, _, Stream, _), Streams)),
    close_node_streams(Streams).

close_node_streams([]).
close_node_streams([Stream|Streams]) :-
    safe_close_stream(Stream), close_node_streams(Streams).

safe_close_stream(Stream) :-
    ( catch(close(Stream), _, fail) -> true ; true ).

safe_close_server(Server) :-
    ( catch(socket_server_close(Server), _, fail) -> true ; true ).

wait_node_shutdown(Port, Deadline) :-
    node_connection_count(Port, Count),
    ( \+ node_running(Port), Count =:= 0
    -> true
    ; get_time(Now), Now >= Deadline
    -> throw(error(resource_error(node_shutdown_timeout(Port, Count)),
                   node:stop_node/2))
    ; sleep(0.01), wait_node_shutdown(Port, Deadline)
    ).


%!  handle_connection(+Client, :WebSocketHandler) is det.
%
%   Dispatch `/call` as ordinary HTTP and `/ws` as an RFC 6455 socket
%   handoff. Other paths receive a 404 response.

handle_connection(Port, C, Peer, WebSocketHandler, WebSocketOptions,
                  Profile, Sandbox, RelationPatterns) :-
    node_http_request(C, Method, Path, Ver, Headers),
    ( split(Path, '?', PathPart, _)
    -> true
    ;  PathPart = Path
    ),
    atom_chars(PathAtom, PathPart),
    ( Method == get, PathAtom == '/healthz'
    -> reply_status_json(C, Ver, 200, 'OK', ok)
    ; Method == get, PathAtom == '/version'
    -> handle_version(C, Ver)
    ; Method == get, PathAtom == '/readyz'
    -> handle_readyz(Port, C, Ver)
    ; Method == get, PathAtom == '/node_info'
    -> handle_node_info(Port, C, Ver, Peer, Headers)
    ; Method == get, PathAtom == '/call'
    -> handle_call_route(Port, C, Path, Ver, Peer, Headers,
                         Profile, Sandbox, RelationPatterns)
    ; Method == get, PathAtom == '/ws', WebSocketHandler \== none
    -> handle_ws_route(Port, C, Ver, Peer, Headers, WebSocketHandler,
                       WebSocketOptions, Profile, PathAtom)
    ; Method == get, PathAtom == '/metrics'
    -> node_metrics_text(Metrics),
       http_reply(C, Ver, 200, 'OK',
                  'text/plain; version=0.0.4; charset=UTF-8', Metrics)
    ; Method == get, PathAtom == '/admin/runtime'
    -> handle_admin_runtime(C, Ver, Peer, Headers)
    ; memberchk(Method, [get,post,delete]), PathAtom == '/admin/tokens'
    -> handle_admin_tokens(C, Method, Path, Ver, Peer, Headers)
    ; memberchk(Method, [get,post]), PathAtom == '/admin/maintenance'
    -> handle_admin_maintenance(Port, C, Method, Ver, Peer, Headers)
    ;  http_reply(C, Ver, 404, 'Not Found',
                  'text/plain', 'Not found\n')
    ).

handle_call_route(Port, C, _Path, Ver, _Peer, _Headers,
                  _Profile, _Sandbox, _RelationPatterns) :-
    \+ node_accepting_work(Port), !,
    reply_draining(C, Ver).
handle_call_route(_Port, C, Path, Ver, Peer, Headers,
                  Profile, Sandbox, RelationPatterns) :-
    catch(( require_ip_access(Peer, Headers, ClientIP),
            request_principal(Peer, Headers, Principal),
            require_route_access(Principal, call),
            profile_check_route(Profile, call) ), RouteError, true),
    ( var(RouteError)
    -> quota_identity(Principal, ClientIP, http, Identity),
       catch(observe_request(
                 Principal, http, call,
                 handle_governed_call(C, Path, Ver, Principal, Identity,
                                      Profile, Sandbox, RelationPatterns)),
             GovernanceError,
             ( note_ip_governance_offense(Peer, Headers, GovernanceError),
               reply_call_error(C, Path, Ver, GovernanceError) ))
    ;  audit_principal(Principal, AuditPrincipal),
       observe_rejection(AuditPrincipal, http, call, RouteError),
       reply_policy_denied(C, Ver, RouteError)
    ).

handle_governed_call(C, Path, Ver, Principal, Identity,
                     Profile, Sandbox, RelationPatterns) :-
    enforce_call_request_rate_limit(Principal, Identity),
    effective_profile_for_route(Profile, call, EffectiveProfile),
    with_inflight_call_limit(
        Principal, Identity,
        handle_call(C, Path, Ver, EffectiveProfile, Sandbox,
                    RelationPatterns)).

handle_ws_route(Port, C, Ver, _Peer, _Headers, _WebSocketHandler,
                _WebSocketOptions, _Profile, _PathAtom) :-
    \+ node_accepting_work(Port), !,
    reply_draining(C, Ver).
handle_ws_route(_Port, C, Ver, Peer, Headers, WebSocketHandler,
                WebSocketOptions, Profile, PathAtom) :-
    catch(( require_ip_access(Peer, Headers, ClientIP),
            ws_require_allowed_origin(Peer, Headers),
            request_principal(Peer, Headers, Principal),
            require_route_access(Principal, ws),
            profile_check_route(Profile, ws) ), Error, true),
    ( var(Error)
    -> quota_identity(Principal, Peer, websocket, Identity),
       setup_call_cleanup(
           set_connection_governance(Principal, Identity, ClientIP),
           ( ws_accept(C, Headers, WebSocket, WebSocketOptions),
             call(WebSocketHandler, WebSocket, PathAtom) ),
           clear_connection_governance)
    ; audit_principal(Principal, AuditPrincipal),
      observe_rejection(AuditPrincipal, websocket, connect, Error),
      reply_policy_denied(C, Ver, Error)
    ).

audit_principal(Principal, Principal) :- nonvar(Principal), !.
audit_principal(_, anonymous([])).

handle_readyz(Port, C, Ver) :-
    ( node_accepting_work(Port)
    -> reply_status_json(C, Ver, 200, 'OK', ready)
    ; reply_status_json(C, Ver, 503, 'Service Unavailable', not_ready)
    ).

reply_status_json(C, Ver, Code, Reason, Status) :-
    node_json_object([status-string_atom(Status)], JSON),
    reply_json_status(C, Ver, Code, Reason, JSON).

handle_version(C, Ver) :-
    ( current_prolog_flag(version_data, trealla(Major, Minor, Patch, _))
    -> format(atom(Runtime), '~w.~w.~w', [Major, Minor, Patch])
    ; Runtime = unknown
    ),
    node_json_object([web_prolog-string_atom('trealla-port'),
                      trealla-string_atom(Runtime),protocol-number(1)], JSON),
    reply_json(C, Ver, JSON).

reply_draining(C, Ver) :-
    node_json_object([type-string_atom(error),
                      error-string_atom('node draining; not accepting new work')],
                     JSON),
    phrase(json_chars(JSON), Chars), atom_chars(Body, Chars),
    http_reply(C, Ver, 503, 'Service Unavailable',
               'application/json; charset=UTF-8', Body,
               ['Retry-After'-'1']).

handle_node_info(Port, C, Ver, Peer, Headers) :-
    node_configuration(Port, Profile, Sandbox, AuthMode, PublicURL,
                       TutorialSections, WSAllowedOrigins),
    node_listener(Port, _, BindAddress, SSL),
    node_self_url(PublicURL, BindAddress, Port, SSL, SelfURL),
    ( catch(request_principal(Peer, Headers, Principal), _, fail) -> true
    ; Principal = anonymous([])
    ),
    principal_id(Principal, PrincipalId),
    ( catch(require_route_access(Principal, call), _, fail)
    -> Execution = true
    ; Execution = false
    ),
    node_maintenance(Port, Maintenance),
    json_string_list(['X-Web-Prolog-User','X-Web-Prolog-Principal',
                      'X-Authenticated-User'], IdentityHeaders),
    json_string_list(['X-Web-Prolog-Capabilities','X-Web-Prolog-Caps'],
                     CapabilityHeaders),
    json_string_list(TutorialSections, TutorialSectionsJSON),
    json_string_list(WSAllowedOrigins, WSAllowedOriginsJSON),
    node_json_object(
        [self_url-string_atom(SelfURL),profile-string_atom(Profile),
         auth-string_atom(AuthMode),sandbox-string_atom(Sandbox),
         protocol_version-number(1),auth_boundary-string_atom(trusted_headers),
         trusted_identity_headers-list(IdentityHeaders),
         trusted_capability_headers-list(CapabilityHeaders),
         internal_transport_principal_prefix-string_atom('node:'),
         principal_id-string_atom(PrincipalId),
         principal_execution-boolean(Execution),maintenance-boolean(Maintenance),
         services-list([]),provides-list([]),self_contained-boolean(true),
         ws_allowed_origins-list(WSAllowedOriginsJSON),
         tutorial_sections-list(TutorialSectionsJSON)],
        JSON),
    reply_json(C, Ver, JSON).

node_self_url(PublicURL, _, _, _, PublicURL) :- PublicURL \== none, !.
node_self_url(_, BindAddress, Port, SSL, URL) :-
    ( SSL == true -> Scheme = https ; Scheme = http ),
    ( memberchk(BindAddress, ['0.0.0.0','::']) -> Host = localhost
    ; Host = BindAddress
    ),
    format(atom(URL), '~w://~w:~w', [Scheme, Host, Port]).

handle_admin_runtime(C, Ver, Peer, Headers) :-
    request_principal(Peer, Headers, Principal),
    catch(require_admin_access(Principal), Error, true),
    ( var(Error)
    -> catch(observe_request(Principal, http, admin_runtime,
                             reply_admin_runtime(C, Ver)),
             RuntimeError,
             reply_answer(C, Ver, prolog, error(RuntimeError)))
    ; observe_rejection(Principal, http, admin_runtime, Error),
      reply_policy_denied(C, Ver, Error)
    ).

handle_admin_maintenance(Port, C, Method, Ver, Peer, Headers) :-
    request_principal(Peer, Headers, Principal),
    catch(require_admin_access(Principal), AccessError, true),
    ( var(AccessError)
    -> catch(observe_request(
                 Principal, http, admin_maintenance,
                 admin_maintenance_response(Port, C, Method, Ver, Headers)),
             Error,
             reply_admin_error(C, Ver, Error))
    ; observe_rejection(Principal, http, admin_maintenance, AccessError),
      reply_policy_denied(C, Ver, AccessError)
    ).

admin_maintenance_response(Port, C, get, Ver, _) :- !,
    node_maintenance(Port, Enabled),
    node_json_object([enabled-boolean(Enabled)], JSON),
    reply_json(C, Ver, JSON).
admin_maintenance_response(Port, C, post, Ver, Headers) :-
    read_json_request(C, Headers, JSON),
    ( node_json_field(JSON, enabled, boolean(Enabled)),
      memberchk(Enabled, [true,false])
    -> set_node_maintenance(Port, Enabled)
    ; throw(error(domain_error(maintenance_field, enabled),
                  node:handle_admin_maintenance/7))
    ),
    node_json_object([enabled-boolean(Enabled)], Response),
    reply_json(C, Ver, Response).

require_admin_access(Principal) :-
    ( principal_has_capability(Principal, admin) -> true
    ; Principal = anonymous(_)
    -> throw(error(authentication_required(admin_runtime),
                   context(node:require_admin_access/1,
                           'admin endpoint requires authentication')))
    ; principal_id(Principal, Id),
      throw(error(authorization_error(Id, admin),
                  context(node:require_admin_access/1,
                          'principal lacks the admin capability')))
    ).

reply_admin_runtime(C, Ver) :-
    node_runtime_json(JSON),
    http_reply(C, Ver, 200, 'OK', 'application/json; charset=UTF-8', JSON).

handle_admin_tokens(C, Method, Path, Ver, Peer, Headers) :-
    request_principal(Peer, Headers, Principal),
    catch(require_admin_access(Principal), AccessError, true),
    ( var(AccessError)
    -> admin_token_operation(Method, Operation),
       catch(observe_request(
                 Principal, http, Operation,
                 admin_tokens_response(C, Method, Path, Ver, Headers)),
             Error,
             reply_admin_error(C, Ver, Error))
    ; observe_rejection(Principal, http, admin_tokens, AccessError),
      reply_policy_denied(C, Ver, AccessError)
    ).

admin_token_operation(get, admin_token_list).
admin_token_operation(post, admin_token_issue).
admin_token_operation(delete, admin_token_revoke).

admin_tokens_response(C, get, _, Ver, _) :- !,
    current_tokens(Tokens), tokens_json(Tokens, TokensJSON),
    node_json_object([tokens-list(TokensJSON)], JSON),
    reply_json(C, Ver, JSON).
admin_tokens_response(C, post, _, Ver, Headers) :- !,
    read_json_request(C, Headers, JSON),
    admin_issue_fields(JSON, Principal, Capabilities, Options),
    issue_token(Principal, Capabilities, Options, FullToken),
    atomic_list_concat([wp,Id,_], '_', FullToken),
    current_tokens(Tokens), tokens_json(Tokens, TokensJSON),
    node_json_object([token-string_atom(FullToken),id-string_atom(Id),
                      tokens-list(TokensJSON)], Response),
    reply_json(C, Ver, Response).
admin_tokens_response(C, delete, Path, Ver, _) :-
    parse_query(Path, Params),
    ( memberchk(id=Id, Params), Id \== '' -> true
    ; throw(error(domain_error(token_field, id), node:handle_admin_tokens/6))
    ),
    ( revoke_token(Id) -> Revoked = true ; Revoked = false ),
    current_tokens(Tokens), tokens_json(Tokens, TokensJSON),
    node_json_object([revoked-boolean(Revoked),id-string_atom(Id),
                      tokens-list(TokensJSON)], Response),
    reply_json(C, Ver, Response).

read_json_request(C, Headers, JSON) :-
    ( memberchk('content-length'-LengthAtom, Headers),
      catch(atom_number(LengthAtom, Length), _, fail),
      integer(Length), Length > 0
    -> true
    ; throw(error(domain_error(content_length, missing),
                  node:handle_admin_tokens/6))
    ),
    current_resource_policy(resource_policy(_,_,_,_,MaxBytes,_,_)),
    ( Length =< MaxBytes -> true
    ; throw(error(resource_error(input_size(admin_json,Length,MaxBytes)), node))
    ),
    read_exact_bytes(C, Length, Codes), atom_codes(Body, Codes),
    atom_chars(Body, Chars),
    ( phrase(json_chars(JSON), Chars) -> true
    ; throw(error(syntax_error(json), node:handle_admin_tokens/6))
    ).

read_exact_bytes(_, 0, []) :- !.
read_exact_bytes(Stream, Count, [Byte|Bytes]) :-
    get_byte(Stream, Byte),
    ( Byte >= 0 -> true
    ; throw(error(unexpected_eof, node:handle_admin_tokens/6))
    ),
    Next is Count-1, read_exact_bytes(Stream, Next, Bytes).

admin_issue_fields(JSON, Principal, Capabilities, Options) :-
    ( node_json_text(JSON, principal, Principal), Principal \== '' -> true
    ; throw(error(domain_error(token_field, principal),
                  node:handle_admin_tokens/6))
    ),
    ( node_json_field(JSON, capabilities, CapabilityValue)
    -> ( CapabilityValue = list(Values), json_atom_list(Values, Capabilities)
       -> true
       ; throw(error(domain_error(token_field, capabilities),
                     node:handle_admin_tokens/6)) )
    ; Capabilities = [execute]
    ),
    admin_issue_options(JSON, Options).

admin_issue_options(JSON, Options) :-
    ( node_json_field(JSON, expires_in, ExpiryValue)
    -> ( ExpiryValue = number(Seconds)
       -> Options = [expires_in(Seconds)|Rest]
       ; throw(error(domain_error(token_field, expires_in),
                     node:handle_admin_tokens/6)) )
    ; Rest = Options
    ),
    ( node_json_field(JSON, label, LabelValue)
    -> ( LabelValue = string(LabelChars), atom_chars(Label, LabelChars)
       -> Rest = [label(Label)]
       ; throw(error(domain_error(token_field, label),
                     node:handle_admin_tokens/6)) )
    ; Rest = []
    ).

json_atom_list([], []).
json_atom_list([string(Chars)|Values], [Atom|Atoms]) :-
    atom_chars(Atom, Chars), json_atom_list(Values, Atoms).

tokens_json([], []).
tokens_json([token_info(Id,Principal,Caps,Created,Expires,Used,Revoked,Label)|Tokens],
            [JSON|JSONTokens]) :-
    json_string_list(Caps, CapsJSON),
    node_json_object([id-string_atom(Id),principal_id-string_atom(Principal),
                      capabilities-list(CapsJSON),created_at-number(Created),
                      expires_at-number(Expires),last_used_at-number(Used),
                      revoked-boolean(Revoked),label-string_atom(Label)], JSON),
    tokens_json(Tokens, JSONTokens).

json_string_list([], []).
json_string_list([Atom|Atoms], [string(Chars)|Values]) :-
    atom_chars(Atom, Chars), json_string_list(Atoms, Values).

node_json_field(pairs(Pairs), Key, Value) :-
    atom_chars(Key, KeyChars), memberchk(string(KeyChars)-Value, Pairs).

node_json_text(JSON, Key, Atom) :-
    node_json_field(JSON, Key, string(Chars)), atom_chars(Atom, Chars).

node_json_object(Fields, pairs(Pairs)) :- node_json_fields(Fields, Pairs).
node_json_fields([], []).
node_json_fields([Key-Value0|Fields], [string(KeyChars)-Value|Pairs]) :-
    atom_chars(Key, KeyChars), node_json_value(Value0, Value),
    node_json_fields(Fields, Pairs).

node_json_value(string_atom(Atom), string(Chars)) :- !, atom_chars(Atom, Chars).
node_json_value(Value, Value).

reply_json(C, Ver, JSON) :-
    reply_json_status(C, Ver, 200, 'OK', JSON).

reply_json_status(C, Ver, Code, Reason, JSON) :-
    phrase(json_chars(JSON), Chars), atom_chars(Body, Chars),
    http_reply(C, Ver, Code, Reason, 'application/json; charset=UTF-8', Body).

reply_admin_error(C, Ver, Error) :-
    format(atom(Body), '~q.\n', [error(Error)]),
    http_reply(C, Ver, 400, 'Bad Request',
               'text/plain; charset=UTF-8', Body).

set_connection_governance(Principal, Identity, ClientIP) :-
    thread_self(Thread),
    retractall(connection_governance(Thread, _, _, _)),
    assertz(connection_governance(Thread, Principal, Identity, ClientIP)).

clear_connection_governance :-
    thread_self(Thread),
    retractall(connection_governance(Thread, _, _, _)).

current_connection_governance(Principal, Identity) :-
    thread_self(Thread),
    connection_governance(Thread, Principal, Identity, _), !.

current_connection_client_ip(ClientIP) :-
    thread_self(Thread),
    connection_governance(Thread, _, _, ClientIP), !.

note_ip_governance_offense(Peer, Headers,
                           error(rate_limit_exceeded(_,_,_,_), _)) :- !,
    catch(record_ip_offense(Peer, Headers), _, true).
note_ip_governance_offense(_, _, _).

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

reply_call_error(C, Path, Ver, Error) :-
    parse_query(Path, Params), param(format, Params, Format, prolog),
    ( Format == json
    -> reply_json_call_error(C, Ver, Error)
    ; reply_governance_denied(C, Ver, Error)
    ).

reply_json_call_error(C, Ver, Error) :-
    Error = error(rate_limit_exceeded(_,_,_,Window), _), !,
    answer_json(error(Error), JSON),
    phrase(json_chars(JSON), Chars), atom_chars(Body, Chars),
    format(atom(RetryAfter), '~w', [Window]),
    http_reply(C, Ver, 429, 'Too Many Requests',
               'application/json; charset=UTF-8', Body,
               ['Retry-After'-RetryAfter]).
reply_json_call_error(C, Ver, Error) :-
    Error = error(resource_limit_exceeded(_,_,_), _), !,
    answer_json(error(Error), JSON),
    reply_json_status(C, Ver, 429, 'Too Many Requests', JSON).
reply_json_call_error(C, Ver, Error) :-
    reply_answer(C, Ver, json, error(Error)).

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
    read_term_from_atom(QTAtom, Goal+Template0, [variable_names(Bindings0)]),
    response_template(Format, Template0, Bindings0, Template),
    profile_check_goal(Profile, Goal, RelationPatterns),
    sandbox_prepare_goal(Sandbox, Profile, user, Goal, ExecutionGoal),
    compute_answer(ExecutionGoal, Template, Offset, Limit, Answer),
    reply_answer(C, Ver, Format, Answer).

response_template(json, _, Bindings0, json_bindings(Bindings)) :- !,
    named_bindings(Bindings0, Bindings).
response_template(_, Template, _, Template).

named_bindings([], []).
named_bindings([Name=Value|Bindings], Named) :-
    ( anonymous_variable_name(Name)
    -> Named = Rest
    ; Named = [Name=Value|Rest]
    ),
    named_bindings(Bindings, Rest).

anonymous_variable_name(Name) :-
    atom_chars(Name, ['_'|_]).


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
%   Format and send an answer term. Prolog terms are written with `~q`
%   so they round-trip through `read_term_from_atom/3`; JSON uses the
%   Trinity `{type,data,more}` response shape with named binding objects.

reply_answer(C, Ver, prolog, Answer) :- !,
    format(atom(AnswerAtom), "~q.\n",
           [Answer]),   % quoted so it round-trips through read_term_from_atom
    http_reply(C, Ver, 200, 'OK', 'text/plain; charset=UTF-8', AnswerAtom).
reply_answer(C, Ver, json, Answer) :- !,
    answer_json(Answer, JSON),
    reply_json(C, Ver, JSON).
reply_answer(_, _, Format, _) :-
    throw(error(domain_error(response_format, Format), node:reply_answer/4)).

answer_json(success(Rows0, More), JSON) :-
    answer_json_rows(Rows0, Rows),
    node_json_object([type-string_atom(success),data-list(Rows),
                      more-boolean(More)], JSON).
answer_json(failure, JSON) :-
    node_json_object([type-string_atom(failure)], JSON).
answer_json(error(Error), JSON) :-
    term_json_string(Error, ErrorString),
    node_json_object([type-string_atom(error),data-string_atom(ErrorString)], JSON).

answer_json_rows([], []).
answer_json_rows([json_bindings(Bindings)|Rows], [JSON|JSONRows]) :-
    binding_json_fields(Bindings, Fields),
    node_json_object(Fields, JSON),
    answer_json_rows(Rows, JSONRows).

binding_json_fields([], []).
binding_json_fields([Name=Value|Bindings],
                    [Name-string_atom(Text)|Fields]) :-
    term_json_string(Value, Text),
    binding_json_fields(Bindings, Fields).

term_json_string(Term, Text) :-
    format(atom(Text), '~q', [Term]).


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
