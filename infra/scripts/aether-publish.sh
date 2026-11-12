#!/usr/bin/env bash
# re-runnable curated publish entrypoint (EX54b); delegates to gated EX53e
set -uo pipefail
exec bash "$HOME/DevOps/aether/codemod/20261112-EX53e-union-blocklist-monotonic-gated-publish.sh" run
