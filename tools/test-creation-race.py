#!/usr/bin/env python3
"""Fixed, fresh-process creation-race diagnostics; does not modify runtimes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = ['actors.pl', 'isolation.pl', 'receiver_lineage.pl', 'rpc.pl',
                 'web_prolog.pl', 'toplevel_actors.pl']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
quote = lambda value: "'" + str(value).replace("'", "''") + "'"
now = lambda: datetime.now(timezone.utc).isoformat()


def capture(command, cwd, env, timeout):
    started = time.monotonic()
    try:
        p = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=timeout)
        return dict(returncode=p.returncode, stdout=p.stdout, stderr=p.stderr,
                    elapsed_seconds=round(time.monotonic()-started, 3))
    except subprocess.TimeoutExpired as error:
        def decode(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else (value or '')
        return dict(returncode=None, timeout=True, stdout=decode(error.stdout),
                    stderr=decode(error.stderr), elapsed_seconds=round(time.monotonic()-started, 3))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', action='append', required=True, help='LABEL=/absolute/path/to/tpl')
    parser.add_argument('--isolated-processes', type=int, default=10)
    parser.add_argument('--isolated-iterations', type=int, default=200)
    parser.add_argument('--prefix-processes', type=int, default=50)
    parser.add_argument('--prefix-iterations', type=int, default=20)
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if min(args.isolated_processes, args.isolated_iterations, args.prefix_processes,
           args.prefix_iterations, args.timeout) <= 0:
        parser.error('batch sizes and timeout must be positive')
    hashes = {name: sha(ROOT/name) for name in RUNTIME_FILES}
    report = dict(started_at=now(), platform=platform.platform(),
                  repository_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  test_sha256=sha(ROOT/'receiver_lineage_tests.pl'), runner_sha256=sha(Path(__file__)),
                  runtime_hashes_before=hashes, configuration=vars(args).copy(), engines={})
    report['configuration']['output'] = str(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        args.output.write_text(json.dumps(report,indent=2)+'\n')
    save()
    failures = 0
    for spec in args.engine:
        label, path = spec.split('=',1)
        if label in report['engines']:
            parser.error('engine labels must be unique')
        exe = Path(path).resolve()
        env = dict(os.environ, TPL_LIBRARY_PATH=str(exe.parent/'library'))
        git = subprocess.run(['git','-C',str(exe.parent),'rev-parse','HEAD'],capture_output=True,text=True)
        engine = dict(executable=str(exe), executable_sha256_before=sha(exe),
                      source_revision=git.stdout.strip() if git.returncode == 0 else None,
                      library_path=env['TPL_LIBRARY_PATH'], trials=[])
        report['engines'][label] = engine
        engine['version'] = capture([str(exe),'-g','current_prolog_flag(version_data,V),writeq(V),nl,halt'],ROOT,env,5)
        for mode, processes, iterations in [('isolated',args.isolated_processes,args.isolated_iterations),
                                            ('after_prefix',args.prefix_processes,args.prefix_iterations)]:
            passed = 0
            for trial in range(1, processes+1):
                goal = (f"consult({quote(ROOT/'receiver_lineage_tests.pl')}),"
                        f"(catch(receiver_lineage_tests:race_batch({mode},{iterations}),E,"
                        "(writeq(E),nl,fail))->halt;halt(1))")
                result = capture([str(exe),'-g',goal],ROOT,env,args.timeout)
                marker = f'creation_race_batch_passed({mode},{iterations})'
                result.update(mode=mode, trial=trial, requested_iterations=iterations,
                              passed=result['returncode']==0 and marker in result['stdout'])
                stage = re.search(r'lineage_creation_race\(([a-z_]+)',result['stdout'])
                iteration = re.search(r'race\((\d+),',result['stdout'])
                if result['passed']:
                    passed += 1
                else:
                    failures += 1
                    result['classification'] = ('external_watchdog' if result.get('timeout') else
                        'stage_failure' if stage else 'incomplete_output' if result['returncode']==0 else 'process_failure')
                    result['stage'] = stage.group(1) if stage else None
                    result['iteration'] = int(iteration.group(1)) if iteration else None
                    print(label,mode,'trial',trial,'FAILED',result['classification'],result['stage'],flush=True)
                engine['trials'].append(result)
                save()
            print(label,mode,f'{passed}/{processes} processes passed; {iterations} iterations requested per process',flush=True)
        engine['executable_sha256_after'] = sha(exe)
        save()
    report['runtime_hashes_after'] = {name: sha(ROOT/name) for name in RUNTIME_FILES}
    report['runtime_files_unchanged'] = report['runtime_hashes_after'] == hashes
    report['finished_at'] = now()
    report['failed_processes'] = failures
    save()
    return 0 if failures == 0 and report['runtime_files_unchanged'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
