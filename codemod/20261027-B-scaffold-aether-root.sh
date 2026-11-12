#!/usr/bin/env bash
# 20261027-B-scaffold-aether-root.sh — single-root rendered-state platform (ADR-0002), rev2
set -uo pipefail
OLD="$HOME/DevOps/aether"; NEW="${OLD}2"; ROOT="$OLD"; SLUG="20261027-B-scaffold-aether-root"
log(){ printf '[%s] %s\n' "$(date +%T)" "$*"; }
die(){ printf '[FAIL] %s\n' "$*" >&2; exit "${2:-1}"; }
log "=== [P0] dependency gate ==="
command -v podman >/dev/null 2>&1 || die "podman missing: sudo apt install -y podman" 3
Q=$(ls /usr/lib/systemd/system-generators/podman-user-generator /usr/libexec/podman/quadlet 2>/dev/null | head -n1)
[ -n "$Q" ] || die "quadlet generator missing (podman too old)" 3
log "  podman $(podman --version | awk '{print $NF}') + quadlet ($Q)"
log "=== [P1] external refs to old root ==="
REFS=$(grep -RIl "$OLD/" "$HOME/.config/systemd/user/" /etc/systemd/system/ "$HOME/.config/restic/" 2>/dev/null || true)
[ -n "$REFS" ] && { log "  refs (repoint after rename):"; printf '%s\n' "$REFS" | sed 's/^/    /'; } || log "  no external refs"
log "=== [P2] guarded rename ==="
[ -e "$NEW" ] && die "$NEW exists — abort (B13)" 1
[ -d "$OLD" ] || die "$OLD missing — abort" 1
mv "$OLD" "$NEW" && log "  mv aether -> aether2 (running stack intact)"
[ -n "$REFS" ] && { sed -i "s|$OLD/|$NEW/|g" $REFS; systemctl --user daemon-reload 2>/dev/null; log "  repointed refs"; }
log "=== [P3] tree ==="
mkdir -p "$ROOT"/{infra/quadlet,infra/certs,apps/n8n-workflows,apps/neo-cortex,codemod,data,backups/snapshots,legacy/compose,docs}
cp -r "$NEW/02_data_plane/compose/." "$ROOT/legacy/compose/" 2>/dev/null && log "  legacy/compose parked"
cat > "$ROOT/.gitignore" <<'EOF'
data/
backups/
infra/certs/
codemod/*.bak
*.env
!secrets.example.env
EOF
cat > "$ROOT/secrets.example.env" <<'EOF'
# TEMPLATE ONLY — real values: ~/.config/aether/secrets.env (0600, outside repo)
LITELLM_MASTER_KEY=
WEAVIATE_API_KEY=
N8N_ENCRYPTION_KEY=
ZITADEL_MASTERKEY=
POSTGRES_PASSWORD=
MINIO_ROOT_PASSWORD=
EOF
printf '[Network]\nNetworkName=aether\n' > "$ROOT/infra/quadlet/aether.network"
cat > "$ROOT/infra/render.list" <<'EOF'
infra/quadlet/aether.network .config/containers/systemd/aether.network
infra/quadlet/node-exporter.container .config/containers/systemd/node-exporter.container
infra/quadlet/prometheus.container .config/containers/systemd/prometheus.container
infra/quadlet/mailpit.container .config/containers/systemd/mailpit.container
EOF
cat > "$ROOT/docs/ADR-0002-single-root-rendered-state.md" <<'EOF'
# ADR-0002: single-root rendered-state platform
ONE git root; quadlet SOURCES in infra/quadlet; aetherctl COPIES to ~/.config/containers/systemd;
hash-convergence gate makes drift/missing loud. Copies (not symlinks) = relocation-safe.
Secrets outside repo; data in gitignored binds. Multi-line programs run FROM FILES, never pasted.
EOF
cat > "$ROOT/docs/ADR-0001-runtime-podman-quadlet.md" <<'EOF'
# ADR-0001: podman + quadlet on a 16GB edge node
systemd-supervised rootless OCI > always-on k3s (RAM) and > compose (no ceilings/boot order).
k3s = ON-DEMAND practice plane; compose = migration source only.
EOF
cat > "$ROOT/docs/RUNBOOK.md" <<'EOF'
# RUNBOOK
deploy:  ./aetherctl deploy   (render+reload+enable+verify; does NOT start)
migrate: ./aetherctl migrate <svc>  (snapshot -> stop compose twin -> start twin -> gate)
verify:  ./aetherctl verify   (repo hash == runtime hash)
doctor:  ./aetherctl doctor   (linger/podman/secrets-perms/ports)
EOF
: > "$ROOT/codemod/INDEX.md"
log "=== [P4] pilot quadlets FROM live inspect (rev2 fixes: Env partition + top-level HostConfig) ==="
python3 - <<'PY'
import json,subprocess,os
OLD=os.path.expanduser("~/DevOps/aether"); NEW=OLD+"2"; OUT=OLD+"/infra/quadlet"
for name in ("node-exporter","prometheus","mailpit"):
    d=json.loads(subprocess.run(["docker","inspect",name],capture_output=True,text=True).stdout)[0]
    c=d.get("Config") or {}; hb=d.get("HostConfig") or {}
    L=["[Container]", f"ContainerName={name}", f"Image={c.get('Image','')}", "Network=aether"]
    for e in (c.get("Env") or []):
        k,_,v=e.partition("=")
        if k in ("PATH","HOSTNAME"): continue
        L.append(f'Environment="{k}={v}"')
    for m in (d.get("Mounts") or []):
        if m.get("Type")!="bind": continue
        src=m["Source"].replace(OLD+"/",NEW+"/",1)
        ro=",ro" if not m.get("RW",True) else ""
        L.append(f"Volume={src}:{m['Destination']}{ro}")
    nb=0
    for cport,binds in (hb.get("PortBindings") or {}).items():
        cp=cport.split("/")[0]
        for b in (binds or []):
            hip=(b.get("HostIp") or "")
            L.append(f"PublishPort={hip+':' if hip else ''}{b['HostPort']}:{cp}"); nb+=1
    L+=["","[Service]","Restart=always",""]
    open(f"{OUT}/{name}.container","w").write("\n".join(L))
    print(f"  generated {name}.container image={c.get('Image','')} publishports={nb}")
PY
log "=== [P5] aetherctl ==="
cat > "$ROOT/aetherctl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; SYS="$HOME/.config/containers/systemd"
PILOT="node-exporter prometheus mailpit"
log(){ printf '[%s] %s\n' "$(date +%T)" "$*"; }
case "${1:-help}" in
doctor)
  echo "  linger=$(loginctl show-user "$USER" --property=Linger | cut -d= -f2)"
  echo "  podman=$(podman --version 2>/dev/null | awk '{print $NF}')"
  echo "  secrets=$(stat -c '%a' "$HOME/.config/aether/secrets.env" 2>/dev/null || echo '<absent: phase-0 pending>')"
  for p in 8025 9090 9100; do printf '  port %-5s %s\n' "$p" "$(ss -ltn 2>/dev/null | grep -q ":$p " && echo BUSY || echo free)"; done ;;
deploy)
  mkdir -p "$SYS"; n=0
  while read -r src dst; do [ -z "$src" ] && continue; install -D -m 644 "$ROOT/$src" "$HOME/$dst"; n=$((n+1)); done < "$ROOT/infra/render.list"
  systemctl --user daemon-reload
  while read -r src dst; do [ -z "$src" ] && continue; u=$(basename "$dst"); case "$u" in *.container) systemctl --user enable "${u%.container}.service" 2>/dev/null;; esac; done < "$ROOT/infra/render.list"
  log "  rendered $n files + reload + enabled (NOT started)"
  "$0" verify ;;
verify)
  fail=0
  while read -r src dst; do [ -z "$src" ] && continue
    a=$(sha256sum "$ROOT/$src" | cut -d' ' -f1); b=$(sha256sum "$HOME/$dst" 2>/dev/null | cut -d' ' -f1)
    [ "$a" = "$b" ] || { echo "  [DRIFT] $src != $dst"; fail=1; }; done < "$ROOT/infra/render.list"
  [ "$fail" = 0 ] && echo "  [VERIFY] hashes match repo==runtime" || exit 1 ;;
status) systemctl --user list-units --no-legend | grep -E 'node-exporter|prometheus|mailpit' | sed 's/^/  /' ;;
snapshot)
  S="$ROOT/backups/snapshots/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$S"
  docker exec postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$S/pg_dumpall.sql" 2>/dev/null \
    || podman exec aether-postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$S/pg_dumpall.sql" 2>/dev/null || echo "  [WARN] dump failed"
  sha256sum "$ROOT"/infra/quadlet/* > "$S/quadlet.sha"
  { docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null; podman ps --format '{{.Names}} {{.Image}}' 2>/dev/null; } > "$S/ps.manifest"
  log "  snapshot -> $S" ;;
migrate)
  svc="${2:-}"; case " $PILOT " in *" $svc "*) ;; *) echo "  [GATED] '$svc' not pilot ($PILOT)"; exit 2;; esac
  "$0" snapshot
  ( cd "$HOME/DevOps/aether2/02_data_plane/compose" && docker compose -f docker-compose.yml -f gitops.yml -f ai-gateway.yml -f portainer.yml stop "$svc" ) \
    || echo "  [WARN] compose stop failed (svc in another file?)"
  systemctl --user start "${svc}.service"
  for i in $(seq 1 15); do systemctl --user is-active --quiet "${svc}.service" && break; sleep 2; done
  systemctl --user is-active --quiet "${svc}.service" && log "  [MIGRATED] $svc active on quadlet" || { echo "  [FAIL] $svc not active"; exit 1; } ;;
*) echo "  usage: aetherctl deploy|verify|status|snapshot|migrate <svc>|doctor" ;;
esac
EOF
chmod +x "$ROOT/aetherctl"
log "=== [P6] git + ledger + self-archive ==="
( cd "$ROOT" && { git rev-parse --git-dir >/dev/null 2>&1 || git init -q; }
  git config user.email >/dev/null 2>&1 || git config user.email "dev@aether.home"
  git config user.name  >/dev/null 2>&1 || git config user.name  "aether-operator"
  git add -A && git commit -qm "scaffold: single-root rendered-state platform (ADR-0002)" )
grep -q "$SLUG" "$ROOT/codemod/INDEX.md" 2>/dev/null || echo "| $(date +%F) | B | $SLUG | podman=$(podman --version 2>/dev/null | awk '{print $NF}') gate=pending | rollback=see codemod header |" >> "$ROOT/codemod/INDEX.md"
install -D -m 755 "$0" "$ROOT/codemod/$SLUG.sh" 2>/dev/null && log "  self-archived -> codemod/$SLUG.sh"
log "=== SCAFFOLD COMPLETE ==="
