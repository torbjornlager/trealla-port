% SPDX-License-Identifier: MIT
:- module(remote_io_output_tests, [run/0]).
:- use_module(actors).
:- use_module(distribution).

run :-
    expect(actors:hook_terminal_stream('@'('$io_endpoint'(probe),'https://n3.example'))),
    expect(\+ actors:hook_terminal_stream(not_a_terminal)),
    payload(io, hello, hello),
    payload(io_line, hello, 'hello\n'),
    payload(io, 'a\nb', 'a\nb'),
    payload(io_line, 'a\n', 'a\n\n'),
    payload(io_line, 'å é', 'å é\n'),
    payload(io, [a,b], '[a,b]'),
    payload(io_line, pair(1,2), 'pair(1,2)\n'),
    expect(distribution:io_wire_message(terminal_io_output(42,old),terminal_io_output(42,old),[])),
    expect(distribution:io_wire_message('$input_prompt'(42,ref,prompt),prompt(42,ref,prompt),[prompt_mode-string_atom(correlated)])),
    writeln('Remote terminal stream: 11 checks passed').

payload(Source,Term,Expected) :-
    expect(distribution:io_wire_message(terminal_io_output(42,'$terminal_stream'(Source,Term)),terminal_io_output(42,Text),[])),
    expect(Text==Expected).
expect(Goal) :- (call(Goal) -> true ; throw(remote_io_output_test_failed(Goal))).
