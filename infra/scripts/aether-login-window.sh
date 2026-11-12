#!/usr/bin/env bash
set -uo pipefail
case "${1:-status}" in
  open)
    sudo -v || exit 1
    sudo cp -p /etc/hosts "/etc/hosts.pre-login.$(date +%Y%m%d-%H%M%S).bak"
    grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts || echo "127.0.0.2 gitea" | sudo tee -a /etc/hosts >/dev/null
    echo "login window OPEN — browser: http://127.0.0.1:8000 -> Login with Gitea; run '$0 close' after login" ;;
  close)
    sudo -v || exit 1
    sudo sed -i '/^[^#]*[[:space:]]gitea\([[:space:]]\|$\)/d' /etc/hosts
    echo "login window CLOSED (hosts clean)" ;;
  status)
    grep -qE '[[:space:]]gitea([[:space:]]|$)' /etc/hosts && echo "OPEN" || echo "CLOSED" ;;
  *) echo "usage: $0 open|close|status"; exit 2 ;;
esac
