:- use_module(actors).

bm_ping(0, Pong_Pid) :-
    Pong_Pid ! finished.
bm_ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong -> true
    }),
    N1 is N - 1,
    bm_ping(N1, Pong_Pid).
    
bm_pong :-
    receive({
        finished -> true;
        ping(Ping_Pid) ->
            Ping_Pid ! pong,
            bm_pong
    }).
    
bm_ping_pong(N) :-
    spawn(bm_pong, Pong_Pid),
    spawn(bm_ping(N, Pong_Pid), Ping_Pid, [
        monitor(true)
    ]),
    receive({
       down(Ping_Pid, _, true) ->
          true
    }).