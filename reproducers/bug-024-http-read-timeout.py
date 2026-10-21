#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run the standalone Trealla reproducer against a delayed loopback response.

Usage: TPL_LIBRARY_PATH=/path/to/trealla/library python3 THIS_FILE /path/to/tpl
No Web Prolog modules or third-party Python packages are used.
"""
import pathlib
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DelayedReply(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(1.2)  # no response headers or body before this point
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"ok\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # expected if a working client timeout closes the connection

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    executable = sys.argv[1] if len(sys.argv) > 1 else "tpl"
    source = pathlib.Path(__file__).with_suffix(".pl").resolve()
    with ThreadingHTTPServer(("127.0.0.1", 0), DelayedReply) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            subprocess.run([executable, "--version"], check=True)
            url = f"http://127.0.0.1:{server.server_port}/"
            goal = f"bug_024_http_read_timeout:reproducer('{url}'),halt"
            subprocess.run([executable, "-f", str(source), "-g", goal],
                           check=True, timeout=10)
        finally:
            server.shutdown()
            worker.join()
