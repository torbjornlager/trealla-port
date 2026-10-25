:- use_module(library(json)).
code(C,N):-char_code(C,N).
probe(Label,Wire):-atom_chars(Wire,Cs),phrase(json_chars(string(Chars)),Cs),maplist(code,Chars,Codes),writeq(decoded(Label,Codes)),nl,atom_chars(Goal,Chars),catch((read_term_from_atom(Goal,T,[]),call(T),writeq(result(Label,pass))),E,writeq(result(Label,E))),nl.
main:-probe(ascii_raw,'"\\"ab\\"==[''a'',''b'']"'),probe(ascii_escaped,'"\\"ab\\"==[''a'',''b'']"'),probe(bmp_raw,'"\\"å\\"==[''å'']"'),probe(bmp_escaped,'"\\"\\u00e5\\"==[''\\u00e5'']"'),probe(supplementary_raw,'"\\"😀\\"==[''😀'']"'),probe(supplementary_escaped,'"\\"\\ud83d\\ude00\\"==[''\\ud83d\\ude00'']"'),probe(last_scalar_raw,'"\\"􏿿\\"==[''􏿿'']"'),probe(last_scalar_escaped,'"\\"\\udbff\\udfff\\"==[''\\udbff\\udfff'']"'),halt.
