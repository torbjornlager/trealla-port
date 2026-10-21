#!/usr/bin/env python3
"""Fresh-process HTTP client context regressions; stdlib only, disposable nodes."""
import argparse
import re
import socket
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]


def request(url, goal, template='ok', source=''):
    params = dict(goal='('+goal+')', template='('+template+')',
                  format='prolog', src_text=source, limit=20)
    try:
        with urlopen(url+'/call?'+urlencode(params), timeout=5) as response:
            return response.read().decode().strip()
    except HTTPError as error:
        return error.read().decode().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tpl', required=True)
    args = parser.parse_args()
    executable = shutil.which(args.tpl) or str(Path(args.tpl).resolve())
    count = 0
    # Neither entry point may preload rpc from the test fixture.
    for entry in ['node', 'distribution']:
        for mode in ['blacklist', 'whitelist']:
            with tempfile.TemporaryDirectory(prefix='trealla-http-client-') as temp:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                url = f'http://127.0.0.1:{port}'
                options = f"[bind_address('127.0.0.1'),node_url('{url}'),profile(actor),sandbox({mode}),auth(open),time_limit(3)]"
                start = (f'use_module(node),node:node({port},none,{options})'
                         if entry == 'node' else
                         f"consult('distribution.pl'),web_prolog:web_prolog_node({port},{options})")
                goal = start+',thread_get_message(stop)'
                before = count
                with open(Path(temp)/'node.log', 'w') as log:
                    proc = subprocess.Popen([executable, '-g', goal], cwd=ROOT,
                                            stdout=log, stderr=log)
                    try:
                        for attempt in range(150):
                            if proc.poll() is not None:
                                raise AssertionError('node exited during startup')
                            try:
                                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                    break
                            except OSError:
                                time.sleep(.02)
                        else:
                            raise AssertionError('node startup timed out')
                        peer = "'"+url+"'"

                        def check(label, query, template='ok', expected='success([ok],false).', source=''):
                            nonlocal count
                            actual = request(url, query, template, source)
                            assert actual == expected, (entry, mode, label, actual)
                            count += 1

                        check('rpc/3', f'rpc({peer},member(X,[a,b,c]),[limit(2)])', 'X',
                              'success([a,b,c],false).')
                        check('rpc/2 under findall',
                              f'findall(X,rpc({peer},member(X,[a,b])),Xs),Xs==[a,b]')
                        check('rpc/3 under findall',
                              f'findall(X,rpc({peer},member(X,[a,b,c]),[limit(2)]),Xs),Xs==[a,b,c]')
                        check('native control scope',
                              f'(once(rpc({peer},member(X,[a,b]),[]))->X==a;fail)')
                        check('promise/4 sharing',
                              f'promise({peer},X=ok,R,[template(pair(X,X))]),var(X),'
                              'yield(R,A),A=success([pair(ok,ok)],false),var(X)')
                        check('promise/3 default template',
                              f'promise({peer},X=ok,R),yield(R,success([G],false)),G=(ok=ok),var(X)')
                        check('timeout answer and retry',
                              f'promise({peer},(sleep(0.15),X=ok),R,[template(X)]),'
                              'yield(R,Early,[timeout(0)]),Early==timeout,'
                              'yield(R,success([ok],false))')
                        check('timeout callback and retry',
                              f'promise({peer},(sleep(0.15),X=ok),R,[template(X)]),'
                              'yield(R,Early,[timeout(0),on_timeout(Early=waiting)]),Early==waiting,'
                              'yield(R,success([ok],false))')
                        check('remote error answer',
                              f'promise({peer},throw(client_probe),R),yield(R,error(client_probe))')
                        check('invalid and collected references',
                              f'catch(yield(42,_),E,true),E=error(existence_error(promise,42),_),'
                              f'promise({peer},true,R),yield(R,_),catch(yield(R,_),F,true),'
                              'F=error(existence_error(promise,R),_)')
                        # Exercise completed-result disposal here; the existing
                        # lifecycle suite covers cancellation of pending workers.
                        check('explicit promise disposal',
                              f'promise({peer},true,R),sleep(0.1),promise_cleanup(R),catch(yield(R,_),E,true),'
                              'E=error(existence_error(promise,R),_)')
                        check('source-backed RPC call', f'client(X),X==ok',
                              source=f'client(X) :- rpc({peer},X=ok,[]).')
                        check('source-backed promise/callback', 'client(ok)',
                              source=f'client(Answer) :- promise({peer},(sleep(0.15),X=ok),R,[template(X)]), '
                                     'yield(R,Early,[timeout(0),on_timeout(Early=waiting)]), Early==waiting, '
                                     'yield(R,success([Answer],false)).')
                        guard_goal = 'G=open(should_not_exist,write,_),catch(call(G),E,true),nonvar(E)'
                        if mode == 'blacklist':
                            check('runtime sandbox guard', guard_goal)
                        else:
                            # Whitelist rejects opaque calls at admission.
                            rejected = request(url, guard_goal)
                            assert 'opaque_meta_call' in rejected, rejected
                            count += 1
                        rejected = request(url, 'open(should_not_exist,write,_)')
                        assert 'permission_error' in rejected and 'sandboxed' in rejected, rejected
                        count += 1
                        rejected = request(url, 'node:stop_node(1)')
                        assert 'module_qualification' in rejected, rejected
                        count += 1
                        # Database guards must retain user scope, never node state.
                        check('node clauses stay private',
                              'catch((clause(handle_call(_,_,_,_,_,_),_)->fail;true),_,true)')
                        # Stateless ISOBASE admission rejects mutations even on
                        # an ACTOR node; the new resolution context must not widen it.
                        for mutation in ['retract(http_promise_namespace(_,_))',
                                         'abolish(http_promise_namespace/2)']:
                            rejected = request(url, mutation)
                            assert 'profile_violation(isobase' in rejected, rejected
                            count += 1
                        # HTTP producers retain distinct promise ownership contexts.
                        body = request(url, f'promise({peer},true,R)', 'R')
                        match = re.fullmatch(r'success\(\[(\d+)\],false\)\.', body)
                        assert match, body
                        reference = match.group(1)
                        check('cross-request reference denied',
                              f'catch(yield({reference},_),E,true),E=error(existence_error(promise,{reference}),_)')
                        print(f'{entry}/{mode}: {count-before} HTTP client-context checks passed', flush=True)
                    finally:
                        proc.terminate()
                        try:
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait()
    print(f'HTTP client context: all {count} checks passed')


if __name__ == '__main__':
    main()
