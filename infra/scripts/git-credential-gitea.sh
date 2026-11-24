#!/usr/bin/env bash
# git credential helper for the local Gitea host. Reads secrets at call time; stores nothing.
[ "${1:-}" = get ] || exit 0
S="$HOME/DevOps/aether/secrets"
[ -f "$S/gitea-admin.user" ] && [ -f "$S/gitea-admin.pass" ] || exit 1
printf 'username=%s\n' "$(tr -d '\r\n' < "$S/gitea-admin.user")"
printf 'password=%s\n' "$(tr -d '\r\n' < "$S/gitea-admin.pass")"
