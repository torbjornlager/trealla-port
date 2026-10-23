:- use_module('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/actors.pl',[]).
run(Mode) :-
 findall(Id,(between(1,32,_),thread_create(wait(Mode),Id,[])),Ids),
 sleep(2),get_time(Start),maplist(release,Ids),maplist(join,Ids),get_time(End),
 Delta is End-Start,format('release_seconds(~6f).~n',[Delta]).
wait(adapter) :- actors:receive({done -> true}).
wait(native) :- thread_get_message(done).
release(Id) :- thread_send_message(Id,done).
join(Id) :- thread_join(Id,true).
