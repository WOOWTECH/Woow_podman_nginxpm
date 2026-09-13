#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
EMAIL=os.environ['FAKE_EMAIL']; PASSWORD=os.environ['FAKE_PASSWORD']; LOG=os.environ['FAKE_LOG']; DELAY_FILE=os.environ.get('FAKE_DELAY_FILE')
state={'email':EMAIL,'password':PASSWORD}
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def body(self):
        n=int(self.headers.get('Content-Length','0')); raw=self.rfile.read(n)
        with open(LOG,'ab') as f: f.write(self.command.encode()+b' '+self.path.encode()+b' '+raw+b'\n')
        return json.loads(raw or b'{}')
    def send(self, code, value):
        raw=json.dumps(value).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path=='/api/': self.send(200,{'status':'OK'})
        elif self.path=='/api/users/me' and self.headers.get('Authorization')=='Bearer fixture-token': self.send(200,{'id':1})
        else: self.send(404,{'error':'not found'})
    def do_POST(self):
        b=self.body()
        if self.path=='/api/tokens' and b.get('identity')==state['email'] and b.get('secret')==state['password']:
            if DELAY_FILE and os.path.exists(DELAY_FILE): time.sleep(2)
            self.send(200,{'token':'fixture-token'})
        else: self.send(401,{'error':'rejected','reflected':b})
    def do_PUT(self):
        b=self.body()
        if self.headers.get('Authorization')!='Bearer fixture-token': self.send(401,{'error':'token'}); return
        if self.path=='/api/users/1': state['email']=b['email']; self.send(200,{'id':1})
        elif self.path=='/api/users/1/auth' and b.get('current')==state['password']:
            state['password']=b['secret']; self.send(200,{})
        else: self.send(400,{'error':'bad','reflected':b})
ThreadingHTTPServer(('127.0.0.1',18081),Handler).serve_forever()
