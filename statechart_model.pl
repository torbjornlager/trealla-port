% SPDX-License-Identifier: MIT

:- module(statechart_model,
       [ statechart_compile_text/2,
         statechart_compile_stream/2,
         statechart_validate_text/2,
         statechart_validate_stream/2,
         statechart_spawn_source/3
       ]).

/** <module> Pure SXML 0.2 model compiler

Compile a validated SXML document into the same model terms used by the SWI
statechart interpreter.  The compiler has no global state: a future runtime
can install the returned terms in an actor-private namespace, and validation
can never leave half a model behind after an error.
*/

:- use_module(sxml_parser).

:- op(800,  xfx, !).
:- op(200,  xfx, @).
:- op(1000, xfy, if).


statechart_compile_text(Text, Model) :-
    sxml_parse_text(Text, Content),
    validate_sxml_structure(Content),
    compile_nodes(Content, null, 0, _Next, Model, []).

statechart_compile_stream(Stream, Model) :-
    load_sxml_structure(Stream, Content),
    compile_nodes(Content, null, 0, _Next, Model, []).

statechart_validate_text(Text, Diagnostics) :-
    sxml_validate_text(Text, Diagnostics).

statechart_validate_stream(Stream, Diagnostics) :-
    sxml_validate_stream(Stream, Diagnostics).


%!  statechart_spawn_source(+Options, -SourceGoal, -SpawnOptions) is det.
%
%   Split the required XML source from ordinary actor options. This mirrors
%   the public SWI statechart constructor contract.
statechart_spawn_source(Options, SourceGoal, SpawnOptions) :-
    remove_control_options(Options, Effective),
    partition_sources(Effective, Sources, SpawnOptions),
    ( Sources = [src_uri(URI)]
    -> SourceGoal = statechart_actor:interpret(URI)
    ; Sources = [src_text(Text)]
    -> SourceGoal = statechart_actor:interpret_text(Text)
    ; Sources == []
    -> throw(error(existence_error(option, src_uri_or_src_text),
                   context(statechart_actor:statechart_spawn/2,
                           'statechart_spawn/2 requires one src_uri/1 or src_text/1 option')))
    ; throw(error(domain_error(single_statechart_source_option, Sources),
                  context(statechart_actor:statechart_spawn/2,
                          'statechart_spawn/2 accepts only one source option')))
    ).

remove_control_options([], []).
remove_control_options([trace(_)|Options], Rest) :- !,
    remove_control_options(Options, Rest).
remove_control_options([Option|Options], [Option|Rest]) :-
    remove_control_options(Options, Rest).

partition_sources([], [], []).
partition_sources([Option|Options], [Option|Sources], Rest) :-
    statechart_source_option(Option), !,
    partition_sources(Options, Sources, Rest).
partition_sources([Option|Options], Sources, [Option|Rest]) :-
    partition_sources(Options, Sources, Rest).

statechart_source_option(src_uri(_)).
statechart_source_option(src_text(_)).


                 /*******************************
                 *        MODEL COMPILER         *
                 *******************************/

compile_nodes([], _, N, N, Facts, Facts).
compile_nodes([element(Name, Attrs, Children)|Nodes], Parent, N0, N,
              Facts0, Facts) :-
    compile_node(Name, Attrs, Children, Parent, ChildParent, N0, N1,
                 Facts0, Facts1),
    compile_nodes(Children, ChildParent, N1, N2, Facts1, Facts2),
    compile_nodes(Nodes, Parent, N2, N, Facts2, Facts).
compile_nodes([_|Nodes], Parent, N0, N, Facts0, Facts) :-
    compile_nodes(Nodes, Parent, N0, N, Facts0, Facts).

compile_node(statechart, Attrs, _, Parent, ID, N0, N,
             [n(N0,ID),state(ID,Parent),initial(Initial)|Facts], Facts) :-
    xml_option(initial(Initial), Attrs),
    xml_option(id(ID), Attrs, statechart_actor),
    N is N0+1.
compile_node(state, Attrs, Children, Parent, ID, N0, N,
             [n(N0,ID),state(ID,Parent)|Facts0], Facts) :-
    xml_option(id(ID), Attrs),
    N is N0+1,
    ( xml_option(initial(Initial), Attrs)
    -> Facts0 = [transition(init(ID),'',true,[Initial],[])|Facts]
    ;  Facts0 = Facts
    ),
    validate_compound_initial(Attrs, Children).
compile_node(parallel, Attrs, _, Parent, ID, N0, N,
             [n(N0,ID),parallel(ID,Parent)|Facts], Facts) :-
    xml_option(id(ID), Attrs),
    N is N0+1.
compile_node(final, Attrs, _, Parent, Parent, N0, N,
             [n(N0,ID),final(ID,Parent)|Facts], Facts) :-
    xml_option(id(ID), Attrs),
    N is N0+1.
compile_node(history, Attrs, _, Parent, Parent, N, N,
             [history(ID,Parent,Type)|Facts], Facts) :-
    xml_option(id(ID), Attrs),
    xml_option(type(Type), Attrs, shallow).
compile_node(go, Attrs, Children, Parent, Parent, N0, N, Facts0, Facts) :-
    transition_trigger(Attrs, Parent, Trigger, Bindings0, N0, N),
    xml_option(if(ConditionText), Attrs, true),
    text_term(ConditionText, Condition, Bindings1),
    unify_bindings(Bindings0, Bindings1, Bindings2),
    ( xml_option(to(Targets), Attrs)
    -> atomic_list_concat(TargetList, ' ', Targets)
    ;  TargetList = []
    ),
    children_actions(Children, Actions, Bindings2),
    transition_fact(Trigger, Parent, Condition, TargetList, Actions, Fact),
    Facts0 = [Fact|Facts].
compile_node(defer, Attrs, _, Parent, Parent, N, N,
             [defer(Parent,Event,Condition)|Facts], Facts) :-
    xml_option(on(EventText), Attrs),
    text_term(EventText, Event, Bindings0),
    xml_option(if(ConditionText), Attrs, true),
    text_term(ConditionText, Condition, Bindings1),
    unify_bindings(Bindings0, Bindings1, _).
compile_node(onentry, _, Children, Parent, Parent, N, N,
             [onentry(Parent,Actions)|Facts], Facts) :-
    children_actions(Children, Actions, []).
compile_node(onexit, _, Children, Parent, Parent, N, N,
             [onexit(Parent,Actions)|Facts], Facts) :-
    children_actions(Children, Actions, []).
compile_node(datamodel, _, Children, Parent, Parent, N, N, Facts0, Facts) :-
    ( children_text(Children, Text)
    -> Facts0 = [datamodel(Text)|Facts]
    ;  Facts0 = Facts
    ).
compile_node(spawn, Attrs, Children, Parent, Parent, N, N,
             [to_be_invoked(Parent,Type,Options)|Facts], Facts) :-
    xml_option(type(Type), Attrs),
    select_xml_attribute(type, Attrs, Type, OperandAttrs),
    spawn_options(Type, OperandAttrs, Children, Options).

validate_compound_initial(Attrs, Children) :-
    ( has_state_child(Children), \+ xml_option(initial(_), Attrs)
    -> throw(error(existence_error(attribute, initial),
                   context(statechart_model:statechart_compile_text/2,
                           'a compound <state> requires an initial attribute')))
    ; true
    ).

has_state_child(Children) :-
    member(element(Name,_,_), Children),
    memberchk(Name, [state,parallel,final]), !.

transition_trigger(Attrs, Parent, after(Key,Delay), [], N0, N) :-
    xml_option(after(DelayText), Attrs), !,
    ( xml_option(on(_), Attrs)
    -> throw(error(domain_error(statechart_transition_trigger,on_and_after),
                   context(statechart_model:statechart_compile_text/2,
                           '<go> cannot have both on and after attributes')))
    ; true
    ),
    parse_delay(DelayText, Delay),
    Key = after(Parent,N0),
    N is N0+1.
transition_trigger(Attrs, _, event(Event), Bindings, N, N) :-
    xml_option(on(EventText), Attrs, ''),
    text_term(EventText, Event, Bindings).

parse_delay(Value, Delay) :-
    ( number(Value) -> Delay0=Value
    ; atom(Value), catch(atom_number(Value,Delay0),_,fail)
    ),
    Delay0 >= 0, !,
    Delay=Delay0.
parse_delay(Value, _) :-
    throw(error(domain_error(non_negative_number,Value),
                context(statechart_model:statechart_compile_text/2,
                        'the after attribute is a delay in seconds'))).

transition_fact(event(Event), Parent, Cond, Targets, Actions,
                transition(Parent,Event,Cond,Targets,Actions)).
transition_fact(after(Key,Delay), Parent, Cond, Targets, Actions,
                after_transition(Parent,Key,Delay,Cond,Targets,Actions)).

children_actions([], [], _).
children_actions([Text|Children], [script(Action)|Actions], Bindings) :-
    atom(Text), Text \== '', !,
    text_term(Text, Action, NewBindings),
    unify_bindings(Bindings, NewBindings, _),
    children_actions(Children, Actions, Bindings).
children_actions([_|Children], Actions, Bindings) :-
    children_actions(Children, Actions, Bindings).

text_term('', '', []) :- !.
text_term(true, true, []) :- !.
text_term(Text, Term, Bindings) :- atom_to_term(Text, Term, Bindings).

unify_bindings(Bs1, Bs2, Bs3) :- unify_bindings_(Bs2, Bs1, Bs3, Bs1).
unify_bindings_([], _, Acc, Acc).
unify_bindings_([Name=Var|Rest], Existing, Bs3, Acc0) :-
    ( memberchk(Name=ExistingVar, Existing)
    -> Var=ExistingVar, Acc1=Acc0
    ;  Acc1=[Name=Var|Acc0]
    ),
    unify_bindings_(Rest, Existing, Bs3, Acc1).

children_text(Children, Text) :-
    text_children(Children, Atoms), Atoms \= [],
    atomic_list_concat(Atoms, '\n', Text).

text_children([], []).
text_children([Atom|Children], [Atom|Atoms]) :- atom(Atom), !,
    text_children(Children, Atoms).
text_children([_|Children], Atoms) :- text_children(Children, Atoms).


                 /*******************************
                 *        SPAWN ELEMENTS         *
                 *******************************/

spawn_options(Type, Attrs0, Children, Options) :-
    take_xml_attribute(options, Attrs0, OptionsText, Attrs1, '[]'),
    parse_options(OptionsText, Listed),
    required_spawn_options(Type, Attrs1, Attrs2, Required),
    reject_spawn_attributes(Type, Attrs2),
    append(Required, Listed, Options0),
    ( children_text(Children, Text)
    -> Options1=[src_text(Text)|Options0]
    ;  Options1=Options0
    ),
    validate_spawn_options(Type, Options1),
    Options=Options1.

take_xml_attribute(Name, Attrs0, Value, Attrs, Default) :-
    ( select_xml_attribute(Name, Attrs0, Value0, Rest)
    -> Value=Value0, Attrs=Rest
    ;  Value=Default, Attrs=Attrs0
    ).

select_xml_attribute(Name, [Name=Value|Attrs], Value, Attrs) :- !.
select_xml_attribute(Name, [Attr|Attrs0], Value, [Attr|Attrs]) :-
    select_xml_attribute(Name, Attrs0, Value, Attrs).

parse_options(Text, Options) :-
    catch(atom_to_term(Text, Term, _), _, fail), !,
    ( is_list(Term) -> Options=Term
    ; throw(error(type_error(list,Term),statechart_model:statechart_compile_text/2))
    ).
parse_options(Text, _) :-
    throw(error(syntax_error(spawn_options(Text)),
                statechart_model:statechart_compile_text/2)).

required_spawn_options(actor, Attrs0, Attrs, [goal(Goal)]) :-
    required_typed_attribute(goal, Attrs0, Attrs, Goal).
required_spawn_options(toplevel, Attrs, Attrs, []).
required_spawn_options(server, Attrs0, Attrs,
                       [callback(Callback),state(State)]) :-
    required_typed_attribute(callback, Attrs0, Attrs1, Callback),
    required_typed_attribute(state, Attrs1, Attrs, State).
required_spawn_options(supervisor, Attrs0, Attrs, [children(Children)]) :-
    required_typed_attribute(children, Attrs0, Attrs, Children),
    ( is_list(Children) -> true ; throw(error(type_error(list,Children),_)) ).
required_spawn_options(statechart, Attrs, Attrs, []).

required_typed_attribute(Name, Attrs0, Attrs, Value) :-
    ( select_xml_attribute(Name, Attrs0, Text, Attrs)
    -> atom_to_term(Text, Value, _)
    ; throw(error(existence_error(attribute,Name),
                  context(statechart_model:statechart_compile_text/2,
                          'missing required spawn attribute')))
    ).

reject_spawn_attributes(_, []).
reject_spawn_attributes(Type, [Name=_|_]) :-
    throw(error(domain_error(statechart_spawn_attribute(Type),Name),
                statechart_model:statechart_compile_text/2)).

validate_spawn_options(Type, Options) :-
    validate_spawn_options_(Options, Type),
    validate_statechart_source(Type, Options).

validate_spawn_options_([], _).
validate_spawn_options_([Option|Options], Type) :-
    ground(Option), allowed_spawn_option(Type,Option), !,
    validate_spawn_options_(Options, Type).
validate_spawn_options_([Option|_], Type) :-
    throw(error(domain_error(statechart_spawn_option(Type),Option),
                statechart_model:statechart_compile_text/2)).

allowed_spawn_option(actor,goal(Goal)) :- callable(Goal).
allowed_spawn_option(server,callback(Goal)) :- callable(Goal).
allowed_spawn_option(server,state(_)).
allowed_spawn_option(supervisor,children(Children)) :- is_list(Children).
allowed_spawn_option(_,monitor(B)) :- boolean(B).
allowed_spawn_option(_,link(B)) :- boolean(B).
allowed_spawn_option(_,node(_)).
allowed_spawn_option(_,io_target(_)).
allowed_spawn_option(_,src_text(_)).
allowed_spawn_option(_,src_uri(_)).
allowed_spawn_option(_,src_list(L)) :- is_list(L).
allowed_spawn_option(_,src_predicates(PIs)) :- is_list(PIs).
allowed_spawn_option(actor,target(_)).
allowed_spawn_option(toplevel,target(_)).
allowed_spawn_option(toplevel,session(B)) :- boolean(B).
allowed_spawn_option(toplevel,time_limit(L)) :- positive_limit(L).
allowed_spawn_option(toplevel,idle_limit(L)) :- positive_limit(L).
allowed_spawn_option(toplevel,name(N)) :- atomic(N).
allowed_spawn_option(server,name(N)) :- atomic(N).
allowed_spawn_option(supervisor,strategy(S)) :-
    memberchk(S,[one_for_one,one_for_all,rest_for_one]).
allowed_spawn_option(supervisor,intensity(I)) :- integer(I), I>0.
allowed_spawn_option(supervisor,period(P)) :- number(P), P>0.
allowed_spawn_option(supervisor,name(N)) :- atomic(N).
allowed_spawn_option(statechart,name(N)) :- atomic(N).
allowed_spawn_option(statechart,trace(B)) :- boolean(B).

boolean(true).
boolean(false).
positive_limit(infinite) :- !.
positive_limit(L) :- number(L), L>0.

validate_statechart_source(statechart, Options) :- !,
    statechart_sources(Options, Sources),
    ( Sources=[_] -> true
    ; Sources=[] -> throw(error(existence_error(option,src_uri_or_src_text),_))
    ; throw(error(domain_error(single_statechart_source_option,Sources),_))
    ).
validate_statechart_source(_, _).

statechart_sources([], []).
statechart_sources([Option|Options], [Option|Sources]) :-
    statechart_source_option(Option), !,
    statechart_sources(Options, Sources).
statechart_sources([_|Options], Sources) :- statechart_sources(Options, Sources).
