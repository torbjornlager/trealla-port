from pathlib import Path
import os,subprocess,json,shutil
ROOT=Path('/Users/torbjorn.lager/Documents/GitHub/trealla-port');OUT=Path(__file__).resolve().parent;OLD=Path.home()/'.local/share/trinity-runtime-tests/shared-shadow-probe-2026-10-25';EXE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl';ENV=dict(os.environ,TPL_LIBRARY_PATH=str(EXE.parent/'library'))
# Reverse only this one candidate change for the failing control.
s=(ROOT/'isolation.pl').read_text().replace('retractall(~q:SharedHead)','retractall(SharedHead)').replace("assertz(\\'$actor_source_pi\\'(PI)) ).~n', [Module]),","assertz(\\'$actor_source_pi\\'(PI)) ).~n', []),")
(OLD/'isolation.pl').write_text(s);shutil.copy2(ROOT/'shared_shadow_tests.pl',OLD/'shared_shadow_tests.pl');(OLD/'fixtures/source').mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/'fixtures/source/shared-shadow.pl',OLD/'fixtures/source/shared-shadow.pl')
rows=[]
for label,cwd,module in [('before',OLD,'shared_shadow_tests'),('after',ROOT,'shared_shadow_tests'),('declarations',ROOT,'source_declaration_tests'),('source-capture',ROOT,'source_capture_tests'),('synchronous-toplevel',ROOT,'synchronous_toplevel_tests')]:
 cmd=[str(EXE),'-g',f"consult('{module}.pl'),(catch({module}:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
 with (OUT/(label+'.log')).open('w') as log:
  try:code=subprocess.run(cmd,cwd=cwd,env=ENV,stdout=log,stderr=log,timeout=25).returncode
  except subprocess.TimeoutExpired:code=124
 rows.append(dict(label=label,exit_code=code,command=cmd));print(label,code,flush=True)
(OUT/'checks.json').write_text(json.dumps(rows,indent=2)+'\n')
assert rows[0]['exit_code']==1 and all(r['exit_code']==0 for r in rows[1:])
