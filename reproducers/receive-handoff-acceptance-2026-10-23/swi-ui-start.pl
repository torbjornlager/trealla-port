:- use_module(library(sgml)).
:- use_module(library(option)).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/node.pl').
:- use_module(library(socket)).
:- initialization(main,main).
main :-
 set_setting(http:public_scheme,http),set_setting(http:public_host,localhost),set_setting(http:public_port,44310),
 tcp_socket(S),tcp_bind(S,ip(127,0,0,1):44311),tcp_listen(S,128),
 node:node(44311,[tcp_socket(S),profile(actor),sandbox(blacklist),auth(open),tutorial_sections([all]),
 load_uri_allowed_origins(['http://localhost:44310']),load_uri_allowed_ip_ranges(['127.0.0.1/32','::1']),
 load_uri_origin_aliases(['http://localhost:44310'='http://127.0.0.1:44310']),
 load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/shared_db.pl'),
 load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_actor_common.pl'),
 load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_n3.pl'),
 ws_allowed_origins(['http://localhost:44310','http://127.0.0.1:44310'])]),
 thread_get_message(stop).
