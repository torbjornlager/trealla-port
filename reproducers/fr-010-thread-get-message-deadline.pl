% SPDX-License-Identifier: MIT

% Trealla v3.13.2 through v3.13.4 rejected SWI-Prolog's deadline/1 option.
% Fixed in v3.13.10; this file is retained as a regression probe.
%
% Run with:
%
%   tpl -q -f reproducers/fr-010-thread-get-message-deadline.pl \
%       -g "reproducer,halt"
%
% Expected portable behavior: the already-expired deadline makes
% thread_get_message/3 fail immediately, so the program prints `none`.

reproducer :-
    thread_self(Self),
    get_time(Deadline),
    ( catch(thread_get_message(Self, _Message, [deadline(Deadline)]),
            Error, true)
    -> true
    ;  Error = none
    ),
    ( var(Error) -> Error = unexpected_success ; true ),
    writeq(Error),
    nl.
