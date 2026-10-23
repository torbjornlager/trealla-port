% Standalone import variants: no Web Prolog framework imports.
:- use_module('../port-promise-callback-hang-2026-10-22/state-library.pl').
import_variant(Kind,Path) :-
    assertz(callback_probe_state:state(kept)),
    '$create_module'(import_verifier),
    (Kind==reexport -> Directive=reexport ; Directive=use_module),
    (Kind==selective -> Suffix=', [state/1]' ; Suffix=''),
    format(atom(Text),':- ~w(~q~w).',[Directive,Path,Suffix]),
    atom_chars(Text,Chars),
    (Kind==thread ->
        thread_create(load_text(Chars,[module(import_verifier)]),T,[]),thread_join(T,true)
    ; load_text(Chars,[module(import_verifier)])),
    findall(X,callback_probe_state:state(X),Rows),Rows==[kept],
    import_verifier:state(kept),
    writeln('all assertions passed').
