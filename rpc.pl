:- module(rpc,
       [ rpc/2,                  % +URI, :Goal
         rpc/3                   % +URI, :Goal, +Options
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

  - URIs are decomposed with library(http)'s parse_url/2; the query
    path is assembled with format/2.
  - `http_open/3` is called with the list form `[host(...), port(...),
    path(...)]` because the URL-string form fails for localhost.
  - The response body is read with getline/2, which reads one line.
    This works because the node sends the entire answer on a single
    line ending with `.\n`.  Multi-line terms in the response would be
    truncated.
  - Goal and template atoms are URL-percent-encoded before embedding in
    the query string.

@author Torbjorn Lager
*/


:- use_module(library(http)).


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
%
%   The goal's free variables are collected with term_variables/2 and
%   wrapped in a `v(...)` template.  Both goal and template are
%   pretty-printed with `~q` (quoted, wrapped in parentheses to
%   preserve operator structure) and URL-encoded before embedding in
%   the query string.

rpc(URI, Goal) :-
    rpc(URI, Goal, []).

rpc(URI, Goal, Options) :-
    term_variables(Goal, Vars),
    Template =.. [v|Vars],
    format(atom(GoalAtom),     "(~q)", [Goal]),
    format(atom(TemplateAtom), "(~q)", [Template]),
    option(limit(Limit), Options, 10000000000),
    rpc_page(Template, 0, Limit, GoalAtom, TemplateAtom, URI, Options).


%!  rpc_page(+Template, +Offset, +Limit, +GoalAtom, +TemplateAtom,
%!           +BaseURI, +Options) is nondet.
%
%   Fetch one page of results from the node and yield each solution.
%   On backtracking after the last solution on this page, fetches the
%   next page (if More=true) by recursing with Offset incremented by
%   Limit.

rpc_page(Template, Offset, Limit, GoalAtom, TemplateAtom, BaseURI, Options) :-
    url_encode(GoalAtom,     GoalEnc),
    url_encode(TemplateAtom, TemplEnc),
    '$parse_url'(BaseURI, Parts),
    ( memberchk(host(Host), Parts) -> true ; Host = localhost ),
    ( memberchk(port(Port), Parts) -> true ; Port = 80 ),
    ( memberchk(path(BasePath), Parts) -> true ; BasePath = '/' ),
    base_path_prefix(BasePath, Prefix),
    format(atom(FullPath),
           '~wcall?goal=~w&template=~w&offset=~w&limit=~w&format=prolog',
           [Prefix, GoalEnc, TemplEnc, Offset, Limit]),
    http_open([host(Host), port(Port), path(FullPath)], S, []),
    getline(S, BodyChars),
    close(S),
    atom_chars(BodyAtom, BodyChars),
    read_term_from_atom(BodyAtom, Answer, []),
    rpc_answer(Answer, Template, Offset, Limit,
               GoalAtom, TemplateAtom, BaseURI, Options).


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
           GoalAtom, TemplateAtom, BaseURI, Options) :- !,
    (   member(Template, Slice)
    ;   NewOffset is Offset + Limit,
        rpc_page(Template, NewOffset, Limit,
                 GoalAtom, TemplateAtom, BaseURI, Options)
    ).
rpc_answer(success(Slice, false), Template, _, _, _, _, _, _) :-
    member(Template, Slice).
rpc_answer(failure, _, _, _, _, _, _, _) :-
    fail.
rpc_answer(error(Error), _, _, _, _, _, _, _) :-
    throw(Error).
