% SPDX-License-Identifier: MIT

:- module(resource_policy,
       [ configure_resource_policy/2,
         current_resource_policy/1,
         default_resource_policy/1,
         reset_resource_policy/0,
         policy_time_limit/2,
         policy_idle_limit/2,
         effective_time_limit/2,
         effective_idle_limit/2,
         effective_solution_limit/2,
         create_resource_timer/2,
         disarm_resource_timer/1,
         normalize_resource_exception/2,
         check_term_text_size/2,
         check_source_options_size/1,
         check_ws_frame_size/1,
         resource_websocket_options/2
       ]).

/** <module> Resource governance for a public Trealla node

This module owns the resource ceilings that Trealla can currently enforce
reliably: execution wall time, PTCP idle time, live actor count, result page
size, and textual request/source/WebSocket sizes.  The policy is process-wide,
matching the port's current single-node-per-process runtime state.

Trealla v3.12.6 has neither `call_with_inference_limit/3` nor a supported
`stack_limit/1` thread option.  Those SWI ceilings therefore remain deployment
and upstream-runtime concerns; they are not silently approximated here. Its
public time-limit wrapper also commits to one solution, so pageable calls use
the reusable internal alarm for each active computation slice and cancel it
while waiting for the next page command.
*/

:- use_module(library(error)).

:- dynamic active_resource_policy/1.

:- multifile actors:hook_admit_spawn/2.

actors:hook_admit_spawn(LiveCount, _Options) :-
    current_resource_policy(resource_policy(_,_,Max,_,_,_,_)),
    integer(Max),
    LiveCount >= Max,
    throw(error(resource_error(actors),
                context(actors:spawn/3, 'node actor limit reached'))).

default_resource_policy(
    resource_policy(300, 300, 256, 1000, 32768, 262144, 262144)).

reset_resource_policy :-
    default_resource_policy(Policy),
    retractall(active_resource_policy(_)),
    assertz(active_resource_policy(Policy)).

current_resource_policy(Policy) :-
    active_resource_policy(Policy),
    !.
current_resource_policy(Policy) :-
    default_resource_policy(Policy).

configure_resource_policy(Options, Policy) :-
    default_resource_policy(Default),
    Default = resource_policy(DTime,DIdle,DActors,DSolutions,DTerm,DSource,DFrame),
    option(time_limit(Time0), Options, DTime),
    option(idle_limit(Idle0), Options, DIdle),
    option(max_actors(Actors0), Options, DActors),
    option(max_solutions(Solutions0), Options, DSolutions),
    option(max_term_text_bytes(Term0), Options, DTerm),
    option(max_source_text_bytes(Source0), Options, DSource),
    option(max_ws_frame_bytes(Frame0), Options, DFrame),
    normalize_seconds(time_limit, Time0, Time),
    normalize_seconds(idle_limit, Idle0, Idle),
    normalize_count(max_actors, Actors0, Actors),
    normalize_count(max_solutions, Solutions0, Solutions),
    normalize_bytes(max_term_text_bytes, Term0, Term),
    normalize_bytes(max_source_text_bytes, Source0, Source),
    normalize_bytes(max_ws_frame_bytes, Frame0, Frame),
    Policy = resource_policy(Time,Idle,Actors,Solutions,Term,Source,Frame),
    retractall(active_resource_policy(_)),
    assertz(active_resource_policy(Policy)).

normalize_seconds(_, infinite, infinite) :- !.
normalize_seconds(_Name, Value, Value) :- number(Value), Value > 0, !.
normalize_seconds(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                context(resource_policy:configure_resource_policy/2,
                        'expected positive seconds or infinite'))).

normalize_count(_, unlimited, unlimited) :- !.
normalize_count(_Name, Value, Value) :- integer(Value), Value > 0, !.
normalize_count(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                context(resource_policy:configure_resource_policy/2,
                        'expected a positive integer or unlimited'))).

normalize_bytes(_Name, Value, Value) :- integer(Value), Value > 0, !.
normalize_bytes(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                context(resource_policy:configure_resource_policy/2,
                        'expected a positive byte count'))).

policy_time_limit(resource_policy(Time,_,_,_,_,_,_), Time).
policy_idle_limit(resource_policy(_,Idle,_,_,_,_,_), Idle).

effective_time_limit(Requested0, Effective) :-
    current_resource_policy(Policy), policy_time_limit(Policy, Owner),
    normalize_seconds(time_limit, Requested0, Requested),
    tighter_limit(Owner, Requested, Effective).

effective_idle_limit(Requested0, Effective) :-
    current_resource_policy(Policy), policy_idle_limit(Policy, Owner),
    normalize_seconds(idle_limit, Requested0, Requested),
    tighter_limit(Owner, Requested, Effective).

tighter_limit(infinite, Requested, Requested) :- !.
tighter_limit(Owner, infinite, Owner) :- !.
tighter_limit(Owner, Requested, Effective) :- Effective is min(Owner, Requested).

effective_solution_limit(Requested0, Effective) :-
    normalize_positive_integer(limit, Requested0, Requested),
    current_resource_policy(resource_policy(_,_,_,Owner,_,_,_)),
    ( Owner == unlimited -> Effective = Requested
    ; Effective is min(Owner, Requested)
    ).

normalize_positive_integer(_, Value, Value) :- integer(Value), Value > 0, !.
normalize_positive_integer(Name, Value, _) :-
    throw(error(domain_error(Name, Value), resource_policy)).

create_resource_timer(infinite, none) :- !.
create_resource_timer(Limit, timer(Timer)) :-
    seconds_milliseconds(Limit, Milliseconds),
    once('$alarm'(Milliseconds, Timer)).

disarm_resource_timer(none) :- !.
disarm_resource_timer(timer(Timer)) :- once('$alarm'(0, Timer)).

seconds_milliseconds(Seconds, Milliseconds) :-
    Milliseconds0 is truncate(Seconds * 1000.0),
    ( Milliseconds0 < 1 -> Milliseconds = 1 ; Milliseconds = Milliseconds0 ).

normalize_resource_exception(error(time_limit_exceeded(_, _), _),
                             error(resource_error(time), resource_policy)) :- !.
normalize_resource_exception(time_limit_exceeded,
                             error(resource_error(time), resource_policy)) :- !.
normalize_resource_exception(error(resource_error(Resource), _),
                             error(resource_error(space), resource_policy)) :-
    memberchk(Resource, [space,stack,memory,heap,trail,global_stack,local_stack]),
    !.
normalize_resource_exception(Error, Error).

check_term_text_size(Field, Text) :-
    current_resource_policy(resource_policy(_,_,_,_,Limit,_,_)),
    check_text_size(Field, Text, Limit).

check_source_options_size([]).
check_source_options_size([src_text(Text)|Options]) :- !,
    current_resource_policy(resource_policy(_,_,_,_,_,Limit,_)),
    check_text_size(src_text, Text, Limit),
    check_source_options_size(Options).
check_source_options_size([src_list(Terms)|Options]) :- !,
    format(atom(Text), '~q', [Terms]),
    current_resource_policy(resource_policy(_,_,_,_,_,Limit,_)),
    check_text_size(src_list, Text, Limit),
    check_source_options_size(Options).
check_source_options_size([_|Options]) :- check_source_options_size(Options).

check_ws_frame_size(Text) :-
    current_resource_policy(resource_policy(_,_,_,_,_,_,Limit)),
    check_text_size(ws_frame, Text, Limit).

check_text_size(Field, Text, Limit) :-
    text_codes(Text, Codes), utf8_size(Codes, Size),
    ( Size =< Limit -> true
    ; throw(error(resource_error(input_size(Field, Size, Limit)),
                  resource_policy))
    ).

text_codes(Text, Codes) :- atom(Text), !, atom_codes(Text, Codes).
text_codes(Text, Codes) :- string(Text), !, string_codes(Text, Codes).
text_codes(Text, Codes) :- is_list(Text), !,
    ( Text = [C|_], integer(C) -> Codes = Text
    ; atom_chars(Atom, Text), atom_codes(Atom, Codes)
    ).
text_codes(Text, _) :- throw(error(type_error(text, Text), resource_policy)).

utf8_size([], 0).
utf8_size([Code|Codes], Size) :-
    utf8_width(Code, Width), utf8_size(Codes, Rest), Size is Width + Rest.

utf8_width(Code, 1) :- integer(Code), Code >= 0, Code =< 0x7f, !.
utf8_width(Code, 2) :- integer(Code), Code =< 0x7ff, !.
utf8_width(Code, 3) :- integer(Code), Code =< 0xffff, !.
utf8_width(Code, 4) :- integer(Code), Code =< 0x10ffff, !.
utf8_width(Code, _) :- throw(error(representation_error(character_code(Code)), resource_policy)).

resource_websocket_options(Options0, Options) :-
    current_resource_policy(resource_policy(_,_,_,_,_,_,Limit)),
    ( select(max_payload_length(Requested), Options0, Rest)
    -> normalize_bytes(max_payload_length, Requested, Checked),
       Effective is min(Limit, Checked),
       Options = [max_payload_length(Effective)|Rest]
    ; Options = [max_payload_length(Limit)|Options0]
    ).

:- initialization(reset_resource_policy).
