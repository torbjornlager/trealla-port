% Test-only cleanup controls for the cascade fixture's monitor scope.
:- consult('tests.pl').

monitor_scope_tests :-
    self(Self),
    setup_call_cleanup(monitor(Self,Unrelated),
      (with_mutex('$actor_registry',findall(R,actors:monitor(Self,_,R),Before)),
       Self ! down(Self,Unrelated,unrelated_probe),
       catch(t145_with_monitors([Self-_,Self-_,Self-_],throw(scope_probe)),E,true),
       E==scope_probe,
       with_mutex('$actor_registry',findall(R,actors:monitor(Self,_,R),AfterThrow)),
       Before==AfterThrow,
       \+t145_with_monitors([Self-_,Self-_,Self-_],fail),
       with_mutex('$actor_registry',findall(R,actors:monitor(Self,_,R),AfterFail)),
       Before==AfterFail,
       t145_with_monitors([Self-_,Self-_,Self-_],true),
       with_mutex('$actor_registry',findall(R,actors:monitor(Self,_,R),AfterSuccess)),
       Before==AfterSuccess,
       catch((t145_with_monitors([Self-_,Self-invalid_reference],true)
              -> SetupOutcome=unexpected_success ; SetupOutcome=failed),
             SetupError,SetupOutcome=exception(SetupError)),
       SetupOutcome\==unexpected_success,
       with_mutex('$actor_registry',findall(R,actors:monitor(Self,_,R),AfterSetup)),
       Before==AfterSetup,
       receive({down(Self,Unrelated,unrelated_probe)->true},[timeout(1),on_timeout(fail)])),
      demonitor(Unrelated,[flush])),
    writeln('Cascade monitor scope: success/failure/exception/setup cleanup preserves unrelated state').
