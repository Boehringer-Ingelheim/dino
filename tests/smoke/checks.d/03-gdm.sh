# shellcheck shell=bash
# GDM is the display manager and its greeter session came up.
dm=$(systemctl show --property=Id --value display-manager.service)
if [[ "${dm}" == "gdm.service" ]] && systemctl is-active --quiet gdm.service; then
  pass "gdm.service is the active display manager"
else
  fail "display manager is '${dm}' ($(systemctl is-active display-manager.service))"
fi

greeter=false
for _ in $(seq 1 30); do
  sessions=$(loginctl list-sessions --json=short 2>/dev/null)
  if jq -e 'any(.[]; .class == "greeter")' >/dev/null 2>&1 <<<"${sessions}"; then
    greeter=true
    break
  fi
  sleep 2
done
if [[ "${greeter}" == true ]]; then
  pass "GDM greeter session is running"
else
  fail "no greeter session after 60 seconds"
  loginctl list-sessions --no-pager || true
  journalctl --boot --no-pager --lines=50 --unit=gdm.service || true
fi