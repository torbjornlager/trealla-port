% SPDX-License-Identifier: MIT

:- module(sxml_parser_tests, [run_sxml_parser_tests/0]).

:- use_module(sxml_parser).
:- use_module(statechart_model).

run_sxml_parser_tests :-
    test_swi_tree_shape,
    test_cdata_and_entities,
    test_semantic_validation,
    test_structural_validation,
    test_model_compilation,
    test_history_transition_owner,
    format("All SXML parser and validator tests passed.~n").

test_swi_tree_shape :-
    Text = '<?xml version="1.0"?><!-- chart --><statechart version="0.2" initial="s"><state id="s"><onentry>output(ok)</onentry></state></statechart>',
    sxml_parse_text(Text, Tree),
    Tree == [element(statechart,
                     [version='0.2',initial=s],
                     [element(state,[id=s],
                              [element(onentry,[],['output(ok)'])])])],
    validate_sxml_structure(Tree),
    format("sxml SWI-compatible element tree ok~n").

test_cdata_and_entities :-
    Text = '<statechart version="0.2" initial="s"><state id="s"><go to="s" if="X &gt;= 1">X =&lt; 2</go><spawn type="statechart"><![CDATA[<statechart version="0.2" initial="c"><final id="c"/></statechart>]]></spawn></state></statechart>',
    sxml_parse_text(Text, Tree),
    Tree = [element(statechart,_,[element(state,_,Children)])],
    member(element(go, GoAttrs, ['X =< 2']), Children),
    memberchk(if='X >= 1', GoAttrs),
    member(element(spawn, _, [Nested]), Children),
    Nested == '<statechart version="0.2" initial="c"><final id="c"/></statechart>',
    validate_sxml_structure(Tree),
    format("sxml CDATA and entity decoding ok~n").

test_semantic_validation :-
    Invalid = '<statechart version="0.2" initial="missing"><state id="s"/></statechart>',
    sxml_validate_text(Invalid, Diagnostics),
    Diagnostics = [diagnostic(error,unknown,error(sxml_semantic_error(unknown_identifier,missing),_))],
    format("sxml semantic reference validation ok~n").

test_structural_validation :-
    Unknown = '<statechart version="0.2" initial="s"><state id="s"><bogus/></state></statechart>',
    sxml_validate_text(Unknown, UnknownDiagnostics),
    UnknownDiagnostics \= [],
    Misplaced = '<statechart version="0.2" initial="s"><go/><state id="s"/></statechart>',
    sxml_validate_text(Misplaced, MisplacedDiagnostics),
    MisplacedDiagnostics \= [],
    format("sxml structural grammar validation ok~n").

test_model_compilation :-
    Text = '<statechart version="0.2" initial="idle"><datamodel>:- dynamic count/1.</datamodel><state id="idle"><go on="start(N)" if="N > 0" to="running">assertz(count(N))</go></state><state id="running"><go after="0.25" to="done"/></state><final id="done"/></statechart>',
    statechart_compile_text(Text, Model),
    memberchk(state(statechart_actor,null), Model),
    memberchk(initial(idle), Model),
    memberchk(datamodel(':- dynamic count/1.'), Model),
    member(transition(idle,start(N),Guard,[running],[script(Action)]), Model),
    Guard == (N > 0),
    Action == assertz(count(N)),
    member(after_transition(running,_,0.25,true,[done],[]), Model),
    memberchk(final(done,statechart_actor), Model),
    format("sxml pure statechart model compilation ok~n").

test_history_transition_owner :-
 statechart_compile_text('<statechart version="0.2" initial="p"><state id="p" initial="s"><history id="h"><go to="s"/></history><state id="s"/></state></statechart>',Model),
 memberchk(transition(h,'',true,[s],[]),Model),
 \+memberchk(transition(p,'',true,[s],[]),Model),
 writeln('history default transition belongs to history node: ok').
