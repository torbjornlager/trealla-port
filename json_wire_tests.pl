% SPDX-License-Identifier: MIT
:- module(json_wire_tests,[run/0]).
:- use_module(json_wire).

run :-
    escaped([d,'8','3',d],H),escaped([d,e,'0','0'],L),append(H,L,Pair),
    quoted(Pair,Input),decode_json_atom(Input,string(['😀'])),
    % Keys and nested arrays pass through the same scalar conversion.
    atom_chars(Object,['{','"','\\',u,d,'8','3',d,'\\',u,d,e,'0','0','"',':','[','"','\\',u,d,'8','3',d,'\\',u,d,e,'0','0','"',',','1',']','}']),
    decode_json_atom(Object,pairs([string(['😀'])-list([string(['😀']),number(1)])])),
    quoted(['\\','\\',u,d,'8','3',d],Literal),
    decode_json_atom(Literal,string(['\\',u,d,'8','3',d])),
    quoted(H,High),rejected(High),quoted(L,Low),rejected(Low),
    append(L,H,Reversed),quoted(Reversed,WrongOrder),rejected(WrongOrder),
    escaped([d,b,f,f],MaxH),escaped([d,f,f,f],MaxL),append(MaxH,MaxL,MaxPair),
    quoted(MaxPair,MaxInput),decode_json_atom(MaxInput,string([Max])),
    char_code(Max,1114111),
    append(H,[a],Broken),quoted(Broken,Bad),rejected(Bad),
    decode_json_atom('"é"',string([e,'́'])),
    writeln('JSON wire Unicode scalar decoding: all regressions passed').
escaped(Hex,['\\',u|Hex]).
quoted(Chars,Atom) :- append(['"'|Chars],['"'],All),atom_chars(Atom,All).
rejected(Atom) :-
    catch((decode_json_atom(Atom,_),fail),
          error(syntax_error(json_unicode_surrogate),json_wire:decode_json_atom/2),
          true).
