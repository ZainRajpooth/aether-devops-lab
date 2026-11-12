import sys,os,re,tempfile

src,sec,datapath,redirc,work=sys.argv[1:6]
os.makedirs(redirc,exist_ok=True)
os.chmod(redirc,0o700)
os.makedirs(work,exist_ok=True)
os.chmod(work,0o700)

TL=re.compile(r'^"?([A-Za-z_]+)"?:\s*$')
SVC=re.compile(r'^  "?([A-Za-z0-9_.-]+)"?:\s*$')
SUB=re.compile(r'^    "?([A-Za-z_]+)"?:\s*$')
IT=re.compile(r'^\s+- "?([^"]*)"?\s*$')
ENVKV=re.compile(r'^      "([^"]+)": "(.*)"$')

def tlk(l):
    m=TL.match(l)
    if m:
        return m.group(1)
    return None

def unesc(s):
    o=[]
    i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s):
            n=s[i+1]
            if n=='n':
                o.append('\n'); i+=2; continue
            if n=='r':
                o.append('\r'); i+=2; continue
            if n=='t':
                o.append('\t'); i+=2; continue
            if n=='"':
                o.append('"'); i+=2; continue
            if n=='\\':
                o.append('\\'); i+=2; continue
            o.append(c); i+=1; continue
        o.append(c); i+=1
    return ''.join(o)

argv=[]
n8n_pass=None
n8n_key=None
cur=None
sub=None

for raw in open(src,encoding='utf-8'):
    l=raw.rstrip('\n')
    k=tlk(l)
    if k=='services':
        cur=None
        sub=None
        continue
    sm=SVC.match(l)
    if sm:
        cur=sm.group(1)
        sub=None
        continue
    sb=SUB.match(l)
    if sb:
        sub=sb.group(1)
        continue
    if cur=='redis' and sub=='command':
        it=IT.match(l)
        if it:
            argv.append(it.group(1))
    if cur=='n8n' and sub=='environment':
        m=ENVKV.match(l)
        if m and 'redis' in m.group(1).lower() and ('pass' in m.group(1).lower() or 'pwd' in m.group(1).lower()):
            if n8n_key is None:
                n8n_key=m.group(1)
            n8n_pass=unesc(m.group(2))

P_argv=None
i=0
conf_flags=[]
while i<len(argv):
    w=argv[i]
    if w=='redis-server':
        i+=1
        continue
    if w.startswith('--'):
        name=w[2:]
        vals=[]
        i+=1
        while i<len(argv) and not argv[i].startswith('--') and argv[i]!='redis-server':
            vals.append(argv[i])
            i+=1
        if name=='requirepass':
            P_argv=(vals[0] if vals else '')
        else:
            conf_flags.append((name,vals))
    else:
        conf_flags.append(('<positional '+w,[]))
        i+=1

has_auth=(P_argv is not None) or (n8n_pass is not None)
mismatch=(P_argv is not None and n8n_pass is not None and P_argv!=n8n_pass)

if P_argv not in (None,''):
    P=P_argv
    source='argv'
elif n8n_pass not in (None,''):
    P=n8n_pass
    source='n8n-env'
else:
    P=''
    source='none'

ALLOW = {
    "masterauth",
    "bind",
    "port",
    "protected-mode",
    "timeout",
    "tcp-keepalive",
    "databases",
    "save",
    "appendonly",
    "appendfsync",
    "no-appendfsync-on-rewrite",
    "auto-aof-rewrite-percentage",
    "auto-aof-rewrite-min-size",
    "maxmemory",
    "maxmemory-policy",
    "hz",
    "loglevel",
    "logfile",
    "syslog-enabled",
    "syslog-ident",
    "syslog-facility",
    "dir",
    "client-output-buffer-limit",
    "slowlog-log-slower-than",
    "slowlog-max-len",
    "latency-monitor-history-limit",
    "activedefrag",
    "active-defrag-threshold-lower",
    "active-defrag-threshold-upper",
    "active-defrag-ignore-bytes",
    "active-defrag-cycle-min",
    "active-defrag-cycle-max",
    "active-defrag-max-scan-fields",
    "lua-time-limit",
    "replica-serve-stale-data",
    "replica-read-only",
    "replicas-ignore-maxmemory",
    "repl-diskless-load",
    "repl-diskless-sync",
    "repl-diskless-sync-delay",
    "repl-backlog-size",
    "repl-backlog-ttl",
    "repl-ping-replica-period",
    "min-replicas-to-write",
    "min-replicas-max-lag",
    "notify-keyspace-events",
    "io-threads",
    "io-threads-do-reads",
    "enable-debug-command",
    "enable-module-command",
    "enable-protected-configs",
    "proto-max-bulk-len",
    "maxmemory-samples",
    "jemalloc-bg-thread",
}
DENY={"version","help","v","sentinel","check-single-config","test"}
unknown=sorted(set(n for n,_ in conf_flags if (n in DENY) or n.startswith('<positional') or n not in ALLOW))

status='OK'
halt_reason=''
if mismatch:
    status='HALT'
    halt_reason='argv requirepass differs from n8n redis-password env (capture internally inconsistent); not auto-picking'
elif unknown:
    status='HALT'
    halt_reason='unmapped redis flag(s): '+', '.join(unknown)

final_pass=''
if status=='OK':
    lines=open(sec,encoding='utf-8').read().split('\n') if os.path.isfile(sec) else []
    have=any(re.match(r'^REDIS_PASSWORD=',x) for x in lines)
    if has_auth and P:
        if not have:
            if lines and lines[-1]!='':
                lines.append('')
            ins=(len(lines)-1) if (lines and lines[-1]=='') else len(lines)
            lines.insert(ins,'REDIS_PASSWORD='+P)
            with open(sec,'w',encoding='utf-8') as f:
                f.write('\n'.join(lines))
            os.chmod(sec,0o600)
        for x in open(sec,encoding='utf-8'):
            m=re.match(r'^REDIS_PASSWORD=(.*)$',x.rstrip('\n'))
            if m:
                final_pass=m.group(1)
                break
        if not final_pass:
            final_pass=P
        if final_pass and re.search(r'[\s"\\#]', final_pass):
            status='HALT'
            halt_reason='requirepass contains whitespace/quote/backslash/hash; not safe for unquoted redis.conf line'
    elif has_auth and not P:
        status='HALT'
        halt_reason='has_auth but no recoverable password (argv and n8n env both empty)'

if status=='OK':
    cl=[]
    seen_dir=False
    for n,vals in conf_flags:
        if n=='dir':
            seen_dir=True
            cl.append('dir '+datapath)
            continue
        if vals:
            cl.append(n+' '+' '.join(vals))
        else:
            cl.append(n)
    if not seen_dir:
        cl.append('dir '+datapath)
    if has_auth and final_pass:
        cl.append('requirepass '+final_pass)

    conf_path=os.path.join(redirc,'redis.conf')
    fd,tmp=tempfile.mkstemp(dir=redirc, prefix='.redis.conf.', text=True)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write('\n'.join(cl)+'\n')
        os.chmod(tmp,0o600)
        os.replace(tmp,conf_path)
    except Exception as e:
        if os.path.exists(tmp):
            os.unlink(tmp)
        status='HALT'
        halt_reason='atomic conf write failed: '+str(e)

av='na'
if P_argv is not None and n8n_pass is not None:
    if P_argv==n8n_pass:
        av='match'
    else:
        av='mismatch'

PASS_SHAPE='absent'
if final_pass:
    PASS_LEN=len(final_pass)
    PASS_HAS_SPACE='yes' if re.search(r'\s', final_pass) else 'no'
    PASS_QUOTED='no'
    if len(final_pass)>=2:
        if (final_pass[0]=='"' and final_pass[-1]=='"') or (final_pass[0]=="'" and final_pass[-1]=="'"):
            PASS_QUOTED='yes'
    PASS_SHAPE='len='+str(PASS_LEN)+' has_space='+PASS_HAS_SPACE+' quoted='+PASS_QUOTED

with open(os.path.join(work,'summary.txt'),'w',encoding='utf-8') as f:
    f.write('has_auth=%s\n'%('yes' if has_auth else 'no'))
    f.write('auth_source=%s\n'%source)
    f.write('argv_vs_n8n=%s\n'%av)
    f.write('n8n_redis_env_key=%s\n'%(n8n_key or ''))
    f.write('flags=%s\n'%' '.join(n for n,_ in conf_flags))
    f.write('requirepass_shape=%s\n'%PASS_SHAPE)
    f.write('status=%s\n'%status)
    if halt_reason:
        f.write('halt_reason=%s\n'%halt_reason)

open(os.path.join(work,'status'),'w',encoding='utf-8').write(status+'\n')
sys.exit(0 if status=='OK' else 2)
