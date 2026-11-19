# shellcheck shell=bash
# Entra ID sign-in services.
for unit in himmelblaud.service himmelblaud-tasks.service; do
  if systemctl is-active --quiet "${unit}"; then
    pass "${unit} is active"
  else
    fail "${unit} is $(systemctl is-active "${unit}")"
    systemctl status --no-pager --lines=30 "${unit}" || true
  fi
done