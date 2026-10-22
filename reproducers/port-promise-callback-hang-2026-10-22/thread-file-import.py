#!/usr/bin/env python3
"""Separate diagnostic: create an importer module inside a native thread."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--tpl', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
engine = a.tpl.resolve()
rows = []
with tempfile.TemporaryDirectory(prefix='trealla-thread-import-') as directory:
    directory = Path(directory)
    (directory/'library.pl').write_text(':- module(thread_import_library,[value/1]).\nvalue(ok).\n')
    (directory/'driver.pl').write_text('''
:- use_module('library.pl').
load_importer(Path) :-
    format(atom(Text),':- use_module(~q).',[Path]),
    load_text(Text,[module(thread_import_destination)]).
main :-
    absolute_file_name('library.pl',Path,[]),
    thread_create(load_importer(Path),T,[]),
    thread_join(T,Status),writeq(status(Status)),nl,halt.
''')
    for trial in range(1,4):
        result = subprocess.run([str(engine), '-q', 'driver.pl', '-g', 'main'],
                                cwd=directory, env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library')),
                                capture_output=True, text=True, timeout=5)
        rows.append(dict(trial=trial, exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))
report = dict(engine=str(engine), scope='Separate diagnostic; no Web Prolog', results=rows)
a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
