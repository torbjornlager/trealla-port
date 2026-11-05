#!/usr/bin/env python3
"""Required library and callback boundaries on disposable Trealla listeners."""
import argparse,json,os,socket,subprocess,tempfile,time,urllib.request,urllib.parse
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--tpl',required=True);a=p.parse_args()
pack=json.loads((ROOT/'standard_library_cases.json').read_text());count=0
for mode in ['blacklist','whitelist']:
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 env=dict(os.environ,TPL_LIBRARY_PATH=str(Path(a.tpl).parent/'library'))
 with tempfile.TemporaryFile(mode='w+') as log:
  node=subprocess.Popen([a.tpl,'-g',f'use_module(distribution),web_prolog:web_prolog_node({port},[sandbox({mode}),max_call_requests_per_window(1000)])'],cwd=ROOT,env=env,stdout=log,stderr=log)
  try:
   for _ in range(150):
    if node.poll() is not None:log.seek(0);raise AssertionError(log.read())
    try:
     with socket.create_connection(('127.0.0.1',port),timeout=.1):break
    except OSError:time.sleep(.03)
   else:raise TimeoutError('fixture readiness')
   def query(goal,source=''):
    params=dict(goal='('+goal+'),LibraryCheck=passed',template='LibraryCheck',format='prolog',limit=1,src_text=source)
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/call?'+urllib.parse.urlencode(params),timeout=6) as response:return ''.join(response.read().decode().split())
   cases=pack['cases'] if mode=='blacklist' else [c for c in pack['cases'] if c['id'] in ['STDLIB-032','STDLIB-034','STDLIB-040','STDLIB-048','STDLIB-054']]
   for case in cases:
    body=query(case['goal'],pack['source']);assert body=='success([passed],false).',(mode,case['id'],body);count+=1
   for goal in ['maplist(current_prolog_flag,[bounded],[_])',
                'G=current_prolog_flag,maplist(G,[bounded],[_])',
                'G=current_prolog_flag(bounded,_),countall(G,_)',
                'G=current_prolog_flag(bounded,_),call_nth(G,1)',
                'foldl(open,[no_such_file],read,_)']:
    body=query(goal);assert body.startswith('error(') and ('permission_error' in body or 'instantiation_error' in body),(mode,goal,body);count+=1
  finally:
   node.terminate()
   try:node.wait(timeout=5)
   except subprocess.TimeoutExpired:node.kill();node.wait()
print('PASS',count,'standard-library and callback controls across blacklist/whitelist')
