% SPDX-License-Identifier: MIT

% Trealla v3.13.2 rejects SWI-Prolog's absolute deadline/1 option.
%
% Run with:
%
%   tpl -q -f reproducers/fr-010-thread-get-message-deadline.pl \
%       -g "reproducer,halt"
%
% Expected portable behavior: the already-expired deadline makes
% thread_get_message/3 fail immediately.  Current Trealla behavior:
%
%   error(domain_error(read_option,deadline(...)),thread_get_message/3)

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
