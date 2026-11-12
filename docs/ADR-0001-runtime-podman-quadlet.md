# ADR-0001: podman + quadlet on a 16GB edge node
systemd-supervised rootless OCI beats always-on k3s (RAM) and beats compose (no enforced ceilings,
no boot ordering). k3s retained as ON-DEMAND practice plane. Compose retained only as migration source.
