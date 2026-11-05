% SPDX-License-Identifier: MIT
:- module(browser_context_tests,[run/0]).
:- use_module(namespace_tests).
:- use_module(distribution).

run :-
    namespace_tests:new_scope(NS,P),namespace_tests:new_scope(OtherNS,Other),
    setup_call_cleanup(true,
      (web_prolog:import_browser_pids(Variable,P,Imported),var(Variable),var(Imported),Variable==Imported,
       web_prolog:import_browser_pids(main@localhost,P,'$web_prolog_endpoint'(P,main)),
       web_prolog:import_browser_pids(statechart@localhost,P,'$web_prolog_endpoint'(P,statechart)),
       namespace_tests:run_scope(P,register(context_alias,701@'http://example.invalid'),ok),
       namespace_tests:run_scope(Other,register(context_alias,702@'http://example.invalid'),ok),
       web_prolog:object([request_id-string_atom(denied)],Denied),
       catch(web_prolog:dispatch(context_close,Denied,P,P,actor,blacklist),E,true),
       E=error(permission_error(use,browser_context,context_close),_),
       \+actors:closed_registry_namespace(NS),
       assertz(web_prolog:browser_context_transport(P)),
       web_prolog:object([request_id-string_atom(closed)],JSON),
       web_prolog:dispatch(context_close,JSON,P,P,actor,blacklist),
       namespace_tests:run_scope(P,receive({'$context_closed'(closed)->true},[timeout(1),on_timeout(fail)]),ok),
       namespace_tests:run_scope(P,whereis(context_alias,undefined),ok),
       namespace_tests:run_scope(Other,whereis(context_alias,702@'http://example.invalid'),ok),
       namespace_tests:run_scope(P,true,ok),
       catch(web_prolog:require_open_browser_context(P),Closed,true),
       Closed=error(permission_error(register,closed_namespace,NS),_),
       web_prolog:relay_scope_admission('$ws_command'(send,unused),NS),
       catch(web_prolog:relay_scope_admission('$spawn'(a,b,c,d),NS),Late,true),
       Late=error(permission_error(register,closed_namespace,NS),_),
       web_prolog:dispatch(context_close,JSON,P,P,actor,blacklist),
       writeln('Browser context transport: own scopes, survivor, isolation, admission, variable integrity and special recipients passed')),
      (retractall(web_prolog:browser_context_transport(P)),
       web_prolog:retire_websocket_namespace(OtherNS),
       namespace_tests:stop_scope(P),namespace_tests:stop_scope(Other))).
