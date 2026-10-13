% Trealla v3.13.3 and v3.13.4: concurrent sleep/1 calls lengthen one another.

reproducer :-
    get_time(Start),
    thread_create(sleep(1), One, []),
    thread_create(sleep(3), Three, []),
    thread_create(sleep(2), Two, []),
    thread_join(One, _),
    thread_join(Three, _),
    thread_join(Two, _),
    get_time(Finish),
    Elapsed is Finish-Start,
    format('elapsed(~3f).~n', [Elapsed]).

:- initialization(reproducer).
