# ADR-0009: declarative operations without Kubernetes

- Status: accepted
- Date: 2026-11-15

## Context

The lab runs on one HP EliteBook 8470p (i5, 16 GiB RAM, 240 GB SSD) under Kubuntu.
All workloads are rootless Podman containers supervised by systemd user quadlets.
A Kubernetes brick (k3d single node plus Flux controllers) was drafted to provide GitOps.

## Decision

Do not introduce Kubernetes. Obtain the same GitOps properties from the existing substrate:
declarative state in quadlet units, source of truth in a private Gitea repository,
reconciliation by systemd timers, image drift correction by podman-auto-update with pinned
tags, discovery by netavark plus aardvark DNS, readiness by in-network HTTP probes.

## Rationale

1. Resource cost: a k3d server plus Flux controllers reserves roughly 0.8 GiB for a control
   plane supervising workloads already supervised by systemd. Zero marginal capability.
2. Operational surface: kubelet alongside systemd creates two sources of truth for process
   lifecycle, doubling failure modes during boot and upgrade.
3. Constraint fit: the operating model is rootless Podman plus quadlets; a control plane
   contradicts the documented model.
4. Honesty of signal: a single-node cluster shows tool familiarity, not distributed-systems
   competence. Right-sizing the substrate is the stronger engineering statement.

## Consequences

- No extra RAM footprint, one supervisor, reproducible from Git plus systemd.
- Reconciliation is timer-driven, so convergence is bounded by the timer interval.
- No Kubernetes vocabulary here. If that signal is needed it belongs in a separate,
  clearly labelled experiment repository, never silently merged into this lane.
