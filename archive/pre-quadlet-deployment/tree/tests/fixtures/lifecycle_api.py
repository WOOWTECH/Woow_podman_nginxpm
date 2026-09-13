#!/usr/bin/env python3
"""File-backed NPM API state machine used only by lifecycle mock tests."""
import argparse, json, os, sys
state_dir=os.environ['FAKE_RUNTIME_STATE']; state_path=os.path.join(state_dir,'api.json'); events=os.path.join(state_dir,'events')

def private_value(path):
    return open(path,encoding='utf-8').read().rstrip('\n')
def load():
    if not os.path.exists(state_path):
        value={'email':None,'password':None}
        with open(state_path,'w') as f: json.dump(value,f)
        return value
    with open(state_path) as f: return json.load(f)
def save(value):
    with open(state_path,'w') as f: json.dump(value,f)
p=argparse.ArgumentParser(); p.add_argument('command',choices=('ready','auth','change-password')); p.add_argument('--url',required=True)
p.add_argument('--identity-file'); p.add_argument('--password-file'); p.add_argument('--current-file'); p.add_argument('--new-file'); p.add_argument('--new-identity-file')
a=p.parse_args(); value=load()
with open(events,'a') as f: f.write('api '+a.command+'\n')
if os.environ.get('FAKE_FAIL_ONCE')=='api-'+a.command:
    marker=os.path.join(state_dir,'failed.api-'+a.command)
    if not os.path.exists(marker): open(marker,'w').close(); raise SystemExit(20)
if a.command=='ready': print('READY'); raise SystemExit(0)
if a.command=='auth':
    identity=private_value(a.identity_file); password=private_value(a.password_file)
    if identity==value['email'] and password==value['password']: print('OK'); raise SystemExit(0)
    if os.environ.get('FAKE_DEFAULT_AUTH_VALID')=='1' and identity=='admin@example.com' and password=='changeme': print('OK'); raise SystemExit(0)
    raise SystemExit(10)
if private_value(a.identity_file)!=value['email'] or private_value(a.current_file)!=value['password']: raise SystemExit(10)
replacement=private_value(a.new_file)
if os.environ.get('FAKE_INTERRUPT_ROTATION_ONCE')=='1' and replacement!=value['password']:
    marker=os.path.join(state_dir,'failed.interrupted-rotation')
    if not os.path.exists(marker):
        value={'email':value['email'],'password':replacement}; save(value); open(marker,'w').close(); raise SystemExit(20)
value={'email':private_value(a.new_identity_file),'password':replacement}; save(value); print('CHANGED')
