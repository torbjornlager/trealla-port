% SPDX-License-Identifier: MIT

:- module(sxml_parser,
       [ load_sxml_structure/2,
         sxml_parse_text/2,
         sxml_validate_stream/2,
         sxml_validate_text/2,
         validate_sxml_structure/1,
         xml_option/2,
         xml_option/3
       ]).

/** <module> Portable XML reader and SXML 0.2 validator

This is the small, pure-Prolog XML compatibility layer needed by the native
Trealla statechart port.  It deliberately returns the same tree shape used by
SWI-Prolog's `library(sgml)` with `load_structure/3`:

  `element(Name, [attribute(Value), ...], Children)`

The reader covers the XML constructs used by SXML documents: quoted
attributes, predefined and numeric entities, comments, processing
instructions, CDATA sections, empty elements, and nested elements.  The
validator implements the SXML 0.2 DTD constraints directly and then performs
the cross-reference checks that the SWI implementation applies after DTD
validation.
*/


load_sxml_structure(Stream, Content) :-
    stream_codes(Stream, Codes),
    parse_codes(Codes, Content),
    validate_sxml_structure(Content),
    !.

sxml_parse_text(Text, Content) :-
    text_codes(Text, Codes),
    parse_codes(Codes, Content).

sxml_validate_text(Text, Diagnostics) :-
    catch((sxml_parse_text(Text, Content), validate_sxml_structure(Content)),
          Error,
          validation_diagnostics(Error, Diagnostics0)),
    ( var(Diagnostics0) -> Diagnostics = [] ; Diagnostics = Diagnostics0 ).

sxml_validate_stream(Stream, Diagnostics) :-
    catch(load_sxml_structure(Stream, _), Error,
          validation_diagnostics(Error, Diagnostics0)),
    ( var(Diagnostics0) -> Diagnostics = [] ; Diagnostics = Diagnostics0 ).

validation_diagnostics(error(sxml_validation_error(Diagnostics), _), Diagnostics) :- !.
validation_diagnostics(Error, [diagnostic(error, unknown, Error)]).


                 /*******************************
                 *          XML READER           *
                 *******************************/

parse_codes(Codes0, [Root]) :-
    strip_bom(Codes0, Codes),
    phrase(xml_document(Root), Codes),
    !.
parse_codes(_, _) :-
    throw(error(syntax_error(xml_document),
                context(sxml_parser:sxml_parse_text/2,
                        'malformed XML document'))).

strip_bom([65279|Codes], Codes) :- !.
strip_bom(Codes, Codes).

xml_document(Root) --> xml_misc, xml_element(Root), xml_misc, eos.

xml_misc --> xml_space, !, xml_misc.
xml_misc --> xml_comment, !, xml_misc.
xml_misc --> xml_processing_instruction, !, xml_misc.
xml_misc --> [].

xml_element(element(Name, Attrs, [])) -->
    [60], xml_name(Name), xml_attributes(Attrs), xml_spaces, [47,62], !.
xml_element(element(Name, Attrs, Children)) -->
    [60], xml_name(Name), xml_attributes(Attrs), xml_spaces, [62],
    xml_children(Name, Children).

xml_children(Name, Children) -->
    [60,47], !, xml_name(Close), xml_spaces, [62],
    { same_close_name(Name, Close), Children = [] }.
xml_children(Name, Children) -->
    xml_comment, !, xml_children(Name, Children).
xml_children(Name, Children) -->
    xml_processing_instruction, !, xml_children(Name, Children).
xml_children(Name, [Text|Children]) -->
    [60,33,91,67,68,65,84,65,91], !,
    codes_until([93,93,62], Codes),
    { normalized_text(Codes, Text) },
    xml_children(Name, Children).
xml_children(Name, [Element|Children]) -->
    xml_element(Element), !,
    xml_children(Name, Children).
xml_children(Name, Children) -->
    text_until_tag(Codes),
    { decoded_normalized_text(Codes, Text) },
    xml_text_children(Text, Name, Children).

xml_text_children('', Name, Children) --> !, xml_children(Name, Children).
xml_text_children(Text, Name, [Text|Children]) --> xml_children(Name, Children).

same_close_name(Name, Name) :- !.
same_close_name(Name, Close) :-
    throw(error(syntax_error(mismatched_xml_tag(Name, Close)),
                context(sxml_parser:sxml_parse_text/2,
                        'opening and closing XML tags differ'))).

xml_attributes([Attr|Attrs]) -->
    xml_spaces1, xml_attribute(Attr), !, xml_attributes(Attrs).
xml_attributes([]) --> [].

xml_attribute(Attr) -->
    xml_name(Name), xml_spaces, [61], xml_spaces,
    xml_quoted_value(Value),
    { Attr = (Name=Value) }.

xml_quoted_value(Value) -->
    [34], !, quoted_codes(34, Codes),
    { decode_entities(Codes, Decoded), atom_codes(Value, Decoded) }.
xml_quoted_value(Value) -->
    [39], quoted_codes(39, Codes),
    { decode_entities(Codes, Decoded), atom_codes(Value, Decoded) }.

quoted_codes(Quote, []) --> [Quote], !.
quoted_codes(Quote, [C|Codes]) --> [C], quoted_codes(Quote, Codes).

xml_name(Name) -->
    [C], { xml_name_start(C) }, !,
    xml_name_rest(Cs),
    { atom_codes(Name, [C|Cs]) }.

xml_name_rest([C|Cs]) --> [C], { xml_name_char(C) }, !, xml_name_rest(Cs).
xml_name_rest([]) --> [].

xml_name_start(C) :- ascii_alpha(C), !.
xml_name_start(95).
xml_name_start(58).

xml_name_char(C) :- xml_name_start(C), !.
xml_name_char(C) :- C >= 48, C =< 57, !.
xml_name_char(45).
xml_name_char(46).

ascii_alpha(C) :- C >= 65, C =< 90, !.
ascii_alpha(C) :- C >= 97, C =< 122.

xml_spaces --> xml_space, !, xml_spaces.
xml_spaces --> [].

xml_spaces1 --> xml_space, xml_spaces.

xml_space --> [C], { xml_space_code(C) }.
xml_space_code(9).
xml_space_code(10).
xml_space_code(13).
xml_space_code(32).

xml_comment --> [60,33,45,45], codes_until([45,45,62], _).
xml_processing_instruction --> [60,63], codes_until([63,62], _).

codes_until(End, []) --> End, !.
codes_until(End, [C|Codes]) --> [C], codes_until(End, Codes).

text_until_tag([]) --> lookahead(60), !.
text_until_tag([C|Codes]) --> [C], { C =\= 60 }, text_until_tag(Codes).

lookahead(C, [C|Rest], [C|Rest]).
eos([], []).

decoded_normalized_text(Codes, Text) :-
    decode_entities(Codes, Decoded),
    normalized_text(Decoded, Text).

normalized_text(Codes0, Text) :-
    trim_xml_space(Codes0, Codes),
    collapse_xml_space(Codes, Normalized),
    atom_codes(Text, Normalized).

trim_xml_space(Codes0, Codes) :-
    drop_xml_space(Codes0, Front),
    reverse(Front, Reversed0),
    drop_xml_space(Reversed0, Reversed),
    reverse(Reversed, Codes).

drop_xml_space([C|Cs], Rest) :- xml_space_code(C), !, drop_xml_space(Cs, Rest).
drop_xml_space(Cs, Cs).

collapse_xml_space([], []).
collapse_xml_space([C|Cs], [32|Rest]) :-
    xml_space_code(C),
    !,
    drop_xml_space(Cs, More),
    collapse_xml_space(More, Rest).
collapse_xml_space([C|Cs], [C|Rest]) :- collapse_xml_space(Cs, Rest).

decode_entities([], []).
decode_entities([38|Codes0], [C|Codes]) :-
    !,
    ( take_entity(Codes0, Entity, Rest), entity_code(Entity, C)
    -> decode_entities(Rest, Codes)
    ;  throw(error(syntax_error(xml_entity),
                   context(sxml_parser:sxml_parse_text/2,
                           'unknown or unterminated XML entity')))
    ).
decode_entities([C|Codes0], [C|Codes]) :-
    decode_entities(Codes0, Codes).

take_entity([59|Rest], [], Rest) :- !.
take_entity([C|Codes], [C|Entity], Rest) :- take_entity(Codes, Entity, Rest).

entity_code([97,109,112], 38).
entity_code([108,116], 60).
entity_code([103,116], 62).
entity_code([113,117,111,116], 34).
entity_code([97,112,111,115], 39).
entity_code([35,120|Digits], Code) :- digits_value(Digits, 16, Code).
entity_code([35,88|Digits], Code) :- digits_value(Digits, 16, Code).
entity_code([35|Digits], Code) :- digits_value(Digits, 10, Code).

digits_value([D|Ds], Base, Value) :-
    digit_value(D, Digit), Digit < Base,
    digits_value_(Ds, Base, Digit, Value).

digits_value_([], _, Value, Value).
digits_value_([D|Ds], Base, Acc0, Value) :-
    digit_value(D, Digit), Digit < Base,
    Acc is Acc0*Base + Digit,
    digits_value_(Ds, Base, Acc, Value).

digit_value(D, V) :- D >= 48, D =< 57, !, V is D-48.
digit_value(D, V) :- D >= 65, D =< 70, !, V is D-65+10.
digit_value(D, V) :- D >= 97, D =< 102, V is D-97+10.

text_codes(Text, Codes) :- atom(Text), !, atom_codes(Text, Codes).
text_codes(Text, Codes) :- is_list(Text), !, text_list_codes(Text, Codes).
text_codes(Text, _) :-
    throw(error(type_error(text, Text), sxml_parser:sxml_parse_text/2)).

text_list_codes([], []).
text_list_codes([C|Cs], [C|Codes]) :- integer(C), !, text_list_codes(Cs, Codes).
text_list_codes(Chars, Codes) :- atom_chars(Atom, Chars), atom_codes(Atom, Codes).

stream_codes(Stream, Codes) :-
    get_code(Stream, Code),
    ( Code =:= -1 -> Codes = []
    ; Codes = [Code|Rest], stream_codes(Stream, Rest)
    ).


                 /*******************************
                 *       SXML 0.2 GRAMMAR        *
                 *******************************/

validate_sxml_structure(Content) :-
    ( Content = [element(statechart, RootAttrs, RootChildren)]
    -> true
    ;  structural_error(document_root, statechart)
    ),
    validate_element(statechart, RootAttrs, RootChildren),
    required_attribute(version, RootAttrs, Version, statechart),
    ( Version == '0.2' -> true
    ; semantic_error(statechart_version, Version,
                     'the supported SXML version is 0.2')
    ),
    required_attribute(initial, RootAttrs, RootInitial, statechart),
    root_identifier(RootAttrs, RootID),
    collect_identifiers(Content, [RootID-statechart], IdentifierPairs),
    unique_identifiers(IdentifierPairs),
    pairs_keys(IdentifierPairs, Identifiers),
    validate_reference(RootInitial, Identifiers, initial(statechart)),
    validate_initial_child(RootInitial, RootChildren, statechart),
    validate_semantics(Content, Identifiers).

validate_element(Name, Attrs, Children) :-
    element_contract(Name, Required, Allowed, Content),
    !,
    validate_attributes(Name, Attrs, Required, Allowed),
    validate_content(Content, Name, Children),
    validate_child_elements(Children).
validate_element(Name, _, _) :- structural_error(unknown_element, Name).

validate_child_elements([]).
validate_child_elements([element(Name, Attrs, Children)|Rest]) :- !,
    validate_element(Name, Attrs, Children),
    validate_child_elements(Rest).
validate_child_elements([Text|Rest]) :-
    atom(Text),
    validate_child_elements(Rest).

element_contract(statechart, [version,initial], [version,initial,id],
                 elements([datamodel,state,parallel,final])).
element_contract(state, [id], [id,initial],
                 elements([onentry,onexit,go,defer,spawn,datamodel,history,state,parallel,final])).
element_contract(parallel, [id], [id],
                 elements([onentry,onexit,go,defer,spawn,datamodel,history,state,parallel,final])).
element_contract(final, [id], [id], optional_one(onentry)).
element_contract(history, [id], [id,type], exactly_one(go)).
element_contract(go, [], [to,on,if,after], text).
element_contract(onentry, [], [], text).
element_contract(onexit, [], [], text).
element_contract(datamodel, [], [], text).
element_contract(defer, [on], [on,if], empty).
element_contract(spawn, [type], [type,options,goal,callback,state,children], text).

validate_attributes(Name, Attrs, Required, Allowed) :-
    attribute_names(Attrs, Names),
    unique_attribute_names(Names, Name),
    require_attributes(Required, Names, Name),
    allow_attributes(Names, Allowed, Name).

attribute_names([], []).
attribute_names([Name=_|Attrs], [Name|Names]) :- atom(Name), !,
    attribute_names(Attrs, Names).
attribute_names([Attr|_], _) :- structural_error(invalid_attribute, Attr).

unique_attribute_names([], _).
unique_attribute_names([Name|Names], Element) :-
    ( memberchk(Name, Names) -> structural_error(duplicate_attribute, Element-Name) ; true ),
    unique_attribute_names(Names, Element).

require_attributes([], _, _).
require_attributes([Name|Names], Present, Element) :-
    ( memberchk(Name, Present) -> true
    ; semantic_error(missing_attribute, Name, Element)
    ),
    require_attributes(Names, Present, Element).

allow_attributes([], _, _).
allow_attributes([Name|Names], Allowed, Element) :-
    ( memberchk(Name, Allowed) -> true
    ; structural_error(unknown_attribute, Element-Name)
    ),
    allow_attributes(Names, Allowed, Element).

validate_content(empty, Name, Children) :-
    ( Children == [] -> true ; structural_error(nonempty_element, Name) ).
validate_content(text, Name, Children) :-
    ( all_text(Children) -> true ; structural_error(element_not_allowed, Name) ).
validate_content(elements(Allowed), Name, Children) :-
    validate_allowed_children(Children, Allowed, Name).
validate_content(optional_one(Allowed), Name, Children) :-
    validate_allowed_children(Children, [Allowed], Name),
    length(Children, Count),
    ( Count =< 1 -> true ; structural_error(too_many_children, Name) ).
validate_content(exactly_one(Allowed), Name, Children) :-
    validate_allowed_children(Children, [Allowed], Name),
    ( Children = [element(Allowed,_,_)] -> true
    ; structural_error(required_child, Name-Allowed)
    ).

all_text([]).
all_text([Text|Rest]) :- atom(Text), all_text(Rest).

validate_allowed_children([], _, _).
validate_allowed_children([element(Name,_,_)|Rest], Allowed, Parent) :-
    ( memberchk(Name, Allowed) -> true
    ; structural_error(misplaced_element, Parent-Name)
    ),
    validate_allowed_children(Rest, Allowed, Parent).
validate_allowed_children([Text|_], _, Parent) :-
    structural_error(text_not_allowed, Parent-Text).


                 /*******************************
                 *       SEMANTIC CHECKS         *
                 *******************************/

root_identifier(Attrs, ID) :- xml_option(id(ID), Attrs, statechart_actor).

collect_identifiers([], Pairs, Pairs).
collect_identifiers([element(Name, Attrs, Children)|Rest], Pairs0, Pairs) :-
    ( memberchk(Name, [state, parallel, final, history])
    -> required_attribute(id, Attrs, ID, Name), Pairs1 = [ID-Name|Pairs0]
    ;  Pairs1 = Pairs0
    ),
    collect_identifiers(Children, Pairs1, Pairs2),
    collect_identifiers(Rest, Pairs2, Pairs).
collect_identifiers([_|Rest], Pairs0, Pairs) :-
    collect_identifiers(Rest, Pairs0, Pairs).

unique_identifiers([]).
unique_identifiers([ID-Kind|Rest]) :-
    ( memberchk(ID-OtherKind, Rest)
    -> semantic_error(duplicate_identifier, ID,
                      duplicate_identifier(Kind, OtherKind))
    ;  true
    ),
    unique_identifiers(Rest).

pairs_keys([], []).
pairs_keys([Key-_|Pairs], [Key|Keys]) :- pairs_keys(Pairs, Keys).

validate_semantics([], _).
validate_semantics([element(state, Attrs, Children)|Rest], Identifiers) :- !,
    ( has_state_child(Children)
    -> required_attribute(initial, Attrs, Initial, state),
       validate_reference(Initial, Identifiers, initial(state)),
       validate_initial_child(Initial, Children, state)
    ;  ( xml_option(initial(Initial), Attrs)
       -> validate_reference(Initial, Identifiers, initial(state)),
          validate_initial_child(Initial, Children, state)
       ;  true
       )
    ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(go, Attrs, Children)|Rest], Identifiers) :- !,
    validate_go_targets(Attrs, Identifiers),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(history, Attrs, Children)|Rest], Identifiers) :- !,
    xml_option(type(Type), Attrs, shallow),
    ( memberchk(Type, [shallow, deep]) -> true
    ; semantic_error(history_type, Type, 'the history type is shallow or deep')
    ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(spawn, Attrs, Children)|Rest], Identifiers) :- !,
    required_attribute(type, Attrs, Type, spawn),
    ( memberchk(Type, [actor, toplevel, server, supervisor, statechart]) -> true
    ; semantic_error(statechart_spawn_type, Type,
                     'supported spawn types are actor, toplevel, server, supervisor, and statechart')
    ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(_, _, Children)|Rest], Identifiers) :- !,
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([_|Rest], Identifiers) :- validate_semantics(Rest, Identifiers).

validate_go_targets(Attrs, Identifiers) :-
    ( xml_option(to(Targets), Attrs)
    -> target_list(Targets, TargetList),
       validate_targets(TargetList, Identifiers)
    ;  true
    ).

validate_targets([], _).
validate_targets([Target|Targets], Identifiers) :-
    validate_reference(Target, Identifiers, transition_target),
    validate_targets(Targets, Identifiers).

target_list(Targets, TargetList) :- atomic_list_concat(TargetList, ' ', Targets).

validate_reference(Reference, Identifiers, Role) :-
    ( memberchk(Reference, Identifiers) -> true
    ; semantic_error(unknown_identifier, Reference, Role)
    ).

validate_initial_child(Initial, Children, Owner) :-
    ( member(element(Name, Attrs, _), Children),
      memberchk(Name, [state, parallel, final]),
      xml_option(id(Initial), Attrs)
    -> true
    ;  semantic_error(initial_not_direct_child, Initial, Owner)
    ).

has_state_child(Children) :-
    member(element(Name, _, _), Children),
    memberchk(Name, [state, parallel, final]),
    !.

required_attribute(Name, Attrs, Value, Element) :-
    NameValue =.. [Name, Value],
    ( xml_option(NameValue, Attrs) -> true
    ; semantic_error(missing_attribute, Name, Element)
    ).

structural_error(Kind, Detail) :-
    throw(error(sxml_validation_error(
                    [diagnostic(error, unknown, Kind-Detail)]),
                context(sxml_parser:validate_sxml_structure/1,
                        'the document does not conform to the SXML 0.2 grammar'))).

semantic_error(Kind, Culprit, Detail) :-
    semantic_exception(Kind, Culprit, Exception),
    !,
    throw(error(Exception,
                context(sxml_parser:validate_sxml_structure/1, Detail))).
semantic_error(Kind, Culprit, Detail) :-
    throw(error(sxml_semantic_error(Kind, Culprit),
                context(sxml_parser:validate_sxml_structure/1, Detail))).

semantic_exception(missing_attribute, Attribute,
                   existence_error(attribute, Attribute)).
semantic_exception(statechart_version, Version,
                   domain_error(statechart_version, Version)).
semantic_exception(statechart_spawn_type, Type,
                   domain_error(statechart_spawn_type, Type)).


%!  xml_option(?Option, +Attributes) is semidet.
%!  xml_option(?Option, +Attributes, +Default) is det.
%
%   Read an attribute from the `Name=Value` representation returned by SWI's
%   XML parser. Compound `name(Value)` entries are accepted as well, making
%   the helper convenient at the Trealla/SWI model boundary.
xml_option(Option, Attributes) :-
    nonvar(Option),
    Option =.. [Name, Value],
    ( memberchk(Name=Value, Attributes)
    ; memberchk(Option, Attributes)
    ).

xml_option(Option, Attributes, Default) :-
    ( xml_option(Option, Attributes) -> true
    ; arg(1, Option, Default)
    ).
