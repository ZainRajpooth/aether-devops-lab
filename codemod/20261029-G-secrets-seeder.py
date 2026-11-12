import sys,os,re
SRC = sys.argv[1] if len(sys.argv)>1 else os.path.expanduser("~/DevOps/aether/legacy/compose/recovery-runtime.yml")
SEC = sys.argv[2] if len(sys.argv)>2 else os.path.expanduser("~/.config/aether/secrets.env")
CRITICAL = ["POSTGRES_PASSWORD","MINIO_ROOT_PASSWORD","WEAVIATE_API_KEY",
            "AUTHENTICATION_APIKEY_ALLOWED_KEYS","LITELLM_MASTER_KEY","N8N_ENCRYPTION_KEY"]
NOISE = {"PATH","HOSTNAME","container"}
SAFE  = re.compile(r'^[A-Za-z0-9._:/+=,@-]*$')      # no space/#/quote/backslash/newline
TL    = re.compile(r'^"?([A-Za-z_]+)"?:\s*$')
SVC   = re.compile(r'^  "?([A-Za-z0-9_.-]+)"?:\s*$')
SUB   = re.compile(r'^    "?([A-Za-z_]+)"?:\s*$')
ENVKV = re.compile(r'^      "([^"]+)": "(.*)"$')     # 6-space dict entry (captured form)
def tlk(l):
    m=TL.match(l); return m.group(1) if m else None
def unesc(s):
    o=[];i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s):
            n=s[i+1]
            if n=='n':o.append('\n');i+=2;continue
            if n=='r':o.append('\r');i+=2;continue
            if n=='t':o.append('\t');i+=2;continue
            if n=='"':o.append('"');i+=2;continue
            if n=='\\':o.append('\\');i+=2;continue
            o.append(c);i+=1;continue
        o.append(c);i+=1
    return ''.join(o)

# ---- scoped parse: env literals ONLY from the services region, environment sub-key ----
kv={}                      # key -> set(values)
in_svc=False; cur_sub=None
for raw in open(SRC):
    l=raw.rstrip('\n'); k=tlk(l)
    if k=='services': in_svc=True; cur_sub=None; continue
    if k: in_svc=False; cur_sub=None; continue          # left services block
    if not in_svc: continue
    if SVC.match(l): cur_sub=None; continue             # new service resets sub-key
    sm=SUB.match(l)
    if sm: cur_sub=sm.group(1); continue
    if cur_sub=='environment':
        m=ENVKV.match(l)
        if m:
            key=m.group(1); val=unesc(m.group(2))
            if key in NOISE or val.startswith('${'): continue   # noise / unresolved placeholder
            kv.setdefault(key,set()).add(val)

# ---- classify ----
collisions={k:sorted(v) for k,v in kv.items() if len(v)>1}
union={k:next(iter(v)) for k,v in kv.items() if len(v)==1}
writeable={}; worklist={}
for k,v in union.items():
    (writeable if SAFE.match(v) else worklist)[k]=v

exists = os.path.isfile(SEC) and os.path.getsize(SEC)>0
have=set()
if exists:
    for l in open(SEC):
        m=re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=',l)
        if m: have.add(m.group(1))
    missing=[c for c in CRITICAL if c not in have]
    print(f"  [EXIST] secrets.env present ({len(have)} keys) -> NOT overwritten (edit-protected)")
    print(f"  [EXIST] criticals in file: {', '.join(c for c in CRITICAL if c in have) or '<none>'}")
    if missing: print(f"  [FATAL] criticals MISSING from existing file: {', '.join(missing)}")
    print(f"  [REPORT] capture collisions (excluded, investigate): {', '.join(sorted(collisions)) or '<none>'}")
    sys.exit(1 if missing else 0)

# ---- NEW branch: write only if no fatal-missing ----
covered=set(writeable)|set(worklist)
missing=[c for c in CRITICAL if c not in covered]
print(f"  [PARSE] distinct env keys from 13-capture: {len(kv)}  (writeable {len(writeable)}, worklist {len(worklist)}, collisions {len(collisions)})")
if collisions: print(f"  [COLLISION-EXCLUDED] {', '.join(sorted(collisions))}  (same key, >1 value -> incoherent capture; resolve by hand, NOT auto-picked)")
if worklist:   print(f"  [WORKLIST per-unit Environment=] {', '.join(sorted(worklist))}  (value has space/#/quote/backslash -> unsafe in env-file; set inline in the unit)")
if missing:
    print(f"  [FATAL] criticals absent from capture (neither writeable nor worklist): {', '.join(missing)} -> writing NOTHING (no partial secrets.env)")
    sys.exit(1)
os.makedirs(os.path.dirname(SEC),exist_ok=True)
with open(SEC,'w') as f:
    f.write("# Unified env source for the STATEFUL quadlet tier (secrets + service config).\n")
    f.write("# 0600, OUTSIDE the repo. Single source => rotation is a one-file edit, desync impossible.\n")
    f.write("# Values extracted verbatim from the 13-service live capture (recovery-runtime.yml).\n")
    for k in sorted(writeable): f.write(f"{k}={writeable[k]}\n")
os.chmod(SEC,0o600)
print(f"  [WROTE] {SEC}  ({len(writeable)} keys, 0600, values never echoed)")
print(f"  [CRITICAL PRESENT] {', '.join(c for c in CRITICAL if c in covered)}")
print(f"  [EXPECTED-ABSENT] ZITADEL_MASTERKEY (zitadel stopped at capture; authored fresh step-4)")
sys.exit(0)
