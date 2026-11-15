# aether-devops-lab

Single-node, zero-budget DevOps platform lab. Rootless Podman supervised by systemd quadlets,
a private forge, a gated CI pipeline, and encrypted off-box backups. Every public commit here
passed a secret scan before it left the private forge.

![CI](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/ZainRajpooth/aether-devops-lab/main/badges/ci.json)
![License](https://img.shields.io/badge/license-MIT-blue)
![Runtime](https://img.shields.io/badge/runtime-rootless%20Podman-892CA0)
![Supervisor](https://img.shields.io/badge/supervisor-systemd%20quadlets-1f1f1f)
![Backups](https://img.shields.io/badge/backups-restic%20to%20MinIO-00A98F)
![Secrets](https://img.shields.io/badge/secrets-gitleaks%20gated-critical)

## 1. Design position

No Kubernetes. No Docker. One host, one supervisor, one source of truth. The claim is not
"I can install a control plane" but "I can right-size a platform to its constraints and prove
every property with a gate."

| Constraint | Consequence |
|---|---|
| One host, 16 GiB RAM, 240 GB SSD | No control plane; systemd is the only supervisor |
| Zero spend | Free and open-source components only |
| Solo maintainer | Every operation is a re-runnable, idempotent script |
| Public portfolio, private secrets | Curated allowlist plus secret scan before publish |

## 2. Architecture

    +------------------------------------------------------------------------------+
    |  HOST   Kubuntu  ·  HP EliteBook 8470p  ·  i5 @ 2.8 GHz  ·  16 GiB  ·  240 GB   |
    |  rootless Podman  +  systemd --user quadlets      (no Docker, no Kubernetes)   |
    +------------------------------------------------------------------------------+
                                         |
                      network "aether"  ·  bridge 10.89.0.0/24
                      DNS aardvark  ·  <name>.dns.podman  (hosts-immune)
                                         |
      +----------+---------------+---------------+----------------+----------------+
      |   EDGE   |  FORGE / CI   |     DATA      |  OBSERVABILITY |   APP / AI     |
      +----------+---------------+---------------+----------------+----------------+
      | traefik  | gitea   :3001 | postgres :5432| prometheus     | n8n     :5678  |
      |  :8888   | woodpecker-   | redis   :6379 |  :9090         | litellm :4000  |
      |          |  server :8000 | minio   :9010 | grafana :3000  | llama-embed    |
      |          | woodpecker-   | weaviate      | node-exporter  |  :8081         |
      |          |  agent        |  :8080        |  :9100         | mailpit        |
      |          |               |               |                |  :1025/:8025   |
      |          |               |               |                | zitadel (IdP)  |
      +----------+---------------+---------------+----------------+----------------+
                                         |
                        systemd --user timers (backup, prune)
                                         |
                              restic  --->  MinIO bucket (encrypted)

### Publish pipeline (private to public, fail-closed)

    commit --> Gitea (private) --webhook--> Woodpecker --> agent (rootless Podman)
                                                                |
                                              step 1  curate-scan
                                                build allowlist, apply union blocklist,
                                                gitleaks scan (pinned) -- ABORT on finding
                                                                |
                                              step 2  publish
                                                clone public repo, sync curated tree,
                                                write CI badge state, commit + push
                                                                |
                                                                v
                                         GitHub  ZainRajpooth/aether-devops-lab

## 3. Security posture

1. Nothing secret is committed. Credentials live in a git-ignored directory excluded from publish.
2. Fail-closed publish: the publish step never runs after a failed scan.
3. Union blocklist, never shrinking: a file that ever produced a finding stays excluded.
4. Private key material is excluded from the public tree and tracked as remediation debt.
5. Split-horizon DNS: the browser uses a loopback bridge; containers use the hosts-immune
   dns.podman wildcard name, so host resolution can never poison container resolution.

## 4. Backups

restic to MinIO, encrypted at rest. Per-run backups are append-only; retention is a separate
weekly transaction, so intra-day restore points survive. Every run is gated on a new snapshot
identifier appearing, not on a snapshot count.

## 5. Layout

    docs/      runbooks, ADRs, generated decision index, remediation debt
    infra/     scripts, unit definitions, publish allowlist and blocklist
    codemod/   gated idempotent patch programs, one file per change, with an index

## 6. Operating model

Every change ships as a codemod: a self-contained script with a check mode that mutates nothing,
a run mode that is idempotent, explicit gates, and a documented rollback. Nothing is applied by
hand, so the platform is reproducible by a maintainer who has never seen it.

## 7. Decisions

Generated index: [docs/adr-index.md](docs/adr-index.md).

## 8. Licence

MIT.
