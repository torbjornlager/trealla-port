:- use_module('../../web_prolog.pl').
run :-
    isolation:prepare_actor(9999999999,user,[src_text('probe_marker.')],M),
    writeq(before_qualification(M)),nl,flush_output,
    isolation:call_in_module(M,'$actor_qualify_receive'(Variable,Qualified)),
    writeq(after_qualification(Variable,Qualified)),nl,halt.
