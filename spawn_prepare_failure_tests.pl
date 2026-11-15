% SPDX-License-Identifier: MIT
:- module(spawn_prepare_failure_tests,[run/0]).
:- use_module(actors).

% A failing source directive is reported to the creating client as
% error(directive_failed(Directive), _) and no actor is created. Before this
% rule the parent waited forever in spawn/3. Any other preparation failure is
% still answered by the guard in isolation:prepare_actor_and_signal/8.
run :-
    catch(spawn(true,_,[src_text(':- fail.'),link(false)]),Failed,true),
    Failed = error(Formal,_), Formal == directive_failed(fail),
    catch(spawn(true,_,[src_text('p(1). :- p(2). q.'),link(false)]),Later,true),
    Later = error(LaterFormal,_), LaterFormal == directive_failed(p(2)),
    self(Parent),
    spawn(send(Parent,loaded),_,[src_text('p(1). :- p(1). q.'),link(false)]),
    receive({loaded -> true},[timeout(2),on_timeout(fail)]),
    catch(spawn(true,_,[src_text(':- throw(boom).'),link(false)]),Thrown,true),
    Thrown == boom,
    catch(spawn(true,_,[src_text(':- fail.'),link(false),monitor(true)]),
          Monitored,true),
    Monitored == Failed,
    receive({down(_,_,exception(Reason)) -> Reason == Failed},
            [timeout(2),on_timeout(fail)]),
    self(Self),
    spawn(send(Self,ready),_,[src_text('ready_marker.'),link(false)]),
    receive({ready -> true},[timeout(2),on_timeout(fail)]),
    writeln('Failing source preparation answers the parent; later spawns still work: passed').
