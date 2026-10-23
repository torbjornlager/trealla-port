import http.server,socket,select,http.client
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def do_GET(self):self.forward()
 def do_POST(self):self.forward()
 def forward(self):
  path=self.path.split('?')[0]
  backend=44311 if path in ['/ws','/call','/node_info','/node_api','/toplevel_spawn','/toplevel_call','/toplevel_next','/toplevel_stop','/toplevel_halt'] else 3053
  if path=='/ws':
   with socket.create_connection(('127.0.0.1',backend)) as s:
    s.sendall((self.requestline+'\r\n'+''.join(k+': '+v+'\r\n' for k,v in self.headers.items())+'\r\n').encode())
    while True:
     ready,_,_=select.select([s,self.connection],[],[],60)
     if not ready:break
     for src in ready:
      data=src.recv(65536)
      if not data:return
      (self.connection if src is s else s).sendall(data)
   self.close_connection=True;return
  c=http.client.HTTPConnection('127.0.0.1',backend,timeout=30)
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  headers={k:v for k,v in self.headers.items() if k.lower() not in ['connection','accept-encoding','host']}
  c.request(self.command,self.path,body,headers);r=c.getresponse();data=r.read();self.send_response(r.status)
  for k,v in r.getheaders():
   if k.lower() not in ['transfer-encoding','content-length','connection']:self.send_header(k,v)
  self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);c.close()
http.server.ThreadingHTTPServer(('127.0.0.1',44310),Handler).serve_forever()
