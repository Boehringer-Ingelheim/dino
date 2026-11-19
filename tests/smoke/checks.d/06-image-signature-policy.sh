# shellcheck shell=bash
# Image signature policy: an entry for our image, and its key files exist.
policy=/etc/containers/policy.json
if [[ -n "${POLICY_REF}" ]] &&
  jq -e --arg ref "${POLICY_REF}" \
    '.transports.docker[$ref] | any(.[]; .type == "sigstoreSigned")' \
    "${policy}" >/dev/null; then
  pass "${policy} requires signatures for ${POLICY_REF}"
else
  fail "${policy} has no sigstoreSigned entry for '${POLICY_REF}'"
fi

mapfile -t keys < <(jq -r --arg ref "${POLICY_REF}" \
  '.transports.docker[$ref][]? | (.keyPath // empty), (.keyPaths // [] | .[])' \
  "${policy}" | sort -u)
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