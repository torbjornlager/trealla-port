% SPDX-License-Identifier: MIT
:- module(json_wire,[decode_json_atom/2]).
:- use_module(library(json), []).

% Keep the wire error contract across bundled JSON grammars: older versions
% decode UTF-16 code units, newer versions combine pairs and fail on lone
% surrogates. Validate escapes first, then normalize older grammar output.
% Escaped backslashes and constructed numeric lists stay data.
decode_json_atom(Atom, JSON) :-
    atom_chars(Atom, Chars),
    validate_escapes(Chars, outside),
    once(phrase(json:json_chars(Raw), Chars)),
    scalar_json(Raw, JSON).

% Inspect only JSON string escapes, skipping escaped backslashes and quotes.
validate_escapes([], _).
validate_escapes(['"'|Cs], outside) :- !, validate_escapes(Cs, inside).
validate_escapes(['"'|Cs], inside) :- !, validate_escapes(Cs, outside).
validate_escapes(['\\',u,A,B,C,D|Cs], inside) :-
    hex_code(A,B,C,D,Code), !,
    ( Code >= 55296, Code =< 56319
    -> ( Cs=['\\',u,E,F,G,H|Rest],hex_code(E,F,G,H,Low),
         Low >= 56320, Low =< 57343
       -> validate_escapes(Rest, inside)
       ; invalid_surrogate )
    ; Code >= 56320, Code =< 57343
    -> invalid_surrogate
    ; validate_escapes(Cs, inside)
    ).
validate_escapes(['\\',_|Cs], inside) :- !, validate_escapes(Cs, inside).
validate_escapes([_|Cs], State) :- validate_escapes(Cs, State).

hex_code(A,B,C,D,Code) :-
    hex_digit(A,W),hex_digit(B,X),hex_digit(C,Y),hex_digit(D,Z),
    Code is W*4096+X*256+Y*16+Z.
hex_digit(Char, Digit) :-
    char_code(Char, Code),
    ( Code >= 48, Code =< 57 -> Digit is Code-48
    ; Code >= 65, Code =< 70 -> Digit is Code-55
    ; Code >= 97, Code =< 102 -> Digit is Code-87
    ).

scalar_json(string(Chars),string(Scalars)) :- !, scalar_chars(Chars,Scalars).
scalar_json(list(Values),list(Scalars)) :- !, scalar_values(Values,Scalars).
scalar_json(pairs(Pairs),pairs(Scalars)) :- !, scalar_pairs(Pairs,Scalars).
scalar_json(Value,Value).
scalar_values([],[]).
scalar_values([V|Vs],[S|Ss]) :- scalar_json(V,S),scalar_values(Vs,Ss).
scalar_pairs([],[]).
scalar_pairs([K-V|Ps],[SK-SV|Ss]) :-
    scalar_json(K,SK),scalar_json(V,SV),scalar_pairs(Ps,Ss).

scalar_chars([],[]).
scalar_chars([C|Cs],[Scalar|Scalars]) :-
    char_code(C,Code),
    ( Code >= 55296, Code =< 56319
    -> (Cs=[Low|Rest],char_code(Low,LowCode),LowCode>=56320,LowCode=<57343
       -> ScalarCode is 65536+(Code-55296)*1024+LowCode-56320,
          char_code(Scalar,ScalarCode),scalar_chars(Rest,Scalars)
       ; invalid_surrogate)
    ; Code >= 56320, Code =< 57343
    -> invalid_surrogate
    ; Scalar=C,scalar_chars(Cs,Scalars)
    ).
invalid_surrogate :-
    throw(error(syntax_error(json_unicode_surrogate),json_wire:decode_json_atom/2)).
