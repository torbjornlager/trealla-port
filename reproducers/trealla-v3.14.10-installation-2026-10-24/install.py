"""Controlled side-by-side local runtime installation and backend-only restart."""
from pathlib import Path
import os,subprocess,json,hashlib,shutil,signal,time,socket,shlex
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
SOURCE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
DEST=ROOT/'.build/trealla-v3.14.10';OLD=ROOT/'.build/trealla-v3.13.10';CURRENT=ROOT/'.build/trealla-current'
STATE=Path.home()/'.local/share/trinity-local-nodes/n5';STATE.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(p):return {str(f.relative_to(p)):sha(f)for f in p.rglob('*')if f.is_file()}
def ps(ids):return subprocess.check_output(['ps','-p',ids,'-o','pid=,command='],text=True)
swi=[Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]
before={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'old_runtime':str(OLD),'old_binary_sha256':sha(OLD/'tpl'),'old_library_sha256':tree(OLD/'library'),'protected_processes':ps('55051,42134'),'n5_process':ps('30612'),'swi_sha256':{str(p):sha(p)for p in swi}}
(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n')
expected=json.loads((ROOT/'reproducers/upstream-3.14.10-acceptance-2026-10-24/unit-final-before.json').read_text())['engine_sha256'][str(SOURCE/'tpl')]
assert sha(SOURCE/'tpl')==expected
assert subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip()=='4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294'
assert not subprocess.check_output(['git','-C',str(SOURCE),'status','--short','--untracked-files=no'],text=True).strip()
assert not DEST.exists() and not CURRENT.exists()
DEST.mkdir();shutil.copy2(SOURCE/'tpl',DEST/'tpl');shutil.copytree(SOURCE/'library',DEST/'library',symlinks=True)
assert sha(DEST/'tpl')==expected and tree(DEST/'library')==tree(SOURCE/'library')
CURRENT.symlink_to(DEST.name,target_is_directory=True)
metadata={'version':'v3.14.10','source':str(SOURCE),'installed':str(DEST),'active_pointer':str(CURRENT),'binary_sha256':expected,'library_sha256':tree(DEST/'library'),'upstream_commit':'4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294','build_flags':'NOSSL=1 NOFFI=1','rollback_runtime':str(OLD)}
(DEST/'INSTALLATION.json').write_text(json.dumps(metadata,indent=2)+'\n');(OUT/'installation.json').write_text(json.dumps(metadata,indent=2)+'\n')
goal="use_module(web_prolog),use_module(distribution),web_prolog:web_prolog_node(3061,[bind_address('127.0.0.1'),node_url('http://localhost:3061'),profile(actor),sandbox(blacklist),auth(open),ws_allowed_origins(['http://localhost:3053','http://localhost:3061'])]),thread_get_message(stop)"
script='#!/bin/sh\nset -eu\ncd '+shlex.quote(str(ROOT))+'\nruntime=${TRINITY_TREALLA_RUNTIME:-'+shlex.quote(str(CURRENT))+'}\nexport TPL_LIBRARY_PATH="$runtime/library"\nexec "$runtime/tpl" -g '+shlex.quote(goal)+'\n'
(STATE/'start.sh').write_text(script);(STATE/'start.sh').chmod(0o755);(OUT/'start-n5.sh').write_text(script)
(STATE/'rollback.json').write_text(json.dumps(before,indent=2)+'\n')
# Exercise the installed copy before stopping the existing backend.
with (OUT/'installed-receive-smoke.log').open('w')as log:
 subprocess.run([str(DEST/'tpl'),'-g',"(catch((consult(receive_atomic_tests),receive_atomic_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"],cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(DEST/'library')),stdout=log,stderr=log,check=True,timeout=30)
assert 'trealla-v3.13.10/tpl' in ps('30612')
os.kill(30612,signal.SIGTERM)
for _ in range(50):
 try:os.kill(30612,0)
 except ProcessLookupError:break
 time.sleep(0.1)
else:os.kill(30612,signal.SIGKILL);time.sleep(0.2)
with (STATE/'n5.log').open('ab',buffering=0)as log:
 p=subprocess.Popen([str(STATE/'start.sh')],cwd=ROOT,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
(STATE/'n5.pid').write_text(str(p.pid)+'\n');(OUT/'n5.pid').write_text(str(p.pid)+'\n')
for _ in range(100):
 if p.poll()is not None:raise RuntimeError('new n5 exited; inspect log, old runtime is retained')
 try:
  with socket.create_connection(('127.0.0.1',3061),timeout=0.2):break
 except OSError:time.sleep(0.1)
else:raise RuntimeError('new n5 did not listen')
(OUT/'startup.json').write_text(json.dumps({'pid':p.pid,'launcher':str(STATE/'start.sh'),'log':str(STATE/'n5.log'),'goal':goal,'protected_processes_unchanged':ps('55051,42134')==before['protected_processes'],'n5_process':ps(str(p.pid))},indent=2)+'\n')
print(json.dumps({'new_n5_pid':p.pid,'installed':str(DEST),'old_runtime_retained':str(OLD),'launcher':str(STATE/'start.sh')},indent=2))
