#!/usr/bin/env bash
# aether-gui-watchdog.sh start|stop|status  (CM: fixed self-kill + single instance)
# Clean quit (rc=0) -> stay closed. Crash (rc!=0) -> restart in 3s.
# Do NOT pkill -f 'aether-gui-watchdog' here; that matches this script itself.
PY=/home/dev/DevOps/.venv/bin/python
APP=/home/dev/DevOps/apps/podman/Podman.py
LOG=/tmp/aether-podman-gui.log
PIDF=/tmp/aether-gui-watchdog.pid
DIS=/tmp/aether-gui-watchdog.disabled

hard_kill(){
  if [ -f "$PIDF" ]; then
    kill -9 "$(cat "$PIDF")" 2>/dev/null || true
  fi
  pkill -9 -f 'Podman\.py' 2>/dev/null || true
  # Matches only the detached watchdog loop because it contains this literal path.
  # Does NOT match this script filename aether-gui-watchdog.sh.
  pkill -9 -f '/tmp/aether-gui-watchdog\.pid' 2>/dev/null || true
  rm -f "$PIDF"
}

case "${1:-status}" in
  start)
    hard_kill
    sleep 1
    rm -f "$DIS"

    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
      echo "watchdog already running (pid $(cat "$PIDF"))"
      exit 0
    fi

    setsid nohup bash -c '
      PY=/home/dev/DevOps/.venv/bin/python
      APP=/home/dev/DevOps/apps/podman/Podman.py
      LOG=/tmp/aether-podman-gui.log
      PIDF=/tmp/aether-gui-watchdog.pid
      DIS=/tmp/aether-gui-watchdog.disabled

      echo $$ > "$PIDF"

      while true; do
        if [ -f "$DIS" ]; then
          rm -f "$PIDF"
          exit 0
        fi

        "$PY" "$APP" >>"$LOG" 2>&1
        rc=$?

        if [ "$rc" -eq 0 ]; then
          echo "[watchdog] clean exit (rc=0) at $(date -u +%FT%TZ); user closed -> staying closed" >>"$LOG"
          rm -f "$PIDF"
          exit 0
        fi

        if [ -f "$DIS" ]; then
          rm -f "$PIDF"
          exit 0
        fi

        echo "[watchdog] crash rc=$rc at $(date -u +%FT%TZ); restarting in 3s" >>"$LOG"
        sleep 3
      done
    ' >/dev/null 2>&1 </dev/null &

    sleep 1
    echo "watchdog started detached (pid $(cat "$PIDF" 2>/dev/null || echo '?')); single-instance; clean-quit will NOT reopen"
    ;;

  stop)
    touch "$DIS"
    hard_kill
    sleep 1
    echo "watchdog + ALL GUI instances stopped (disabled sentinel set; run 'start' to re-enable)"
    ;;

  status)
    cnt="$(pgrep -c -f 'Podman\.py' 2>/dev/null || true)"
    case "$cnt" in
      ''|*[!0-9]*) cnt=0 ;;
    esac
    echo "  Podman.py procs: $cnt"
    pgrep -af 'Podman\.py' 2>/dev/null | sed 's/^/    /' || true

    if [ -f "$PIDF" ]; then
      echo "  watchdog pid $(cat "$PIDF")"
    else
      echo "  watchdog not running"
    fi

    if [ -f "$DIS" ]; then
      echo "  disabled sentinel: PRESENT (auto-restart off)"
    else
      echo "  disabled sentinel: absent (auto-restart on crash)"
    fi
    ;;
esac
