% SPDX-License-Identifier: MIT
:- module(json_wire,[decode_json_atom/2]).
:- use_module(library(json), []).

% Trealla's bundled JSON grammar decodes each UTF-16 escape separately.
% Recombine surrogate pairs at the protocol boundary, before strings become
% Prolog source. Escaped backslashes and constructed numeric lists stay data.
decode_json_atom(Atom, JSON) :-
    atom_chars(Atom, Chars),
    once(phrase(json:json_chars(Raw), Chars)),
    scalar_json(Raw, JSON).

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
