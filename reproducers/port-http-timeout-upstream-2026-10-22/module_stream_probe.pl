% Standalone diagnostic: no Web Prolog imports.
:- module(module_stream_probe,[run/0]).
run :- findall(S,stream_property(S,mode(_)),Streams),writeq(Streams),nl.
