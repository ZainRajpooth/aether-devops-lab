#!/usr/bin/env bash
# Replay/verify for AS: reruns the idempotent port-owner-aware promoter/verifier.
set -uo pipefail
exec bash "/home/dev/DevOps/aether/codemod/20261029-AS-port-owner-aware-llama-promote.sh"
