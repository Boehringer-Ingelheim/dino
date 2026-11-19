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

check_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checks.d"
check_scripts=("${check_dir}"/[0-9]*.sh)
if [[ ! -f "${check_scripts[0]}" ]]; then
  echo "No smoke checks found in ${check_dir}." >&2
  exit 1
fi

for check_script in "${check_scripts[@]}"; do
  echo "[RUNNING] $(basename "${check_script}")"
  # shellcheck disable=SC1090
  source "${check_script}"
done

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
