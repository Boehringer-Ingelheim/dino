#!/usr/bin/env bash
# Smoke-test checks. Runs INSIDE the booted test VM as the unprivileged
# `smoke` user (member of wheel, so it can read the system journal).
# Started by run.sh over SSH; it prepends these variables:
#   ALLOWED_FAILED_UNITS  newline-separated units that may be failed
#   POLICY_REF            image reference that must have a signature policy

set -uo pipefail

ALLOWED_FAILED_UNITS="${ALLOWED_FAILED_UNITS:-}"
POLICY_REF="${POLICY_REF:-}"

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# 1. Boot finished without unexpected failed units.
state=$(timeout 600 systemctl is-system-running --wait 2>/dev/null)
case "${state}" in
  running)
    pass "system is running"
    ;;
  degraded)
    unexpected=()
    while read -r unit _; do
      [[ -n "${unit}" ]] || continue
      if grep -qxF "${unit}" <<<"${ALLOWED_FAILED_UNITS}"; then
        echo "INFO: ${unit} failed (allow-listed)"
      else
        unexpected+=("${unit}")
      fi
    done < <(systemctl list-units --failed --plain --no-legend)
    if [[ ${#unexpected[@]} -eq 0 ]]; then
      pass "system is degraded, but only by allow-listed units"
    else
      fail "unexpected failed units: ${unexpected[*]}"
      for unit in "${unexpected[@]}"; do
        systemctl status --no-pager --lines=30 "${unit}" || true
      done
    fi
    ;;
  *)
    fail "system state is '${state:-unknown}' (expected running or degraded)"
    systemctl list-jobs --no-pager || true
    ;;
esac

# 2. Entra ID sign-in services.
for unit in himmelblaud.service himmelblaud-tasks.service; do
  if systemctl is-active --quiet "${unit}"; then
    pass "${unit} is active"
  else
    fail "${unit} is $(systemctl is-active "${unit}")"
    systemctl status --no-pager --lines=30 "${unit}" || true
  fi
done

# 3. GDM is the display manager and its greeter session came up.
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

# 4. Corporate fonts are installed in /usr and visible to fontconfig.
# Capture first: `fc-list | grep -q` fails under pipefail when grep exits
# early and fc-list gets SIGPIPE.
families=$(fc-list : family)
for family in "Boehringer Forward Head" "Boehringer Forward Text"; do
  if grep -qF "${family}" <<<"${families}"; then
    pass "font family '${family}' is installed"
  else
    fail "font family '${family}' is missing"
  fi
done

# 5. Image signature policy: an entry for our image, and every key file exists.
policy=/etc/containers/policy.json
if [[ -n "${POLICY_REF}" ]] &&
  jq -e --arg ref "${POLICY_REF}" \
    '.transports.docker[$ref] | any(.[]; .type == "sigstoreSigned")' \
    "${policy}" >/dev/null; then
  pass "${policy} requires signatures for ${POLICY_REF}"
else
  fail "${policy} has no sigstoreSigned entry for '${POLICY_REF}'"
fi

mapfile -t keys < <(jq -r '.. | objects | (.keyPath // empty), (.keyPaths // [] | .[])' "${policy}" | sort -u)
if [[ ${#keys[@]} -eq 0 ]]; then
  fail "${policy} references no key files"
fi
for key in "${keys[@]}"; do
  if [[ -s "${key}" ]]; then
    pass "signature key ${key} exists"
  else
    fail "signature key ${key} is missing or empty"
  fi
done

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
