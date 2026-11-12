# RUNBOOK
bootstrap: ./aetherctl bootstrap   (deps check + linger + certs + secrets skeleton)
deploy:    ./aetherctl deploy      (render quadlets -> systemd dir + daemon-reload + enable + verify-hash)
migrate:   ./aetherctl migrate <svc>  (snapshot -> stop compose twin -> start quadlet twin -> gate)
verify:    ./aetherctl verify      (repo hash == runtime hash, both directions)
doctor:    ./aetherctl doctor      (linger/podman/secrets-perms/ports/memory)
status:    ./aetherctl status      (list pilot units active/inactive)
snapshot:  ./aetherctl snapshot    (pg_dumpall + quadlet hashes + ps manifest -> backups/snapshots/)
backup:    restic DR unchanged during phase-1; --restore documented here after phase-2.
