#!/usr/bin/env python3
"""Isolated N5/native regressions using supplied immutable Docker image IDs.

No live service is contacted. Requires a conformance runner's WebSocket client.
The topology uses the existing header-stripping public /ws boundary and a
separate owner-configured private dial path, retaining logical public node URLs.
"""
import argparse
from contextlib import ExitStack
import html
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.parse import urlencode
import uuid


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--trealla-image',required=True)
    p.add_argument('--native-image',required=True)
    p.add_argument('--native-bootstrap',default='/app/load.pl')
    p.add_argument('--caddy-image',required=True)
    p.add_argument('--runner',required=True,type=Path)
    p.add_argument('--tutorial',required=True,type=Path)
    p.add_argument('--report',required=True,type=Path)
    p.add_argument('--without-private-route',action='store_true')
    a=p.parse_args();a.report.parent.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('interop_wire',a.runner)
    wire=importlib.util.module_from_spec(spec);sys.modules[spec.name]=wire;spec.loader.exec_module(wire)
    rows=[]
    def save(name,result,**kw):
        rows.append(dict(check=name,result=result,**kw));a.report.write_text(json.dumps(dict(checks=rows),indent=2)+'\n');print(name,result,flush=True)
    def docker(*args):return subprocess.check_output(['docker',*map(str,args)],stderr=subprocess.STDOUT,text=True)
    prefix='n5-fix-'+uuid.uuid4().hex[:10];net=prefix+'-net';n3=prefix+'-n3';n5=prefix+'-n5';edge=prefix+'-edge'
    logical='http://n5.test:8080';peer='http://n3.test:8080'
    with ExitStack() as stack:
        directory=Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='n5-interop-')))
        directory.chmod(0o755) # synthetic fixtures must be readable by the image's unprivileged user
        docker('network','create',net);stack.callback(docker,'network','rm',net)
        native=directory/'native.pl'
        native.write_text(":- multifile distribution:hook_ws_endpoint_override/2.\ndistribution:hook_ws_endpoint_override('http://n5.test:8080','ws://n5:3060/ws').\n")
        topology=directory/'peers.pl';topology.write_text("['http://n3.test:8080'-'ws://n3:3053/ws'].\n")
        goal3="use_module(library(settings)),set_setting(http:public_host,'n3.test'),set_setting(http:public_port,8080),set_setting(http:public_scheme,http),node(3053,[profile(actor),auth(open),sandbox(blacklist),max_ws_commands_per_window(100000)]),thread_get_message(stop)"
        goal5="use_module(web_prolog),use_module(peer_topology),"+('' if a.without_private_route else "peer_topology:configure('/fixture/peers.pl'),")+"web_prolog_node(3060,[bind_address('0.0.0.0'),node_url('http://n5.test:8080'),profile(actor),auth(open),sandbox(blacklist),trusted_proxy_ranges(['172.16.0.0/12']),max_ws_commands_per_window(100000),load_uri_allowed_origins(['http://n3.test:8080','http://n2.test:8080']),load_uri_allowed_ip_ranges(['172.16.0.0/12'])]),thread_get_message(stop)"
        docker('create','--name',n3,'--network',net,'--network-alias','n3','--memory','768m','--cpus','1','--entrypoint','swipl',a.native_image,'-q','-s',a.native_bootstrap,'-s','/fixture/native.pl','-g',goal3);stack.callback(docker,'rm','-f',n3)
        docker('cp',directory,n3+':/fixture');docker('start',n3)
        docker('create','--name',n5,'--network',net,'--network-alias','n5','--memory','768m','--cpus','1','--entrypoint','/opt/trealla/tpl',a.trealla_image,'-g',goal5);stack.callback(docker,'rm','-f',n5)
        docker('cp',directory,n5+':/fixture');docker('start',n5)
        strip='\n'.join('header_up -'+h for h in ['X-Web-Prolog-User','X-Web-Prolog-Principal','X-Web-Prolog-Capabilities','X-Web-Prolog-Caps','X-Web-Prolog-Internal-Proxy','X-Authenticated-User'])
        config=directory/'Caddyfile';config.write_text('''http://:8080 {
 @source host n2.test
 handle @source {
  respond "ancestor_descendant(mike,john). ancestor_descendant(mike,jane)."
 }
 @native host n3.test
 handle @native {
  reverse_proxy n3:3053 {
'''+strip+'''
  }
 }
 handle {
  reverse_proxy n5:3060 {
'''+strip+'''
  }
 }
}
''')
        docker('create','--name',edge,'--network',net,'--network-alias','n3.test','--network-alias','n5.test','--network-alias','n2.test','--memory','256m','-p','127.0.0.1::8080',a.caddy_image,'caddy','run','--config','/fixture/Caddyfile','--adapter','caddyfile');stack.callback(docker,'rm','-f',edge)
        docker('cp',directory,edge+':/fixture');docker('start',edge)
        for name in [n3,n5,edge]:
            stack.callback(lambda name=name: a.report.with_name(name+'.log').write_text(docker('logs',name)))
        port=int(docker('port',edge,'8080/tcp').strip().rsplit(':',1)[1]);base='http://127.0.0.1:'+str(port)
        ready=False
        for _ in range(100):
            try:
                with urlopen(Request(base+'/node_info',headers={'Host':'n5.test:8080'}),timeout=1) as r:
                    if json.load(r)['profile']=='actor':ready=True;break
            except Exception:time.sleep(.1)
        if not ready:
            for name in [n3,n5,edge]:a.report.with_name(name+'.log').write_text(docker('logs',name))
            raise RuntimeError('Isolated fixture did not start')
        save('exact isolated engines started','pass',trealla_image=a.trealla_image,native_image=a.native_image,public_headers_stripped=True)
        query=urlencode(dict(goal='findall(X,rpc(localhost,member(X,[a,b,c]),[limit(1)]),Rows),Rows==[a,b,c]',format='json',limit=1))
        with urlopen(Request(base+'/call?'+query,headers={'Host':'n5.test:8080'}),timeout=10) as response:
            event=json.load(response)
        save('same-node RPC over stateless HTTP','pass' if event['type']=='success' else 'fail',event=event)
        original=socket.create_connection
        def route(address,*args,**kw):return original(('127.0.0.1',port) if address[0] in ['n5.test','n3.test'] else address,*args,**kw)
        def connect(node='n5.test',headers=()):
            with patch.object(socket,'create_connection',route):return wire.WebSocket('ws://'+node+':8080/ws',12,None,'http://'+node+':8080',False,headers)
        # Public callers must not gain internal authority by forging headers.
        ws=connect('n3.test',('X-Web-Prolog-User: node:forged','X-Web-Prolog-Capabilities: execute,internal_transport'))
        try:
            ws.send_json(dict(command='spawn',goal='true',io_target="'$io_endpoint'(forged)@'http://n5.test:8080'"));e=ws.recv_json();save('forged public transport identity denied','pass' if e['type']=='error' else 'fail',event=e)
        finally:ws.close()
        text=html.unescape(re.search(r'<pre id="cpw-remote-pingpong-source">(.*?)</pre>',a.tutorial.read_text(),re.S)[1]).replace('{{actor_peer_host}}',peer).replace('{{ping_pong_peer_host}}',peer)
        text += '\ncopied_io :- write(a), writeln(b), nl.\n'
        ws=connect();pid=None
        try:
            ws.send_json(dict(command='transport_hello',version=1,browser_pids=True,io_ack=True));assert ws.recv_json()['type']=='transport_welcome'
            ws.send_json(dict(command='toplevel_spawn',options='[session(true),src_text('+json.dumps(text)+')]'));e=ws.recv_json();assert e['type']=='spawned',e;pid=e['pid']
            cases=[
                ('same-node RPC paging',"findall(X,rpc(localhost,member(X,[a,b,c]),[limit(1)]),Rows),Rows==[a,b,c]"),
                ('same-node source URI',"findall(X-Y,rpc(localhost,ancestor_descendant(X,Y),[src_uri('http://n2.test:8080')]),Rows),Rows==[mike-john,mike-jane]"),
                ('same-node promise',"promise(localhost,member(X,[a,b,c]),R,[template(X)]),yield(R,A),A==success([a,b,c],false)"),
                ('remote monitored completion',"spawn(true,P,[node('http://n3.test:8080'),monitor(true)]),receive({down(P,P,true)->true},[timeout(3),on_timeout(throw(no_remote_completion))])"),
                ('remote exact output',"spawn((write(a),sleep(0.05),write(b),nl,writeln(done)),P,[node('http://n3.test:8080'),monitor(true)]),receive({down(P,P,true)->true},[timeout(3),on_timeout(throw(no_remote_output_completion))])"),
                ('remote Unicode and term output',"spawn((write([a,b]),nl,writeln('å é'),format('~w',[pair(1,2)])),P,[node('http://n3.test:8080'),monitor(true)]),receive({down(P,P,true)->true},[timeout(3),on_timeout(throw(no_unicode_completion))])"),
                ('copied source output',"spawn(copied_io,P,[node('http://n3.test:8080'),src_predicates([copied_io/0]),monitor(true)]),receive({down(P,P,true)->true},[timeout(3),on_timeout(throw(no_copied_completion))])"),
                ('served remote ping-pong tutorial','ping_pong_remote'),
                ('remote source sandbox denial',"catch(spawn(system:halt,_,[node('http://n3.test:8080')]),E,true),nonvar(E),E=error(permission_error(_,_,_),_)"),
                ('local prompt after remote traffic',"input('Input',X),X==hello"),
            ]
            for name,goal in cases:
                ws.send_json(dict(command='toplevel_call',pid=pid,goal=goal,options='[limit(1),once(true)]'));output=[];prompts=[]
                for _ in range(1000):
                    e=ws.recv_json();kind=e['type']
                    if kind in ['io_request','output']:
                        nested=e.get('event',e);output.append(nested.get('stdout',nested.get('data','')))
                        if kind=='io_request':ws.send_json(dict(command='browser_io_reply',request_id=e['request_id'],status='ok'))
                    elif kind=='prompt':
                        prompts.append(e);ws.send_json(dict(command='toplevel_respond',pid=pid,input='hello.',prompt_ref=e['prompt_ref']))
                    elif kind in ['success','error','failure']:break
                out=''.join(output);passed=e['type']=='success'
                if name=='remote source sandbox denial':passed=e['type']=='error' and 'permission_error' in str(e)
                if name=='remote exact output':passed=passed and out=='ab\ndone\n'
                if name=='copied source output':passed=passed and out=='ab\n\n'
                if name=='remote Unicode and term output':passed=passed and out=='[a,b]\nå é\npair(1,2)'
                if name=='served remote ping-pong tutorial':passed=passed and out.count('Pong received ping.')==3 and 'Pong finished.' in out and 'Ping finished.' in out
                if a.without_private_route and name in ['remote monitored completion','remote exact output','remote Unicode and term output','copied source output','served remote ping-pong tutorial']:
                    passed=e['type']=='error' and 'internal transport' in str(e).lower()
                save(name,'pass' if passed else 'fail',event=e,stdout=out,prompt_count=len(prompts),expected_denial=a.without_private_route and name.startswith(('remote monitored','remote exact','remote Unicode','copied source','served remote')))
        finally:
            if pid is not None:
                try:ws.send_json(dict(command='toplevel_halt',pid=pid))
                except Exception:pass
            ws.close()
        failed=[r for r in rows if r['result']!='pass']
        result=dict(result='fail' if failed else 'pass',private_dial_route=not a.without_private_route,checks=rows)
        a.report.write_text(json.dumps(result,indent=2)+'\n')
        return bool(failed)

if __name__=='__main__':sys.exit(main())
