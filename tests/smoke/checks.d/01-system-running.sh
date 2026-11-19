# shellcheck shell=bash
# Boot finished without unexpected failed units.
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