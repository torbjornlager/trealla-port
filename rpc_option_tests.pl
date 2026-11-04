% SPDX-License-Identifier: MIT
:- use_module(rpc).
:- use_module(actors,[make_ref/1]).

:- meta_predicate expect_client_error(0,?,+).
expect_client_error(Goal,Formal,PI) :-
    catch(call(Goal),Error,true),
    nonvar(Error),Error=error(Formal,context(PI,'invalid client option')).

rpc_option_tests :-
    option_shape_errors,
    option_value_errors,
    option_no_resource_side_effects,
    option_yield_retry,
    option_supported_vectors,
    writeln('RPC client option validation: all regressions passed').

option_shape_errors :-
    expect_client_error(rpc('http://invalid',true,[unknown(1)]),
        domain_error(rpc_option,unknown(1)),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[template(x)]),
        domain_error(rpc_option,template(x)),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[offset(0)]),
        domain_error(rpc_option,offset(0)),rpc:rpc/3),
    expect_client_error(promise('http://invalid',true,_,[once(true,false)]),
        domain_error(promise_option,once(true,false)),rpc:promise/4),
    expect_client_error(rpc('http://invalid',true,[limit(1)|bad]),
        type_error(list,_),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,Options),instantiation_error,rpc:rpc/3),var(Options),
    expect_client_error(promise('http://invalid',true,_,[Option]),instantiation_error,rpc:promise/4),var(Option),
    expect_client_error(promise('http://invalid',true,_,[post(atom(x))]),
        domain_error(promise_option,post(atom(x))),rpc:promise/4),
    expect_client_error(promise('http://invalid',true,_,[status_code(_)]),
        domain_error(promise_option,status_code(_)),rpc:promise/4),
    writeln('unknown, ineffective, output and malformed options: ok').

option_value_errors :-
    expect_client_error(rpc('http://invalid',true,[once(true),once(maybe)]),
        domain_error(boolean,maybe),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[once(_)]),
        instantiation_error,rpc:rpc/3),
    expect_client_error(promise('http://invalid',true,_,[once(false),once(maybe)]),
        domain_error(boolean,maybe),rpc:promise/4),
    expect_client_error(promise('http://invalid',true,_,[once(_)]),
        instantiation_error,rpc:promise/4),
    expect_client_error(rpc('http://invalid',true,[limit(1),limit(0)]),
        domain_error(positive_integer,0),rpc:rpc/3),
    expect_client_error(promise('http://invalid',true,_,[offset(-1)]),
        domain_error(not_less_than_zero,-1),rpc:promise/4),
    expect_client_error(rpc('http://invalid',true,[timeout(bad)]),
        type_error(number,bad),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[redirect(true),redirect(maybe)]),
        domain_error(rpc_option,redirect(true)),rpc:rpc/3),
    expect_client_error(promise('http://invalid',true,_,[max_redirect(-1)]),
        domain_error(promise_option,max_redirect(-1)),rpc:promise/4),
    expect_client_error(rpc('http://invalid',true,[request_header(bad)]),
        type_error(http_request_header,bad),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[authorization(digest(user,password))]),
        domain_error(http_authorization,digest(user,password)),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[src_predicates([a/b])]),
        type_error(predicate_indicator,a/b),rpc:rpc/3),
    expect_client_error(rpc('http://invalid',true,[src_uri(42)]),
        type_error(atom,42),rpc:rpc/3),
    writeln('values and every duplicate occurrence are validated: ok').

option_no_resource_side_effects :-
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),Before),
    findall(Q,message_queue_property(Q,size(_)),QueuesBefore),
    expect_client_error(promise('http://invalid',true,Ref,[limit(1),limit(0)]),
        domain_error(positive_integer,0),rpc:promise/4),var(Ref),
    % A denied source URI would fail first if materialization preceded validation.
    expect_client_error(promise('http://invalid',true,Ref2,
        [src_uri('http://invalid/source'),unknown(1)]),
        domain_error(promise_option,unknown(1)),rpc:promise/4),var(Ref2),
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),After),Before==After,
    findall(Q,message_queue_property(Q,size(_)),QueuesAfter),QueuesBefore==QueuesAfter,
    writeln('invalid options do not fetch source or create promise resources: ok').

option_yield_retry :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_)),
    setup_call_cleanup(true,user:check_invalid_yield(Ref),promise_cleanup(Ref)),
    writeln('invalid yield options preserve the reference and answer: ok').
check_invalid_yield(Ref) :-
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    expect_client_error(yield(Ref,_,[timeout(0),timeout(bad)]),type_error(number,bad),rpc:yield/3),
    expect_client_error(yield(Ref,_,[on_timeout(42)]),type_error(callable,42),rpc:yield/3),
    expect_client_error(yield(Ref,_,[timeout(-1)]),domain_error(not_less_than_zero,-1),rpc:yield/3),
    expect_client_error(yield(Ref,_,[unknown(1)]),domain_error(yield_option,unknown(1)),rpc:yield/3),
    yield(Ref,Answer),Answer==success([ok],false).

option_supported_vectors :-
    Options=[limit(2),limit(3),timeout(301),
             request_header('X-Test'=[v,a,l,u,e]),request_header('x-test'=later),request_header('X-Count'='42'),
             authorization(basic(user,password)),request_header('AUTHORIZATION'=later),user_agent('Trealla test'),request_header('User-Agent'=later),
             src_text('p(a).'),src_text([112,46]),src_list([p(X)]),src_predicates([p/1]),src_uri('http://localhost/source')],
    rpc:validate_client_options(rpc,[once(true),once(false)|Options]),var(X),
    rpc:rpc_http_options([once(true)|Options],OnceHTTP),
    rpc:rpc_http_options(Options,OnceHTTP),
    POptions=[template(X-X),offset(0),once(true),once(false)|Options],
    rpc:validate_client_options(promise,POptions),var(X),
    rpc:validate_client_options(yield,[timeout(301),on_timeout(X=waiting)]),var(X),
    option(limit(First),Options,_),First==2,
    rpc:rpc_http_options(POptions,HTTP),
    HTTP==[request_header('x-test'=value),request_header('x-count'='42'),
           request_header(authorization='Basic dXNlcjpwYXNzd29yZA=='),user_agent('Trealla test')],
    writeln('documented subset, precedence, source formats and sharing: ok').

rpc_options_live_test(Port) :-
    format(atom(URI),'http://localhost:~w',[Port]),
    findall(X,rpc(URI,member(X,[a,b,c]),[limit(1),limit(2),timeout(301),
        request_header('X-Test'=value),
        authorization(basic(test,password)),user_agent('Trealla validation')]),Rows),Rows==[a,b,c],
    promise(URI,X=ok,Ref,[template(X-X),offset(0),limit(1),timeout(301)]),
    expect_client_error(yield(Ref,_,[timeout(bad)]),type_error(number,bad),rpc:yield/3),
    yield(Ref,Answer),Answer==success([ok-ok],false),var(X),
    format('Live validated RPC paging and promise collection on ~w: ok~n',[Port]).
