:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/distribution.pl').
:- initialization(main,main).
main :-
 web_prolog:web_prolog_node(44301,[bind_address('127.0.0.1'),node_url('http://localhost:44300'),
  profile(actor),sandbox(blacklist),auth(open),tutorial_sections([all]),
  load_uri_allowed_origins(['http://localhost:44300']),load_uri_allowed_ip_ranges(['127.0.0.1/32','::1']),
  load_uri_origin_aliases(['http://localhost:44300'='http://127.0.0.1:44300']),
  load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/shared_db.pl'),
  load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_actor_common.pl'),
  load_shared_db_file('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_n5.pl'),
  ws_allowed_origins(['http://localhost:3053','http://localhost:44300','http://127.0.0.1:3053','http://127.0.0.1:44300'])]).
