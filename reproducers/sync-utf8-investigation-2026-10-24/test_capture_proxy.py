"""End-to-end proxy transparency including invalid UTF-8 and half-close."""
from pathlib import Path
import tempfile,socket,threading,subprocess,sys,time,signal,json,hashlib
ROOT=Path(__file__).resolve().parent;payload=bytes(range(256))*20;received=[]
with socket.socket()as backend:
 backend.bind(('127.0.0.1',0));backend.listen(1);back=backend.getsockname()[1]
 def peer():
  with backend.accept()[0]as c:
   blocks=[]
   while True:
    b=c.recv(65536)
    if not b:break
    blocks.append(b)
   received.append(b''.join(blocks));c.sendall(payload[::-1])
 t=threading.Thread(target=peer,daemon=True);t.start()
 with socket.socket()as s:s.bind(('127.0.0.1',0));front=s.getsockname()[1]
 with tempfile.TemporaryDirectory()as directory:
  d=Path(directory)
  with (d/'proxy.log').open('w')as log:
   p=subprocess.Popen([sys.executable,str(ROOT/'capture_proxy.py'),str(d/'wire'),str(back),str(front)],stdout=log,stderr=log)
   try:
    for _ in range(200):
     if '"ready": true' in (d/'proxy.log').read_text():break
     time.sleep(.01)
    else:raise AssertionError('proxy did not start')
    with socket.create_connection(('127.0.0.1',front),timeout=3)as c:
     c.sendall(payload);c.shutdown(socket.SHUT_WR);response=[]
     while True:
      b=c.recv(65536)
      if not b:break
      response.append(b)
    t.join(timeout=3);assert not t.is_alive();assert received==[payload];assert b''.join(response)==payload[::-1]
   finally:
    p.send_signal(signal.SIGTERM);p.wait(timeout=4)
   assert (d/'wire/001-c2s.bin').read_bytes()==payload
   assert (d/'wire/001-s2c.bin').read_bytes()==payload[::-1]
   meta=json.loads((d/'wire/connections.json').read_text());assert len(meta)==1
   for direction in meta[0]['directions'].values():assert direction=={'received':len(payload),'forwarded':len(payload)}
   result={'passed':True,'bytes_each_direction':len(payload),'includes_all_byte_values':True,'half_close_preserved':True,'client_sha256':hashlib.sha256(payload).hexdigest(),'server_sha256':hashlib.sha256(payload[::-1]).hexdigest()}
   (ROOT/'proxy-selftest.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
