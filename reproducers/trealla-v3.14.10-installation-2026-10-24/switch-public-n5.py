from pathlib import Path
import os,json,signal,time,subprocess,socket,shlex,urllib.request,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];STATE=Path.home()/'.local/share/trinity-local-nodes/n5'
with urllib.request.urlopen('http://127.0.0.1:3062/node_info',timeout=5)as r:info=json.load(r)
old_process=subprocess.check_output(['ps','-p','69596','-o','pid=,command='],text=True)
assert 'trealla-v3.13.10/tpl' in old_process
(OUT/'public-n5-before.json').write_text(json.dumps({'process':old_process,'node_info':info,'auxiliary_new_pid':97669},indent=2)+'\n')
(STATE/'start-auxiliary-3061.sh').write_text((STATE/'start.sh').read_text());(STATE/'start-auxiliary-3061.sh').chmod(0o755)
opts="[bind_address('127.0.0.1'),node_url('http://localhost:3060'),profile(actor),sandbox(blacklist),auth(open),ws_allowed_origins(['http://localhost:3053','http://localhost:3060','http://127.0.0.1:3053','http://127.0.0.1:3060']),tutorial_sections([all]),load_shared_db_file('Deployment/shared_db_common.pl'),load_shared_db_file('Deployment/shared_db_actor_common.pl')]"
goal="use_module(actors),use_module(actor_api),use_module(web_prolog),use_module(distribution),consult('Deployment/shared_db_common.pl'),consult('Deployment/shared_db_actor_common.pl'),web_prolog:web_prolog_node(3062,"+opts+"),thread_get_message(stop)"
script='#!/bin/sh\nset -eu\ncd '+shlex.quote(str(ROOT))+'\nruntime=${TRINITY_TREALLA_RUNTIME:-'+shlex.quote(str(ROOT/'.build/trealla-current'))+'}\nexport TPL_LIBRARY_PATH="$runtime/library"\nexec "$runtime/tpl" -g '+shlex.quote(goal)+'\n'
(STATE/'start.sh').write_text(script);(OUT/'start-n5.sh').write_text(script)
(OUT/'public-n5-goal.txt').write_text(goal+'\n')
os.kill(69596,signal.SIGTERM)
forced=False
for _ in range(50):
 try:os.kill(69596,0)
 except ProcessLookupError:break
 time.sleep(0.1)
else:os.kill(69596,signal.SIGKILL);forced=True;time.sleep(0.2)
with (STATE/'n5.log').open('ab',buffering=0)as log:p=subprocess.Popen([str(STATE/'start.sh')],cwd=ROOT,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
(STATE/'auxiliary-3061.pid').write_text('97669\n');(STATE/'n5.pid').write_text(str(p.pid)+'\n');(OUT/'n5.pid').write_text(str(p.pid)+'\n')
for _ in range(100):
 if p.poll()is not None:raise RuntimeError('public backend exited')
 try:
  with urllib.request.urlopen('http://127.0.0.1:3062/version',timeout=0.5)as r:
   version=json.load(r);assert version['trealla']=='3.14.10';break
 except (OSError,TimeoutError):time.sleep(0.1)
else:raise RuntimeError('public backend not ready')
with urllib.request.urlopen('http://localhost:3060/node_info',timeout=5)as r:after=json.load(r)
assert after==info,(after,info)
(OUT/'public-n5-startup.json').write_text(json.dumps({'pid':p.pid,'node_info':after,'original_public_node_info_preserved':True,'old_backend_forced_stop':forced,'launcher':str(STATE/'start.sh'),'old_runtime':str(ROOT/'.build/trealla-v3.13.10')},indent=2)+'\n')
print('Public n5 backend ready',p.pid,'node info preserved')
