
## Login window helper (EX54b)
- infra/scripts/aether-login-window.sh open|close|status
- open: temporary hosts entry (backup taken) -> browser login at :8000 -> close immediately after
- session expiry 720h (woodpecker.env) reduces re-login frequency
- Never leave the window open: hosts entry leaks into Podman containers and breaks step DNS
## Contribution graphs — corrected (EX54b)
- Gitea heatmap credits the PUSHER (action table): push authenticated as adminX to credit adminX;
  bot-authenticated CI pushes credit the bot regardless of commit author email.
- GitHub credits verified AUTHOR email: add+verify z4xebot1@gmail.com at github.com/settings/emails (one-time, manual).
