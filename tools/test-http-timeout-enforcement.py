#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Focused plain-HTTP client checks against an explicitly selected Trealla build.

The full group requires stream read-timeout enforcement. The parse_error case
also runs on pinned v3.13.10 and checks cleanup without a timeout dependency.
Uses a disposable Python loopback peer, never an existing Web Prolog node.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        mode = parsed.path.split('/')[1]
        template = parse_qs(parsed.query).get('template', [''])[0]
        row = 'v(ok)' if 'v(' in template else 'ok-ok' if '-' in template else 'ok'
        body = f'success([{row}],false).\n'.encode()
        if mode == 'invalid':
            body = b'success([).\n'
        try:
            if mode == 'headers':
                time.sleep(1.2)
            elif mode == 'brief':
                time.sleep(0.35)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=UTF-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.flush()
            if mode == 'body':
                time.sleep(1.2)
            if mode == 'partial':
                self.wfile.write(body[:8])
                self.wfile.flush()
                time.sleep(1.2)
                self.wfile.write(body[8:])
            else:
                self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # expected when the tested client times out and closes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tpl', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--case', default='all',
                        choices=['all', 'promise_headers', 'promise_body', 'promise_partial', 'retry_success', 'parse_error'])
    args = parser.parse_args()
    executable = args.tpl.resolve()
    env = dict(os.environ, TPL_LIBRARY_PATH=str(executable.parent/'library'))
    started = time.monotonic()
    with ThreadingHTTPServer(('127.0.0.1', 0), Peer) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = f'http://127.0.0.1:{server.server_port}'
        source = str(ROOT/'rpc_http_timeout_enforcement_tests.pl').replace("'", "''")
        target = (f"rpc_http_timeout_enforcement_tests('{url}')" if args.case == 'all'
                  else f"rpc_http_timeout_enforcement_case({args.case},'{url}')")
        goal = (f"consult('{source}'),"
                f"(catch({target},"
                "E,(writeq(E),nl,fail))->halt;halt(1))")
        try:
            result = subprocess.run([str(executable), '-g', goal], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=30)
            report = dict(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
        except subprocess.TimeoutExpired as error:
            def decode(value):
                return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
            report = dict(exit_code=None, timeout=True,
                          stdout=decode(error.stdout), stderr=decode(error.stderr))
        finally:
            server.shutdown()
            worker.join()
    report.update(executable=str(executable), library=env['TPL_LIBRARY_PATH'], case=args.case,
                  elapsed_seconds=round(time.monotonic()-started, 3),
                  scope='Plain HTTP; delayed headers, body and partial line; no TLS')
    marker = ('HTTP read-timeout enforcement, retry/callbacks and resource cleanup: passed'
              if args.case == 'all' else f'HTTP timeout case {args.case}: passed')
    report['passed'] = report['exit_code'] == 0 and marker in report['stdout']
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
