import json, os, subprocess

HOME = os.path.expanduser("~")
A  = os.path.join(HOME, "DevOps", "aether")
LC = os.path.join(A, "legacy", "compose")
OUT  = os.path.join(LC, "emergency-recovery.yml")
LOCK = os.path.join(LC, "images.lock.tsv")
os.makedirs(LC, exist_ok=True)

EXCL_NAME  = ("k3d-",)
EXCL_IMAGE = ("rancher/k3s", "registry:", "ghcr.io/k3d-io/")
SECRET_HINTS = ("PASSWORD","PASSWD","KEY","SECRET","TOKEN","MASTER",
                "ENCRYPTION","APIKEY","AUTH","CREDENTIAL","PRIVATE")

def run(c): return subprocess.run(c, capture_output=True, text=True)
def is_secret(k):
    ku = k.upper(); return any(h in ku for h in SECRET_HINTS)
def ns_to_dur(n):
    try: n = int(n)
    except: return None
    return f"{n//10**9}s" if n > 0 else None

# ---- enumerate non-k3d running containers ----
names = []
for ln in run(["docker","ps","--format","{{json .}}"]).stdout.splitlines():
    ln = ln.strip()
    if not ln: continue
    try: c = json.loads(ln)
    except: continue
    nm = c.get("Names","").lstrip("/")
    img = c.get("Image","")
    if not nm or nm.startswith(EXCL_NAME) or img.startswith(EXCL_IMAGE): continue
    names.append(nm)

services, vol_set, net_set, missing_binds = {}, set(), set(), []

for nm in names:
    raw = run(["docker","inspect",nm]).stdout
    if not raw.strip(): continue
    d = json.loads(raw)[0]
    cfg = d.get("Config") or {}; hc = d.get("HostConfig") or {}
    netset = (d.get("NetworkSettings") or {}).get("Networks") or {}
    s = {}
    s["image"] = cfg.get("Image","")
    cn = (d.get("Name") or "").lstrip("/")
    if cn: s["container_name"] = cn
    rp = (hc.get("RestartPolicy") or {}).get("Name")
    if rp and rp != "no": s["restart"] = rp
    if cfg.get("Cmd"): s["command"] = list(cfg["Cmd"])

    env = {}
    for e in (cfg.get("Env") or []):
        k,_,v = e.partition("=")
        if k in ("PATH","HOSTNAME"): continue
        env[k] = v
    if env: s["environment"] = {k: env[k] for k in sorted(env)}

    vols = []
    for m in (d.get("Mounts") or []):
        dst = m.get("Destination","")
        if not dst: continue
        mode = "" if m.get("RW",True) else ":ro"
        src = m.get("Source","")
        if m.get("Type") == "volume":
            vn = (src.rstrip("/").split("/")[-1]) if src else m.get("Name","")
            if vn: vols.append(f"{vn}:{dst}{mode}"); vol_set.add(vn)
        elif m.get("Type") == "bind":
            vols.append(f"{src}:{dst}{mode}")
            if src.startswith("/") and not os.path.exists(src):
                missing_binds.append((nm, src))
    if vols: s["volumes"] = vols

    ports = []
    for cp, binds in (hc.get("PortBindings") or {}).items():
        cport, proto = (cp.split("/",1) if "/" in cp else (cp,"tcp"))
        for b in (binds or []):
            hp = b.get("HostPort"); hip = b.get("HostIp","")
            if not hp: continue
            pre = f"{hip}:" if hip and hip not in ("0.0.0.0","") else ""
            ports.append(f"{pre}{hp}:{cport}/{proto}")
    if ports: s["ports"] = ports

    nmode = hc.get("NetworkMode","")
    if nmode in ("host","none") or nmode.startswith("container:"):
        s["network_mode"] = nmode
    else:
        svcnets = [n for n in netset.keys() if n != "bridge"]
        if svcnets: s["networks"] = svcnets; net_set.update(svcnets)
    pid = hc.get("PidMode","")
    if pid and pid != "private": s["pid"] = pid
    if hc.get("Privileged"): s["privileged"] = True
    if hc.get("CapAdd"): s["cap_add"] = list(hc["CapAdd"])
    if hc.get("Devices"):
        dl = []
        for dv in hc["Devices"]:
            pp=dv.get("PathOnHost",""); cp2=dv.get("PathInContainer",""); pm=dv.get("CgroupPermissions","rwm")
            dl.append(f"{pp}:{cp2}:{pm}" if cp2 else pp)
        if dl: s["devices"] = dl
    if hc.get("SecurityOpt"): s["security_opt"] = list(hc["SecurityOpt"])
    if hc.get("ReadonlyRootfs"): s["read_only"] = True

    labs = {k:v for k,v in (cfg.get("Labels") or {}).items()
            if not k.startswith("com.docker.compose.")}
    if labs: s["labels"] = {k: labs[k] for k in sorted(labs)}

    hk = cfg.get("Healthcheck") or {}
    if hk.get("Test"):
        hh = {"test": list(hk["Test"])}
        for ik,ck in (("Interval","interval"),("Timeout","timeout"),("StartPeriod","start_period")):
            dv = ns_to_dur(hk.get(ik));  hh[ck] = dv if dv else None
        hh = {k:v for k,v in hh.items() if v is not None}
        if hk.get("Retries"): hh["retries"] = int(hk["Retries"])
        s["healthcheck"] = hh

    services[nm] = s

services = {k: services[k] for k in sorted(services)}
doc = {"services": services}
if vol_set: doc["volumes"]  = {v: {"external": True} for v in sorted(vol_set)}
if net_set: doc["networks"] = {n: {"external": True} for n in sorted(net_set)}

# ---- guaranteed-valid YAML emitter: quote every leaf, bare booleans, sorted ----
def esc(x):
    return (str(x).replace("\\","\\\\").replace('"','\\"')
            .replace("\n","\\n").replace("\r","\\r").replace("\t","\\t"))
def qv(x): return '"' + esc(x) + '"'
def emit_map(mp, ind):
    out=[]; pad=" "*ind
    for k,v in mp.items():
        if isinstance(v,bool):   out.append(f"{pad}{qv(k)}: {'true' if v else 'false'}")
        elif isinstance(v,dict): out.append(f"{pad}{qv(k)}:"); out += emit_map(v, ind+2)
        elif isinstance(v,list):
            out.append(f"{pad}{qv(k)}:")
            for it in v:
                if isinstance(it,dict):   out.append(f"{pad}-"); out += emit_map(it, ind+2)
                elif isinstance(it,list): out.append(f"{pad}-"); out += emit_list(it, ind+2)
                else:                     out.append(f"{pad}- {qv(it)}")
        else: out.append(f"{pad}{qv(k)}: {qv(v)}")
    return out
def emit_list(lst, ind):
    out=[]; pad=" "*ind
    for it in lst:
        if isinstance(it,dict): out.append(f"{pad}-"); out += emit_map(it, ind+2)
        else:                   out.append(f"{pad}- {qv(it)}")
    return out

with open(OUT,"w") as f: f.write("\n".join(emit_map(doc,0)) + "\n")

# ---- images.lock.tsv (secret-free): running ref/id vs current :latest id -> drift ----
tagmap = {}
for ln in run(["docker","images","--format","{{.Repository}}:{{.Tag}}\t{{.ID}}"]).stdout.splitlines():
    if "\t" not in ln: continue
    ref, iid = ln.split("\t",1)
    tagmap.setdefault(ref.split(":")[0], []).append((ref, iid))
drift_rows = []
with open(LOCK,"w") as f:
    f.write("service\trunning_ref\trunning_id\tlatest_id\tdrift\n")
    for nm, s in services.items():
        rid = run(["docker","inspect",nm,"--format","{{.Image}}"]).stdout.strip()
        ref = s.get("image","")
        repo = ref.split("@")[0].split(":")[0] if "@" not in ref else ref.split("@")[0]
        latest_id = next((i for r,i in tagmap.get(repo,[]) if r.endswith(":latest")), "")
        flag = "DRIFT" if (latest_id and rid and latest_id != rid) else ""
        if flag: drift_rows.append((nm, rid, latest_id))
        f.write(f"{nm}\t{ref}\t{rid}\t{latest_id}\t{flag}\n")

# ---- stdout: SAFE summary only (no env values, no secret bytes) ----
print(f"  services captured: {len(services)}")
print("  names: " + ", ".join(sorted(services)))
print(f"  external volumes: {len(vol_set)}   external networks: {len(net_set)}")
if missing_binds:
    print(f"  [MISSING BIND SOURCES] {len(missing_binds)} path(s) the live stack mounts no longer exist on disk:")
    for nm, src in missing_binds: print(f"    {nm}: {src}")
else:
    print("  [BIND SOURCES] every bind-mount source the live stack uses is present on disk")
if drift_rows:
    print(f"  [IMAGE DRIFT] {len(drift_rows)} service(s) run an image id != current :latest (full table in images.lock.tsv):")
    for nm, rid, lid in drift_rows: print(f"    {nm}: running={rid[:19]}  latest={lid[:19]}")
print(f"  wrote: {OUT}   (secret-bearing -> gitignored)")
print(f"  wrote: {LOCK}  (secret-free -> committed)")
