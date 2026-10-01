# Notices and attribution

## This project

`trealla-port` is copyright (c) 2026 Torbjörn Lager and is distributed under
the MIT License in [`LICENSE`](LICENSE).

The actor, toplevel, HTTP, Web Prolog protocol, and distribution layers are a
native Trealla Prolog port and continuing adaptation of code and protocol work
from Torbjörn Lager's
[`trinity-demonstrator`](https://github.com/torbjornlager/trinity-demonstrator),
which is also distributed under the MIT License. The implementation has been
substantially changed to accommodate Trealla's runtime, module, thread,
socket, HTTP, and WebSocket facilities.

Files in this repository use the SPDX identifier `MIT` to refer to the project
license. Git history remains the authoritative record of individual changes.

## External systems

The source repository does not vendor Trealla Prolog or SWI-Prolog. They are
used as runtimes, test dependencies, interoperability peers, and reference
implementations:

- [Trealla Prolog](https://github.com/trealla-prolog/trealla) is
  copyright (c) 2020 Andrew George Davison and is distributed under the MIT
  License. See Trealla's
  [license](https://github.com/trealla-prolog/trealla/blob/main/LICENSE).
- [SWI-Prolog](https://www.swi-prolog.org/) is distributed under the Simplified
  BSD License. See SWI-Prolog's
  [license](https://github.com/SWI-Prolog/swipl/blob/master/LICENSE).
- [Caddy](https://caddyserver.com/) v2.8.4 is used as the deployment reverse
  proxy and is distributed under the Apache License 2.0. The derived proxy
  image includes its license at `/usr/share/licenses/caddy/LICENSE`.

[Logtalk](https://logtalk.org/) was evaluated during the feasibility work but
is not used by the current native Trealla implementation: this repository
contains no Logtalk source files and has no Logtalk runtime dependency. Logtalk
is copyright (c) 1998-2026 Paulo Moura and is distributed under the Apache
License 2.0; see its
[license](https://github.com/LogtalkDotOrg/logtalk3/blob/master/LICENSE.txt)
and [notice](https://github.com/LogtalkDotOrg/logtalk3/blob/master/NOTICE.txt).
The Apache License does not apply to this repository merely because Logtalk
was evaluated. If Logtalk source is incorporated or bundled in the future,
its license and notice requirements must be followed.

The Trealla deployment image builds and bundles the pinned runtime. Trealla's
`LICENSE` and `ATTRIBUTION` files are copied into
`/usr/share/doc/trealla/` in that image. If SWI-Prolog, Logtalk, or other
third-party code is bundled in a future distribution, its applicable license
text and notices must likewise be included.

## Development assistance

Development and porting work has used AI assistance from Claude (Anthropic)
and ChatGPT/Codex (OpenAI). The project maintainer reviewed and accepted the
resulting changes. These tools are acknowledged as development aids, not
copyright holders or licensors.
