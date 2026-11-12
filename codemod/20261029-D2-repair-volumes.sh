#!/usr/bin/env bash
# 20261029-D2-repair-volumes.sh  —  ARCHIVED RECORD of the successful [W] repair.
# Effect: rename 14 collapsed '_data' binds -> unique per-service '<svc>_data[_k]'; repoint the dead
#   grafana provisioning bind -> runtime/grafana/provisioning; rebuild top-level volumes block.
# NOTE: the live [W] run ALSO appended two CORRECTION rows to codemod/INDEX.md; this archive OMITS that
#   append so replay does not double-write the ledger. The CORRECTION rows already exist in INDEX.md.
# REPLAY FROM CLEAN:  cp "$SRC" "$DST" ; bash 20261029-D1-augment-16.sh ; bash 20261029-D2-repair-volumes.sh
# DO NOT run against an already-repaired DST (would rename *_data -> *_data_data).
set -uo pipefail
A="$HOME/DevOps/aether"; LC="$A/legacy/compose"; RT="$LC/runtime"
DST="$LC/recovery-runtime.yml"; SRC="$LC/emergency-recovery.yml"
DEAD_GRAFANA="/home/dev/DevOps/aether/02_data_plane/compose/grafana/provisioning"
python3 - "$DST" "$RT" "$DEAD_GRAFANA" <<'PY'
import sys,os,re
dst,rt,deadg=sys.argv[1],sys.argv[2],sys.argv[3]
orig=open(dst).read().split('\n')
TL=re.compile(r'^"?([A-Za-z_]+)"?:\s*$')
def tlk(l):
    m=TL.match(l); return m.group(1) if m else None
tl=[(i,tlk(l)) for i,l in enumerate(orig) if tlk(l)]
if not any(k=='services' for _,k in tl):
    print("  [W] ABORT: no services block (B13)."); sys.exit(0)
regions={}; order=[]
for j,(i,k) in enumerate(tl):
    nxt=tl[j+1][0] if j+1<len(tl) else len(orig)
    regions[k]=orig[i:nxt]; order.append(k)
print(f"  [W] regions: {order}")
svc_re=re.compile(r'^  "?([A-Za-z0-9_.-]+)"?:\s*$')
sub_re=re.compile(r'^    "?([A-Za-z_]+)"?:\s*$')
item_re=re.compile(r'^(\s*- )"?([^"]*)"?\s*$')
cur_svc=None; cur_sub=None; in_svc=False
volcount={}; assigned=set(); warns=[]; renames=0; repoints=0
out=[]
for l in regions['services']:
    k=tlk(l)
    if k=='services': in_svc=True; cur_svc=None; cur_sub=None; out.append(l); continue
    if k: in_svc=False
    sm=svc_re.match(l)
    if sm: cur_svc=sm.group(1); cur_sub=None; out.append(l); continue
    sub=sub_re.match(l)
    if sub: cur_sub=sub.group(1); out.append(l); continue
    im=item_re.match(l)
    if im and cur_sub=='volumes' and cur_svc:
        pre,val=im.group(1),im.group(2)
        src,_,rest=val.partition(':')
        if src=='_data':
            n=volcount.get(cur_svc,0); volcount[cur_svc]=n+1
            name=f"{cur_svc}_data" if n==0 else f"{cur_svc}_data_{n}"
            assigned.add(name); renames+=1
            out.append(f'{pre}"{name}:{rest}"'); continue
        if src==deadg or src.startswith(deadg):
            out.append(f'{pre}"{rt}/grafana/provisioning:{rest}"'); repoints+=1; continue
        out.append(l); continue
    out.append(l)
regions['services']=out
assigned.add('prometheus_data')
newvol=['"volumes":']+[f'  "{n}":' for n in sorted(assigned)]
if 'volumes' in regions: regions['volumes']=newvol
else: order.append('volumes'); regions['volumes']=newvol
print(f"  [W] renamed {renames} '_data' bind(s) -> unique per-service volumes; repointed {repoints} dead grafana bind(s)")
print(f"  [W] declared volumes ({len(assigned)}): {', '.join(sorted(assigned))}")
if warns:
    for w in warns: print(f"    [WARN] {w}")
merged=[]
for k in order: merged+=regions[k]
while merged and merged[-1]=='': merged.pop()
open(dst,'w').write('\n'.join(merged)+'\n')
print(f"  [W] recovery-runtime.yml now {sum(1 for _ in open(dst))} lines")
PY
echo "=== [X] LOUD gate ==="
echo "  residual '_data:' (expect 0):"; grep -c '"_data:' "$DST"
echo "  residual '02_data_plane' (expect 0):"; grep -c '02_data_plane' "$DST"
echo "=== [V3] re-validate ==="
n_img=$(grep -c '"image":' "$DST"); echo "  service count (image-keys): $n_img  (expect 16)"
docker compose -f "$DST" config -q 2>/tmp/cfgerr && echo "  [compose] schema valid" \
  || { grep -qi 'Cannot connect to the Docker daemon' /tmp/cfgerr && echo "  [compose] DEFERRED" || { echo "  [compose ERR]"; head -n 12 /tmp/cfgerr; }; }
