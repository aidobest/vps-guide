import os, re, shlex, subprocess, json, pathlib, sys, uuid, tempfile
P=pathlib.Path
ROOT=P(__file__).resolve().parent.parent
SCRIPTS=ROOT/'scripts' if (ROOT/'scripts').is_dir() else ROOT
fixture=tempfile.TemporaryDirectory(prefix='vps-script-tests-')
base=P(fixture.name)
bin=base/'bin'; bin.mkdir(exist_ok=True)
py=sys.executable
# Every privileged command is replaced; no real service/firewall changes.
def script(name, body, python=False):
    p=bin/name; p.write_text(('#!'+py+'\n' if python else '#!/bin/bash\n')+body); p.chmod(0o755); return p
script('flock', '''import fcntl,sys
args=sys.argv[1:]; fd=int(args[-1]); op=fcntl.LOCK_UN if '-u' in args else fcntl.LOCK_EX
if '-n' in args: op |= fcntl.LOCK_NB
try: fcntl.flock(fd,op)
except BlockingIOError: sys.exit(1)
''',True)
script('id','echo 0\n')
script('sleep','exit 0\n')
script('chown','exit 0\n')
script('install','''import sys, pathlib, shutil, os
a=sys.argv[1:]; rest=[]; mode=0o755; i=0; directory=False
while i<len(a):
 if a[i] in ('-m','-o','-g'):
  if a[i]=='-m': mode=int(a[i+1],8)
  i+=2
 elif a[i]=='-d': directory=True; i+=1
 else: rest.append(a[i]); i+=1
if directory:
 for x in rest: pathlib.Path(x).mkdir(parents=True,exist_ok=True); os.chmod(x,mode)
else: shutil.copyfile(rest[-2],rest[-1]); os.chmod(rest[-1],mode)
''',True)
script('runuser','while [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
script('xray','''import json,sys,uuid
if sys.argv[1]=='uuid': print(uuid.uuid4()); sys.exit()
p=sys.argv[sys.argv.index('-config')+1]; data=json.load(open(p))
names=[x['email'] for x in data['inbounds'][0]['settings']['clients']]
sys.exit(1 if 'invalid' in names else 0)
''',True)
script('systemctl','''import os,sys,json,pathlib
with open(os.environ['CALL_LOG'],'a') as f: f.write('systemctl '+' '.join(sys.argv[1:])+'\\n')
if 'fail2ban' in ' '.join(sys.argv) and os.getenv('FAIL_F2B')=='1': sys.exit(1)
if 'xray' in sys.argv:
 d=json.load(open(os.environ['TEST_CONF'])); names=[x['email'] for x in d['inbounds'][0]['settings']['clients']]
 if 'restart' in sys.argv and 'restartfail' in names: sys.exit(1)
 if 'is-active' in sys.argv and 'unhealthy' in names: sys.exit(1)
sys.exit(0)
''',True)
script('ss', '''echo 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=123,fd=3))'
echo 'LISTEN 0 128 0.0.0.0:48222 0.0.0.0:* users:(("sshd",pid=321,fd=3))'
''')
script('qrencode', '''[ "${FAIL_QR:-0}" != 1 ] || exit 1\nprintf 'QR-MOCK %s\\n' "${@: -1}"\n''')
script('sshd','[ "${FAIL_SSH:-0}" != 1 ]\n')
script('fail2ban-client','[ "${FAIL_F2B:-0}" != 1 ]\n')
script('ufw','echo "ufw $*" >>"$CALL_LOG"\n[ "${FAIL_UFW:-0}" != 1 ]\n')
# GNU-compatible subset for sed -i used by the confirmation helper.
script('sed','''import sys,re,pathlib,subprocess
a=sys.argv[1:]
if a[0]!='-i': sys.exit(subprocess.call(['/usr/bin/sed']+a))
p=pathlib.Path(a[-1]); t=p.read_text(); e=a[1]
if e=='/^Port 22$/d': t=''.join(l for l in t.splitlines(True) if l.rstrip()!='Port 22')
elif e.startswith('s/^port    = .*/'): t=re.sub(r'^port    = .*',e.split('/')[2],t,flags=re.M)
else: raise ValueError(e)
p.write_text(t)
''',True)
path=f'{bin}:/usr/bin:/bin:/usr/sbin:/sbin'
conf=base/'config.json'; log=base/'calls.log'
env=os.environ|{'PATH':path,'CALL_LOG':str(log),'TEST_CONF':str(conf)}
source=(SCRIPTS/'vpn-setup.sh').read_text()
blocks=dict(re.findall(r"cat > ([^\n]+?) <<'EOF'\n(.*?)\nEOF",source,re.S))
def patch(t):
 t=t.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin','export PATH='+shlex.quote(path))
 for old,new in [('/usr/local/etc/xray/config.json',str(conf)),('/usr/local/lib/vpn-common.sh',str(base/'common.sh')),('/run/lock/vpn-config.lock',str(base/'vpn.lock')),('/etc/vpn/reality.env',str(base/'reality.env')),('/var/backups/vpn',str(base/'backups')),('/usr/local/bin/xray',str(bin/'xray'))]: t=t.replace(old,new)
 return t
(base/'reality.env').write_text('VPN_HOST=192.0.2.1\nVPN_PORT=443\nREALITY_SNI=example.com\nREALITY_PUB=test\nREALITY_SID=test\nXRAY_USER=test\nXRAY_GROUP=test\n')
(base/'common.sh').write_text(patch(blocks['/usr/local/lib/vpn-common.sh']))
for name in ('vpn-add','vpn-del','vpn-list','vpn-show'):
 p=base/name; p.write_text(patch(blocks['/usr/local/bin/'+name])); p.chmod(0o755)
def reset(names=('first',)):
 conf.write_text(json.dumps({'inbounds':[{'settings':{'clients':[{'email':n,'id':str(uuid.uuid4())} for n in names]}}]})); log.write_text('')
def names(): return [x['email'] for x in json.loads(conf.read_text())['inbounds'][0]['settings']['clients']]
def run(name,arg=None,extra=None):
 return subprocess.run(['/bin/bash',str(base/name)]+([arg] if arg else []),env=env|(extra or {}),text=True,capture_output=True,timeout=15)
FAILED=[]
def check(cond,label,detail=''):
 # Не останавливаемся на первой ошибке: собираем все и падаем в конце.
 if not cond:
  FAILED.append(label); print('FAIL',label,detail[:500]); return
 print('PASS',label)
reset(); r=run('vpn-add','second'); check(r.returncode==0 and names()==['first','second'],'add client',r.stderr)
u=json.loads(conf.read_text())['inbounds'][0]['settings']['clients'][1]['id']
check('vless://'+u+'@192.0.2.1:443' in r.stdout and 'QR-MOCK vless://'+u in r.stdout,'vpn-add prints matching link and QR without deadlock')
r=run('vpn-show','second'); check(r.returncode==0 and 'QR-MOCK vless://'+u in r.stdout,'standalone vpn-show prints link and QR')
r=run('vpn-add','second'); check(r.returncode!=0 and len(names())==2,'reject duplicate')
r=run('vpn-del','second'); check(r.returncode==0 and names()==['first'],'delete client',r.stderr)
r=run('vpn-del','first'); check(r.returncode!=0 and names()==['first'],'preserve last client')
for name in ('invalid','restartfail','unhealthy'):
 reset(); original=conf.read_bytes(); r=run('vpn-add',name)
 check(r.returncode!=0 and conf.read_bytes()==original,'rollback/reject '+name,r.stdout+r.stderr)
reset(); r=run('vpn-add','qr-failure',extra={'FAIL_QR':'1'}); check(r.returncode==0 and 'qr-failure' in names() and 'ВНИМАНИЕ' in r.stderr and 'vless://' in r.stdout,'QR error keeps client and link')
reset(); original=conf.read_bytes(); r=run('vpn-add','bad name'); check(r.returncode!=0 and conf.read_bytes()==original,'reject invalid name')
reset(); procs=[subprocess.Popen(['/bin/bash',str(base/'vpn-add'),'same'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)]
results=[p.communicate(timeout=15) for p in procs]; check(sorted(p.returncode for p in procs)==[0,1] and names().count('same')==1,'concurrent duplicate add',str(results))
reset(('first','second')); procs=[subprocess.Popen(['/bin/bash',str(base/'vpn-del'),n],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for n in ('first','second')]
results=[p.communicate(timeout=15) for p in procs]; check(sorted(p.returncode for p in procs)==[0,1] and len(names())==1,'concurrent delete preserves last',str(results))
# Syntax check of source and all generated shell helpers, including expanded heredoc.
h=(SCRIPTS/'harden.sh').read_text()
vals={'LOG':'/var/log/vps-harden.log','ROLLBACK_MINUTES':'20','SSHD_DROPIN':'/etc/ssh/sshd_config.d/00-vps-hardening.conf','BACKUP_DIR':'/root/vps-harden-backup.TEST','OLD_PORTS':'2222 ','NEW_USER':'admin','SSH_PORT':'48222','PUBLIC_IP':'192.0.2.1'}
def extract(text):
 out={}
 for m in re.finditer(r"cat > ([^\n]+?) <<('?)(EOF)\2\n(.*?)\nEOF",text,re.S):
  target,quoted,_,body=m.groups()
  if not (body.startswith('#!/usr/bin/env bash') or target.endswith('/vpn-common.sh')): continue
  if not quoted:
   pre='\n'.join(k+'='+shlex.quote(v) for k,v in vals.items())+'\n'
   body=subprocess.run(['/bin/bash'],input=pre+'cat <<EOF\n'+body+'\nEOF\n',text=True,capture_output=True,check=True).stdout
  r=subprocess.run(['/bin/bash','-n'],input=body,text=True,capture_output=True)
  check(r.returncode==0,'syntax '+target,r.stderr); out[target]=body
 return out
hb=extract(h); extract(source)
for p in (SCRIPTS/'harden.sh', SCRIPTS/'vpn-setup.sh'):
 r=subprocess.run(['/bin/bash','-n',p],capture_output=True,text=True); check(r.returncode==0,'syntax '+str(p),r.stderr)
# Confirmation helper uses only a sandboxed synthetic filesystem.
root=base/'rootfs'
def rootpatch(t):
 t=re.sub(r'(?<![\w])/(etc|var|run|root)(?=/)',lambda m:str(root)+'/'+m.group(1),t)
 t=t.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin','export PATH='+shlex.quote(path))
 return t
for name in ('vps-confirm','vps-harden-rollback'):
 (base/name).write_text(rootpatch(hb['/usr/local/sbin/'+name]))
for d in ('etc/ssh/sshd_config.d','etc/fail2ban','etc/default','etc/ufw','var/lib/vps-harden','var/log','run/lock','root'):
 (root/d).mkdir(parents=True,exist_ok=True)
pending=root/'var/lib/vps-harden/pending'; drop=root/'etc/ssh/sshd_config.d/00-vps-hardening.conf'
def reset_confirm():
 pending.touch(); drop.write_text('Port 48222\nPort 22\n'); (root/'var/lib/vps-harden/added-port22').write_text('1\n'); (root/'etc/fail2ban/jail.local').write_text('port    = 48222,22\n'); log.write_text('')
for fail in ('FAIL_SSH','FAIL_UFW'):
 reset_confirm(); r=run('vps-confirm',extra={fail:'1'})
 check(r.returncode!=0 and pending.exists() and 'disable --now vps-harden-rollback.timer' not in log.read_text(),'confirmation failure keeps timer '+fail,r.stderr)
reset_confirm(); r=run('vps-confirm',extra={'FAIL_F2B':'1'}); check(r.returncode==0 and not pending.exists() and 'ВНИМАНИЕ' in r.stderr,'fail2ban warning permits SSH confirmation',repr((r.returncode,r.stdout,r.stderr,log.read_text())))
reset_confirm(); r=run('vps-confirm'); check(r.returncode==0 and not pending.exists(),'successful confirmation',r.stderr)
reset_confirm(); (root/'run/sshd').exists() and (root/'run/sshd').rmdir(); r=run('vps-confirm'); check(r.returncode==0 and (root/'run/sshd').is_dir(),'confirm recreates /run/sshd before sshd -t',r.stderr)
# После full-upgrade (needrestart перезапускает ssh) /run/sshd пропадает: шаг 4 создаёт его перед sshd -T.
s4=h[h.index('step "4/9'):]; check(s4.index('install -d -m 0755 /run/sshd')<s4.index('sshd -T'),'step 4 recreates /run/sshd after upgrade')
# Real file copies/restoration; service responses are mocks.
backup=root/'root/vps-harden-backup.TEST'; backup.mkdir(exist_ok=True)
(backup/'sshd_config').write_text('Port 2222\n'); (backup/'sshd_config.d').mkdir(exist_ok=True); (backup/'sshd_config.d/old.conf').write_text('PermitRootLogin yes\n')
(backup/'ufw').mkdir(exist_ok=True); (backup/'ufw/user.rules').write_text('old firewall rules\n'); (backup/'ufw-default').write_text('DEFAULT_INPUT_POLICY="ACCEPT"\n'); (backup/'ufw-was-active').write_text('1\n'); (backup/'jail.local').write_text('old jail\n'); (backup/'ssh-mode').write_text('service\n')
for unit in ('ssh.service','ssh.socket','fail2ban.service'):
 (backup/(unit+'.load')).write_text('loaded\n')
 (backup/(unit+'.enabled')).write_text('disabled\n' if unit=='ssh.socket' else 'enabled\n'); (backup/(unit+'.active')).write_text('active\n')
(root/'var/lib/vps-harden/backup-path').write_text(str(backup)+'\n')
reset_confirm(); r=run('vps-harden-rollback')
check((root/'run/sshd').is_dir(),'rollback creates /run/sshd for sshd -t on Ubuntu 24.04 socket mode',r.stderr)
check(r.returncode==0 and not pending.exists() and (root/'etc/default/ufw').read_text()==(backup/'ufw-default').read_text() and (root/'etc/ufw/user.rules').read_text()=='old firewall rules\n' and (root/'etc/ssh/sshd_config').read_text()=='Port 2222\n','restore SSH and full firewall files',r.stderr)
reset_confirm(); r=run('vps-harden-rollback',extra={'FAIL_UFW':'1'}); check(r.returncode!=0 and pending.exists(),'rollback error remains retryable',r.stderr)
# Distinguish absent service, disabled service, and inactive but enabled service.
for loaded,enabled,active,expected in (
 ('not-found','not-found','inactive','disable --now fail2ban.service'),
 ('loaded','enabled','inactive','enable fail2ban.service'),
 ('loaded','disabled','active','disable fail2ban.service')):
 (backup/'fail2ban.service.load').write_text(loaded+'\n')
 (backup/'fail2ban.service.enabled').write_text(enabled+'\n')
 (backup/'fail2ban.service.active').write_text(active+'\n')
 reset_confirm(); r=run('vps-harden-rollback'); calls=log.read_text()
 action='restart' if active=='active' else 'stop'
 check(r.returncode==0 and expected in calls and 'systemctl '+action+' fail2ban.service' in calls,'restore fail2ban '+loaded+'/'+enabled+'/'+active,r.stderr)
# Execute the real upgrade branch with an apt-get stub.
script('apt-get','echo \"apt-get $*\" >>\"$CALL_LOG\"\n')
block=re.search(r'if \[ \"\$\{UPGRADE_SYSTEM:-1\}\" = 1 \]; then\n.*?\nfi',h,re.S).group(0)
for value,want in ((None,True),('1',True),('0',False)):
 log.write_text(''); e=env.copy(); e.pop('UPGRADE_SYSTEM',None)
 if value is not None: e['UPGRADE_SYSTEM']=value
 r=subprocess.run(['/bin/bash','-e'],input=block,text=True,capture_output=True,env=e)
 check(r.returncode==0 and ('upgrade' in log.read_text())==want,'upgrade default/override '+str(value),r.stderr)
for p in (SCRIPTS/'harden.sh',SCRIPTS/'vpn-setup.sh'):
 r=subprocess.run(['/bin/bash',str(p),'--help'],capture_output=True,text=True)
 check(r.returncode==0 and 'Использование' in r.stdout,'help '+p.name,r.stderr)
# Проверка формата публичного ключа (harden.sh: pubkeys_ok) на отдельных строках.
fn=re.search(r"pubkeys_ok\(\) \{.*?\n\}", (SCRIPTS/'harden.sh').read_text(), re.S).group(0)
kd=pathlib.Path(tempfile.mkdtemp(prefix='keys-',dir=base))
subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C','me@test','-f',str(kd/'k')],check=True)
pub=(kd/'k.pub').read_text().strip(); priv=(kd/'k').read_text()
cases={
 'public key':(pub,True),
 'two public keys':(pub+'\n'+pub.replace('me@test','other'),True),
 'hoster options before key':('no-port-forwarding,command="echo \'Please login as ubuntu\'" '+pub,True),
 'private key':(priv,False),
 'public + private':(pub+'\n'+priv,False),
 'garbage':('hello world',False),
 'empty':('',False),
}
for label,(text,want) in cases.items():
 f=kd/'in'; f.write_text(text+'\n')
 r=subprocess.run(['/bin/bash','-c',fn+'\npubkeys_ok "$1"','x',str(f)],capture_output=True,text=True)
 check((r.returncode==0)==want,'pubkeys_ok '+label,r.stderr)
if FAILED:
 print(f'FAILED {len(FAILED)}:',', '.join(FAILED)); fixture.cleanup(); sys.exit(1)
print('ALL CHECKS PASSED. These are mocked service tests, not a real VPS deployment.')
fixture.cleanup()
