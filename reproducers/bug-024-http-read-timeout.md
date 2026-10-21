# Upstream report: HTTP read timeout is accepted but not enforced

**Status:** Submitted on 2026-10-21 as [Trealla issue #1172](https://github.com/trealla-prolog/trealla-prolog/issues/1172).
Reproduced on v3.13.10 and a
separate unmodified current-upstream v3.13.26 build; duplicate search completed
on 2026-10-21 with no direct match found.

## Summary

`library(http):http_open/3` accepts `timeout(0.2)`, but a loopback peer that
sends nothing for 1.2 seconds still produces a successful response. There is
no Web Prolog code, asynchronous client, source loader or application-level
alarm in this reproducer.

## Environment tested

- Current upstream Trealla v3.13.26, commit
  `7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6`
  ("Strip Windows paths too in make_reload's changed lines"). This was
  upstream `main` both when cloned and when checked again after testing on
  2026-10-21. The source checkout is unmodified.
- Also reproduced on v3.13.10, commit
  `36f512f595e407e330f6e1f6b4eb339da2b0675e`
  ("Drop credentials from http_open/3 on cross-origin redirects #1170").
- Each runtime was paired with its own matching standard library; both builds
  use `NOSSL=1`. The isolated v3.13.26 build used Apple Clang and the installed
  macOS 15.4 SDK, selected only for the build process. No installation or
  runtime replacement was performed.
- macOS 26.6.2, Darwin arm64; plain HTTP over IPv4 loopback.
- Three standalone runs on each version on 2026-10-21.
- HTTPS and other platforms have not been tested here.

## Minimal reproducer

The two accompanying files are independent of the Web Prolog repositories:

- [`bug-024-http-read-timeout.pl`](bug-024-http-read-timeout.pl): the Prolog
  client, using only `library(http)` and ordinary runtime predicates.
- [`bug-024-http-read-timeout.py`](bug-024-http-read-timeout.py): a Python
  standard-library fixture/runner. It binds an ephemeral loopback port, waits
  1.2 seconds before sending any response bytes, runs the client, and stops
  the fixture. The child process has a ten-second watchdog.

Run with an installed Trealla and matching libraries:

```sh
python3 bug-024-http-read-timeout.py /path/to/tpl
```

For an uninstalled source build, explicitly select its matching library:

```sh
TPL_LIBRARY_PATH=/path/to/trealla/library \
  python3 bug-024-http-read-timeout.py /path/to/trealla/tpl
```

The essential client operation is:

```prolog
setup_call_cleanup(
    http_open(URL, Stream, [timeout(0.2)]),
    getline(Stream, Body),
    close(Stream)).
```

## Expected behaviour

The peer is silent for substantially longer than the requested read timeout.
The blocked HTTP read should report a timeout at about 0.2 seconds, subject to
normal scheduling tolerance. The precise exception shape can follow Trealla's
intended stream-timeout contract; the important point is that the request
should not wait for and successfully return the delayed response.

## Actual behaviour

The runner prints the runtime version and the result. Current upstream
v3.13.26 returned `success([o,k])` after **1.205, 1.207 and 1.205 seconds**.
The older v3.13.10 build returned success after 1.209 seconds in all three
runs. Example current-upstream output:

```text
Trealla Prolog (c) Infradig 2020, v3.13.26
success([o,k]) after 1.205 seconds
```

The Prolog result is printed rather than asserted, so the same reproducer can
show the timeout exception after a fix. A successful runner exit by itself is
not evidence that the timeout is enforced.

## Source observations on both tested revisions

`library/http/http_open.pl` applies the option in `connect/3` using
`set_stream(S, timeout(T))`. `src/bif_streams.c` stores that value in
`stream.timeout_ms`; on both revisions, source references to the field consist
of its declaration, initialization and assignments, with no read-side use.
The ordinary socket line-reading path in `src/network.c` waits through
`tpl_wait_fd_readable()`, whose poll budget considers alarms and interruption,
but not the configured stream timeout. These observations suggest that the
missing enforcement belongs in the runtime read machinery rather than in the
application's option extraction.

This reproducer establishes the silent-header case only. A fix should also
consider partial lines, body reads, buffered data, zero timeouts, TLS and
interaction with existing alarms/cancellation; those cases are not claimed
as independently reproduced here.

## Impact and current handling

Applications cannot currently rely on the HTTP library's timeout option to
bound a silent peer. The Web Prolog port documents the limitation; it has not
added a replacement enforcement mechanism. An independent experiment showed
that an enclosing alarm interrupts the plain-HTTP wait, but that would impose
a whole-request deadline rather than transparently repair read-timeout
semantics, so it is not used as the fix.

## Duplicate check

On 2026-10-21, searched the canonical
[`trealla-prolog/trealla-prolog` tracker](https://github.com/trealla-prolog/trealla-prolog/issues)
across open and closed issues/pull requests, using `timeout`, `http_open` and
`set_stream`, and reviewed the relevant older discussions and their comments.
No direct duplicate of the ignored HTTP stream read-timeout setting was found.
Related historical reports are:

- [#1052: Make SIGALRM work with threads](https://github.com/trealla-prolog/trealla-prolog/issues/1052):
  alarm delivery and `call_with_time_limit/2`, rather than the unused
  `set_stream/2` timeout field.
- [#1048: Sockets issues with the new Logtalk HTTP/HTMX/WebSocket/OpenAPI/REST libraries](https://github.com/trealla-prolog/trealla-prolog/issues/1048):
  socket hangs and shutdown handling, without this minimal delayed-response
  timeout case.

The former repository URL (`trealla-prolog/trealla`) redirects to this
canonical repository. The earlier search API error was resolved by using the
canonical name. The submitted issue includes both standalone reproducer files
as inline code blocks.
