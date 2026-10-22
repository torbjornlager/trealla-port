#!/usr/bin/env python3
"""Fresh-process comparison; explicitly selected engines, no runtime changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pinned', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--trials', type=int, default=5)
    args = parser.parse_args()
    rows = []
    engines = []
    for name, executable in [('pinned', args.pinned), ('upstream', args.upstream)]:
        executable = executable.resolve()
        env = dict(os.environ, TPL_LIBRARY_PATH=str(executable.parent/'library'))
        engines.append(dict(name=name, executable=str(executable),
                            sha256=hashlib.sha256(executable.read_bytes()).hexdigest()))
        for case, body, marker in [
            ('original', "consult('rpc_promise_tests.pl'),promise_actor_callback_test", 'case_passed'),
            ('file_import', f"consult({quoted(HERE/'import-state.pl')}),run({quoted(HERE/'state-library.pl')})", 'state_preserved'),
            ('module_import_control', f"consult({quoted(HERE/'import-state.pl')}),run(callback_probe_state)", 'state_preserved')]:
            for trial in range(1, args.trials+1):
                goal = f"(catch(({body},writeln(case_passed),flush_output),E,(writeq(E),nl,flush_output,halt(1)))->halt;halt(1))"
                row = dict(engine=name, case=case, trial=trial)
                try:
                    result = subprocess.run([str(executable), '-g', goal], cwd=ROOT,
                                            env=env, capture_output=True, text=True, timeout=3)
                    row.update(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr,
                               passed=result.returncode == 0 and marker in result.stdout)
                except subprocess.TimeoutExpired as error:
                    def decoded(value):
                        return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
                    row.update(timeout=True, stdout=decoded(error.stdout), stderr=decoded(error.stderr), passed=False)
                rows.append(row)
                print(json.dumps(row), flush=True)
    report = dict(engines=engines, trials=args.trials, results=rows,
                  scope='Investigation only; failures retained, no engine or runtime repair')
    args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
