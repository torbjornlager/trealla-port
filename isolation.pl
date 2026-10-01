% SPDX-License-Identifier: MIT

:- module(isolation,
       [ prepare_actor/4,          % +Pid, +GoalModule, +Options, -Module
         run_actor_goal/3,         % +Module, :Goal, +Options
         cleanup_actor/1,          % +Pid
         configure_shared_db/1,    % +Files
         clear_shared_db/0,
         actor_module/2,           % +Pid, -Module
         actor_source_module/2,    % +Pid, -Module
         execution_goal/2,         % +Goal, -QualifiedGoal
         rewrite_source_options/3, % +Options, +SourceModule, -Options
         load_options_text/3       % +SourceModule, +Options, -Text
       ]).

/** <module> Private source namespaces for Trealla actors

Each local actor receives a fresh Trealla module.  Source supplied through
`src_text/1`, `src_list/1`, or `src_predicates/1` is installed there and is
therefore invisible to other actors.  `src_predicates/1` is materialised in
the spawning process, which also makes it portable over the distribution
protocol.

Trealla currently exposes module creation, but not module destruction, to
Prolog.  Cleanup therefore retracts every dynamically installed source
predicate and deletes the short-lived bootstrap file.  The now-empty module
record remains in Trealla's module table until process exit.

`src_uri/1` is resolved to inline source by the node's controlled source
policy before actor creation.
*/

:- use_module(library(error)).
:- use_module(source_policy).

:- dynamic actor_namespace/2.
:- dynamic actor_source_namespace/2.
:- dynamic shared_db_text/1.

:- catch(mutex_create(_, [alias('$isolation_listing')]),
         error(permission_error(create, mutex, '$isolation_listing'), _),
         true).

actors_library_file(ActorsFile) :-
    absolute_file_name('actors.pl', ActorsFile, []).

sandbox_library_file(SandboxFile) :-
    absolute_file_name('sandbox_policy.pl', SandboxFile, []).

rpc_library_file(RpcFile) :-
    absolute_file_name('rpc.pl', RpcFile, []).


                /*******************************
                *       PUBLIC OPERATIONS      *
                *******************************/

%!  configure_shared_db(+Files) is det.
%
%   Load trusted node-wide source files for every subsequently created actor.
%   The source is copied into each actor namespace so ordinary actor calls and
%   nested spawns see the same database.  Actor-local source retains SWI's
%   shadowing semantics: defining a predicate locally replaces the shared
%   clauses for that predicate in that actor only.

configure_shared_db(Files) :-
    must_be(list, Files),
    shared_files_text(Files, '', Text),
    retractall(shared_db_text(_)),
    ( Text == '' -> true ; assertz(shared_db_text(Text)) ).

clear_shared_db :-
    retractall(shared_db_text(_)).

shared_files_text([], Text, Text).
shared_files_text([File0|Files], Acc, Text) :-
    shared_file_atom(File0, File),
    setup_call_cleanup(open(File, read, Stream, [type(binary)]),
                       read_stream_bytes(Stream, Bytes), close(Stream)),
    atom_codes(Source, Bytes),
    ( Acc == '' -> Next = Source
    ; atom_concat(Acc, '\n', Prefix), atom_concat(Prefix, Source, Next)
    ),
    shared_files_text(Files, Next, Text).

shared_file_atom(File, File) :- atom(File), !.
shared_file_atom(File, Atom) :- string(File), !, atom_string(Atom, File).
shared_file_atom(File, _) :-
    throw(error(type_error(source_sink, File), configure_shared_db/1)).

read_stream_bytes(Stream, Bytes) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> Bytes = []
    ; Bytes = [Byte|Rest], read_stream_bytes(Stream, Rest)
    ).

prepare_actor(Pid, _GoalModule, Options, Module) :-
    fresh_namespace(Module, File),
    catch(
        ( write_bootstrap(File, Module),
          load_files(File, []),
          delete_file(File),
          assertz(actor_namespace(Pid, Module)),
          source_options(Options, Sources),
          ( shared_db_text(SharedText)
          -> call_in_module(Module, '$actor_load_shared'(SharedText)),
             HasShared = true
          ; HasShared = false
          ),
          call_in_module(Module, '$actor_load'(Sources)),
          ( Sources == [], HasShared == false -> true
          ; assertz(actor_source_namespace(Pid, Module))
          )
        ),
        Error,
        ( catch(delete_file(File), _, true),
          catch(call_in_module(Module, '$actor_cleanup'), _, true),
          retractall(actor_namespace(Pid, Module)),
          retractall(actor_source_namespace(Pid, Module)),
          throw(Error)
        )).

run_actor_goal(Module, Goal0, Options) :-
    ( memberchk('$entry_context'(caller), Options)
    -> call(Goal0)
    ; strip_module(Goal0, _, Goal),
      call_in_module(Module, '$actor_call'(Goal))
    ).

cleanup_actor(Pid) :-
    retractall(actor_source_namespace(Pid, _)),
    forall(retract(actor_namespace(Pid, Module)),
           catch(call_in_module(Module, '$actor_cleanup'), _, true)).

actor_module(Pid, Module) :-
    actor_namespace(Pid, Module).

actor_source_module(Pid, Module) :-
    actor_source_namespace(Pid, Module).

execution_goal(Goal, Qualified) :-
    Goal = rpc(URI, RemoteGoal),
    !,
    Qualified = rpc:rpc(URI, RemoteGoal).
execution_goal(Goal, Qualified) :-
    Goal = rpc(URI, RemoteGoal, Options),
    !,
    Qualified = rpc:rpc(URI, RemoteGoal, Options).
execution_goal(Goal, Qualified) :-
    actors:self(Pid),
    actor_source_namespace(Pid, Module),
    !,
    % Calling the goal through the private module's trampoline preserves any
    % explicit module qualification introduced by the sandbox rewriter.
    % Trealla otherwise lets the outer Module:Goal qualification override a
    % nested sandbox_policy:sandbox_spawn(...) qualification.
    Qualified = Module:'$actor_call'(Goal).
execution_goal(Goal, Goal).


                /*******************************
                *        SOURCE OPTIONS       *
                *******************************/

source_options([], []).
source_options([Option|Options], Sources) :-
    ( source_option(Option)
    -> Sources = [Option|Rest]
    ; Option = src_uri(URI)
    -> throw(error(permission_error(load, source_uri, URI),
                   context(isolation:prepare_actor/4,
                           'src_uri/1 must be materialized by source_policy before isolation')))
    ; Sources = Rest
    ),
    source_options(Options, Rest).

source_option(src_text(Text)) :-
    text_source(Text),
    !.
source_option(src_text(Text)) :-
    throw(error(type_error(text, Text), src_text/1)).
source_option(src_list(Terms)) :-
    must_be(list, Terms),
    !.
source_option(src_predicates(PIs)) :-
    throw(error(domain_error(rewritten_source_option, src_predicates(PIs)),
                isolation:prepare_actor/4)).

text_source(Text) :- atom(Text), !.
text_source(Text) :- string(Text), !.
text_source(Text) :- is_list(Text).

rewrite_source_options([], _, []).
rewrite_source_options([src_uri(URI)|Options], Module,
                       [src_text(Text)|Rewritten]) :-
    !,
    fetch_source_uri(URI, Text),
    rewrite_source_options(Options, Module, Rewritten).
rewrite_source_options([src_predicates(PIs)|Options], Module0,
                       [src_list(Terms)|Rewritten]) :-
    !,
    source_module(Module0, Module),
    predicates_to_terms(Module, PIs, Terms),
    rewrite_source_options(Options, Module0, Rewritten).
rewrite_source_options([Option|Options], Module, [Option|Rewritten]) :-
    rewrite_source_options(Options, Module, Rewritten).

%!  load_options_text(+SourceModule, +Options, -Text) is det.
%
%   Materialize RPC src_* options into the single src_text query parameter
%   understood by Web Prolog's HTTP endpoint.  This mirrors the SWI client:
%   list and predicate sources are serialized locally, while src_uri is
%   fetched under the node's configured source policy before being shipped.

load_options_text(Module, Options, Text) :-
    load_option_parts(Options, Module, Parts),
    append_source_parts(Parts, '', Text).

load_option_parts([], _, []).
load_option_parts([Option|Options], Module, Parts) :-
    ( load_option_text(Option, Module, Text)
    -> Parts = [Text|Rest]
    ; Parts = Rest
    ),
    load_option_parts(Options, Module, Rest).

load_option_text(src_text(Text0), _, Text) :- !,
    source_text_atom(Text0, Text).
load_option_text(src_list(Terms), _, Text) :- !,
    source_terms_text(Terms, Text).
load_option_text(src_predicates(PIs), Module, Text) :- !,
    rewrite_source_options([src_predicates(PIs)], Module, [src_list(Terms)]),
    source_terms_text(Terms, Text).
load_option_text(src_uri(URI), _, Text) :- !,
    fetch_source_uri(URI, Text).

source_text_atom(Text, Text) :- atom(Text), !.
source_text_atom(Text, Atom) :- string(Text), !, atom_string(Atom, Text).
source_text_atom(Text, Atom) :- is_list(Text), !,
    ( Text = [C|_], integer(C) -> atom_codes(Atom, Text)
    ; atom_chars(Atom, Text)
    ).
source_text_atom(Text, _) :-
    throw(error(type_error(text, Text), src_text/1)).

source_terms_text(Terms, Text) :-
    must_be(list, Terms),
    source_terms_text_(Terms, '', Text).

source_terms_text_([], Text, Text).
source_terms_text_([Term|Terms], Acc, Text) :-
    format(atom(Line), '~q.~n', [Term]),
    atom_concat(Acc, Line, Next),
    source_terms_text_(Terms, Next, Text).

append_source_parts([], Text, Text).
append_source_parts([Part|Parts], Acc, Text) :-
    ( Acc == '' -> Next = Part
    ; Part == '' -> Next = Acc
    ; atom_concat(Acc, '\n', Prefix), atom_concat(Prefix, Part, Next)
    ),
    append_source_parts(Parts, Next, Text).

source_module(Module, user) :- var(Module), !.
source_module(Module, Module).

predicates_to_terms(Module, PIs, Terms) :-
    must_be(list, PIs),
    maplist(valid_source_predicate_indicator, PIs),
    actor_namespace(_, Module),
    !,
    call_in_module(Module, '$actor_copy_predicates'(PIs, Terms)).
predicates_to_terms(Module, PIs, Terms) :-
    must_be(list, PIs),
    maplist(valid_source_predicate_indicator, PIs),
    actors:make_ref(Id),
    format(atom(HelperName), '$isolation_listing_~w', [Id]),
    HelperHead =.. [HelperName, PI],
    HelperClause = (HelperHead :- listing(PI)),
    setup_call_cleanup(
        call_in_module(Module, assertz(HelperClause)),
        with_mutex('$isolation_listing',
                   listed_predicate_terms(Module, HelperName, Id,
                                          PIs, Terms)),
        ( CleanupHead =.. [HelperName, _],
          call_in_module(Module, retractall(CleanupHead))
        )).

valid_source_predicate_indicator(PI) :-
    source_predicate_indicator(PI, _, _).

listed_predicate_terms(Module, HelperName, Id, PIs, Terms) :-
    fresh_bootstrap_file(Id, File),
    setup_call_cleanup(
        true,
        ( write_predicate_listings(File, Module, HelperName, PIs),
          read_source_terms(File, Terms)
        ),
        catch(delete_file(File), _, true)).

write_predicate_listings(File, Module, HelperName, PIs) :-
    setup_call_cleanup(
        open(File, write, Out),
        setup_call_cleanup(
            ( current_output(Previous), set_output(Out) ),
            write_predicate_listings_(PIs, Module, HelperName),
            set_output(Previous)),
        close(Out)).

write_predicate_listings_([], _, _).
write_predicate_listings_([PI|PIs], Module, HelperName) :-
    Call =.. [HelperName, PI],
    call_in_module(Module, Call),
    write_predicate_listings_(PIs, Module, HelperName).

read_source_terms(File, Terms) :-
    setup_call_cleanup(
        open(File, read, In),
        read_source_terms_(In, Terms),
        close(In)).

read_source_terms_(In, Terms) :-
    read_term(In, Term, []),
    ( Term == end_of_file
    -> Terms = []
    ; Terms = [Term|Rest],
      read_source_terms_(In, Rest)
    ).

source_predicate_indicator(PI, Name, Arity) :-
    must_be(nonvar, PI),
    ( PI = Name/Arity,
      atom(Name), integer(Arity), Arity >= 0
    -> true
    ; throw(error(type_error(predicate_indicator, PI), src_predicates/1))
    ).

                /*******************************
                *       MODULE BOOTSTRAP       *
                *******************************/

fresh_namespace(Module, File) :-
    actors:make_ref(Id),
    format(atom(Module), '$trealla_actor_~w', [Id]),
    fresh_bootstrap_file(Id, File).

fresh_bootstrap_file(Id, File) :-
    random_between(1000000000, 9999999999, Random),
    format(atom(Candidate), '/tmp/trealla-actor-~w-~w.pl', [Random, Id]),
    ( exists_file(Candidate)
    -> fresh_bootstrap_file(Id, File)
    ; File = Candidate
    ).

write_bootstrap(File, Module) :-
    actors_library_file(ActorsFile),
    sandbox_library_file(SandboxFile),
    rpc_library_file(RpcFile),
    setup_call_cleanup(
        open(File, write, Out),
        write_bootstrap_(Out, Module, ActorsFile, SandboxFile, RpcFile),
        close(Out)).

write_bootstrap_(Out, Module, ActorsFile, SandboxFile, RpcFile) :-
    format(Out, '%% SPDX-License-Identifier: MIT~n', []),
    format(Out, ':- module(~q, [\'$actor_load\'/1, \'$actor_load_shared\'/1, \'$actor_call\'/1, \'$actor_copy_predicates\'/2, \'$actor_cleanup\'/0]).~n', [Module]),
    format(Out, ':- use_module(~q).~n', [ActorsFile]),
    format(Out, ':- use_module(~q, [rpc/2,rpc/3]).~n', [RpcFile]),
    format(Out, ':- use_module(~q, [sandbox_call/5,sandbox_call/6,sandbox_call/7,sandbox_call/8,sandbox_call/9,sandbox_call/10,sandbox_call/11,sandbox_call/12,sandbox_spawn/7,sandbox_toplevel_call/7,sandbox_format/2,sandbox_sleep/1,sandbox_clause/6,sandbox_assert/5,sandbox_assert/6,sandbox_asserta/5,sandbox_asserta/6,sandbox_assertz/5,sandbox_assertz/6,sandbox_retract/5,sandbox_retractall/5,sandbox_abolish/5,sandbox_abolish/6]).~n', [SandboxFile]),
    format(Out, ':- dynamic \'$actor_source_pi\'/1.~n', []),
    format(Out, ':- dynamic \'$actor_dynamic_pi\'/1.~n', []),
    format(Out, ':- dynamic \'$actor_shared_pi\'/1.~n', []),
    format(Out, ':- dynamic \'$actor_loading_shared\'/0.~n', []),
    format(Out, '\'$actor_load_shared\'(Text) :- setup_call_cleanup(assertz(\'$actor_loading_shared\'), \'$actor_text\'(Text), retractall(\'$actor_loading_shared\')).~n', []),
    format(Out, '\'$actor_load\'([]).~n', []),
    format(Out, '\'$actor_load\'([src_text(Text)|Rest]) :- !, \'$actor_text\'(Text), \'$actor_load\'(Rest).~n', []),
    format(Out, '\'$actor_load\'([src_list(Terms)|Rest]) :- !, \'$actor_terms\'(Terms), \'$actor_load\'(Rest).~n', []),
    format(Out, '\'$actor_load\'([Bad|_]) :- throw(error(domain_error(source_option, Bad), \'$actor_load\'/1)).~n', []),
    format(Out, '\'$actor_text\'(Text0) :- \'$actor_source_atom\'(Text0, Text), open_string(Text, In), setup_call_cleanup(true, \'$actor_read\'(In), close(In)).~n', []),
    format(Out, '\'$actor_source_atom\'(Text, Text) :- atom(Text), !.~n', []),
    format(Out, '\'$actor_source_atom\'(Text, Atom) :- string(Text), !, atom_string(Atom, Text).~n', []),
    format(Out, '\'$actor_source_atom\'(Text, Atom) :- Text = [C|_], integer(C), !, atom_codes(Atom, Text).~n', []),
    format(Out, '\'$actor_source_atom\'(Text, Atom) :- atom_chars(Atom, Text).~n', []),
    format(Out, '\'$actor_read\'(In) :- read_term(In, Term, []), ( Term == end_of_file -> true ; \'$actor_term\'(Term), \'$actor_read\'(In) ).~n', []),
    format(Out, '\'$actor_terms\'([]).~n', []),
    format(Out, '\'$actor_terms\'([Term|Terms]) :- \'$actor_term\'(Term), \'$actor_terms\'(Terms).~n', []),
    format(Out, '\'$actor_term\'(Term0) :- expand_term(Term0, Term1), \'$actor_qualify_source\'(Term1, Term), \'$actor_expanded\'(Term).~n', []),
    format(Out, '\'$actor_qualify_source\'([], []) :- !.~n', []),
    format(Out, '\'$actor_qualify_source\'([Term0|Terms0], [Term|Terms]) :- !, \'$actor_qualify_source\'(Term0, Term), \'$actor_qualify_source\'(Terms0, Terms).~n', []),
    format(Out, '\'$actor_qualify_source\'((Head :- Body0), (Head :- Body)) :- !, \'$actor_qualify_goal\'(Body0, Body).~n', []),
    format(Out, '\'$actor_qualify_source\'(Term, Term).~n', []),
    format(Out, '\'$actor_qualify_goal\'((A0,B0), (A,B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_goal\'((A0;B0), (A;B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_goal\'((A0->B0), (A->B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_goal\'((\\+ A0), (\\+ A)) :- !, \'$actor_qualify_goal\'(A0,A).~n', []),
    format(Out, '\'$actor_qualify_goal\'(receive(Clauses0), receive(~q:Clauses)) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses).~n', [Module]),
    format(Out, '\'$actor_qualify_goal\'(receive(Clauses0,Options0), receive(~q:Clauses,Options)) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses), \'$actor_qualify_receive_options\'(Options0,Options).~n', [Module]),
    format(Out, '\'$actor_qualify_goal\'(Goal, Goal).~n', []),
    format(Out, '\'$actor_qualify_receive\'({Clauses0}, {Clauses}) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses).~n', []),
    format(Out, '\'$actor_qualify_receive\'((A0;B0), (A;B)) :- !, \'$actor_qualify_receive\'(A0,A), \'$actor_qualify_receive\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_receive\'((Head0->Body0), (Head->Body)) :- !, \'$actor_qualify_receive_head\'(Head0,Head), \'$actor_qualify_receive_body\'(Body0,Body).~n', []),
    format(Out, '\'$actor_qualify_receive\'(Clause, Clause).~n', []),
    format(Out, '\'$actor_qualify_receive_head\'(if(Pattern,Guard0), if(Pattern,Guard)) :- !, \'$actor_qualify_receive_body\'(Guard0,Guard).~n', []),
    format(Out, '\'$actor_qualify_receive_head\'(Head, Head).~n', []),
    format(Out, '\'$actor_qualify_receive_options\'(Options, Options) :- var(Options), !.~n', []),
    format(Out, '\'$actor_qualify_receive_options\'([], []) :- !.~n', []),
    format(Out, '\'$actor_qualify_receive_options\'([on_timeout(Goal0)|Options0], [on_timeout(Goal)|Options]) :- !, \'$actor_qualify_receive_body\'(Goal0,Goal), \'$actor_qualify_receive_options\'(Options0,Options).~n', []),
    format(Out, '\'$actor_qualify_receive_options\'([Option|Options0], [Option|Options]) :- \'$actor_qualify_receive_options\'(Options0,Options).~n', []),
    format(Out, '\'$actor_qualify_receive_body\'((A0,B0), (A,B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_receive_body\'((A0;B0), (A;B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_receive_body\'((A0->B0), (A->B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    format(Out, '\'$actor_qualify_receive_body\'((\\+ A0), (\\+ A)) :- !, \'$actor_qualify_receive_body\'(A0,A).~n', []),
    format(Out, '\'$actor_qualify_receive_body\'(Qualified:Goal, Qualified:Goal) :- atom(Qualified), !.~n', []),
    format(Out, '\'$actor_qualify_receive_body\'(receive(Clauses0), actors:receive(~q:Clauses)) :- !, \'$actor_qualify_receive\'(Clauses0,Clauses).~n', [Module]),
    format(Out, '\'$actor_qualify_receive_body\'(receive(Clauses0,Options0), actors:receive(~q:Clauses,Options)) :- !, \'$actor_qualify_receive\'(Clauses0,Clauses), \'$actor_qualify_receive_options\'(Options0,Options).~n', [Module]),
    format(Out, '\'$actor_qualify_receive_body\'(Goal, ~q:Goal).~n', [Module]),
    format(Out, '\'$actor_expanded\'([]) :- !.~n', []),
    format(Out, '\'$actor_expanded\'([Term|Terms]) :- !, \'$actor_expanded\'(Term), \'$actor_expanded\'(Terms).~n', []),
    format(Out, '\'$actor_expanded\'((:- module(Name, Exports))) :- !, throw(error(permission_error(load, module, module(Name, Exports)), \'$actor_load\'/1)).~n', []),
    % Clauses are installed with assertz/1 and are therefore mutable already.
    % Trealla does not expose dynamic/1 as a callable runtime predicate, so
    % retain the declaration as source ownership metadata without calling it.
    format(Out, '\'$actor_expanded\'((:- dynamic(PI))) :- !, \'$actor_remember_pi\'(PI), \'$actor_remember_dynamic_pi\'(PI).~n', []),
    format(Out, '\'$actor_expanded\'((:- Directive)) :- !, call(Directive).~n', []),
    format(Out, '\'$actor_expanded\'((Head :- Body)) :- !, \'$actor_remember\'(Head), assertz((Head :- Body)).~n', []),
    format(Out, '\'$actor_expanded\'(Head) :- \'$actor_remember\'(Head), assertz(Head).~n', []),
    format(Out, '\'$actor_remember\'(Head) :- callable(Head), functor(Head, Name, Arity), PI = Name/Arity, \'$actor_prepare_pi\'(PI,Head).~n', []),
    format(Out, '\'$actor_remember_pi\'((A,B)) :- !, \'$actor_remember_pi\'(A), \'$actor_remember_pi\'(B).~n', []),
    format(Out, '\'$actor_remember_pi\'(Name/Arity) :- functor(Head,Name,Arity), \'$actor_prepare_pi\'(Name/Arity,Head).~n', []),
    format(Out, '\'$actor_prepare_pi\'(PI,_Head) :- \'$actor_loading_shared\', !, ( \'$actor_source_pi\'(PI) -> true ; assertz(\'$actor_source_pi\'(PI)) ), ( \'$actor_shared_pi\'(PI) -> true ; assertz(\'$actor_shared_pi\'(PI)) ).~n', []),
    format(Out, '\'$actor_prepare_pi\'(Name/Arity,_Head) :- PI = Name/Arity, ( retract(\'$actor_shared_pi\'(PI)) -> functor(SharedHead,Name,Arity), retractall(SharedHead) ; true ), ( \'$actor_source_pi\'(PI) -> true ; assertz(\'$actor_source_pi\'(PI)) ).~n', []),
    format(Out, '\'$actor_remember_dynamic_pi\'((A,B)) :- !, \'$actor_remember_dynamic_pi\'(A), \'$actor_remember_dynamic_pi\'(B).~n', []),
    format(Out, '\'$actor_remember_dynamic_pi\'(PI) :- ( \'$actor_dynamic_pi\'(PI) -> true ; assertz(\'$actor_dynamic_pi\'(PI)) ).~n', []),
    % Trealla does not preserve imports when an arbitrary term is passed
    % through call/1 here.  Route the flat Web Prolog RPC surface explicitly,
    % matching the actor_api re-export used by the SWI implementation.
    format(Out, '\'$actor_call\'(rpc(URI,Goal)) :- !, rpc:rpc(URI,Goal).~n', []),
    format(Out, '\'$actor_call\'(rpc(URI,Goal,Options)) :- !, rpc:rpc(URI,Goal,Options).~n', []),
    format(Out, '\'$actor_call\'(Goal) :- call(Goal).~n', []),
    format(Out, '\'$actor_copy_predicates\'([], []).~n', []),
    format(Out, '\'$actor_copy_predicates\'([Name/Arity|PIs], Terms) :- PI = Name/Arity, \'$actor_source_pi\'(PI), !, functor(Head,Name,Arity), \'$actor_dynamic_terms\'(PI,Declarations), findall(Term, (clause(Head,Body0), \'$actor_strip_source_module\'(Body0,Body), \'$actor_clause_term\'(Head,Body,Term)), Here), append(Declarations,Here,Current), \'$actor_copy_predicates\'(PIs,Rest), append(Current,Rest,Terms).~n', []),
    format(Out, '\'$actor_copy_predicates\'([PI|_], _) :- throw(error(existence_error(procedure,PI), src_predicates/1)).~n', []),
    format(Out, '\'$actor_dynamic_terms\'(PI, [(:- dynamic(PI))]) :- \'$actor_dynamic_pi\'(PI), !.~n', []),
    format(Out, '\'$actor_dynamic_terms\'(_, []).~n', []),
    format(Out, '\'$actor_strip_source_module\'(Term, Term) :- var(Term), !.~n', []),
    format(Out, '\'$actor_strip_source_module\'(sandbox_policy:sandbox_clause(_M,_P,_C,_A,Head0,Body0), clause(Head,Body)) :- !, \'$actor_strip_source_module\'(Head0,Head), \'$actor_strip_source_module\'(Body0,Body).~n', []),
    format(Out, '\'$actor_strip_source_module\'(sandbox_policy:sandbox_sleep(Seconds), sleep(Seconds)) :- !.~n', []),
    format(Out, '\'$actor_strip_source_module\'(actors:input(\'|:\',Term0), read(Term)) :- !, \'$actor_strip_source_module\'(Term0,Term).~n', []),
    format(Out, '\'$actor_strip_source_module\'(Source:Inner0, Inner) :- Source == ~q, !, \'$actor_strip_source_module\'(Inner0,Inner).~n', [Module]),
    format(Out, '\'$actor_strip_source_module\'(Term, Term) :- atomic(Term), !.~n', []),
    format(Out, '\'$actor_strip_source_module\'(Term0, Term) :- Term0 =.. [Functor|Args0], \'$actor_strip_source_args\'(Args0,Args), Term =.. [Functor|Args].~n', []),
    format(Out, '\'$actor_strip_source_args\'([], []).~n', []),
    format(Out, '\'$actor_strip_source_args\'([Arg0|Args0], [Arg|Args]) :- \'$actor_strip_source_module\'(Arg0,Arg), \'$actor_strip_source_args\'(Args0,Args).~n', []),
    format(Out, '\'$actor_clause_term\'(Head, true, Head) :- !.~n', []),
    format(Out, '\'$actor_clause_term\'(Head, Body, (Head :- Body)).~n', []),
    format(Out, '\'$actor_cleanup\' :- forall(retract(\'$actor_source_pi\'(Name/Arity)), (functor(Head, Name, Arity), retractall(Head))), retractall(\'$actor_dynamic_pi\'(_)), retractall(\'$actor_shared_pi\'(_)), retractall(\'$actor_loading_shared\').~n', []).

call_in_module(Module, Goal) :-
    Qualified = Module:Goal,
    call(Qualified).
