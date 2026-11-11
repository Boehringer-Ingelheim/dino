#!/usr/bin/env bash
# Pick the image to promote to `stable` (#93).
#
# Without SOURCE_TAG: the newest `latest-YYYYMMDD-<sha>` image built at least
# SOAK_DAYS ago that is signed and carries a passed smoke-test attestation.
# With SOURCE_TAG: exactly that image, regardless of its age (rollback to a
# previous `stable-*` image, or an urgent hotfix).
#
# Prints key=value lines (append them to $GITHUB_OUTPUT):
#   promote       true, or false if there is nothing to do (see reason)
#   reason        why nothing is promoted (only with promote=false)
#   digest        digest to promote
#   source_tag    tag the digest was found under
#   commit        full git commit the image was built from (may be empty)
#   smoke_test    passed | skipped (SKIP_SMOKE_CHECK) | previously-stable
#   current       digest `stable` points to now (empty if none)
#
# Env:
#   IMAGE             e.g. ghcr.io/boehringer-ingelheim/dino
#   COSIGN_KEY        public key file (default cosign.pub)
#   SOAK_DAYS         default 14
#   SOURCE_TAG        optional, see above
#   SKIP_SMOKE_CHECK  "true" to accept an image without smoke-test attestation
#   TODAY             testing only: reference date, default today (UTC)

set -euo pipefail

: "${IMAGE:?IMAGE is required}"
COSIGN_KEY="${COSIGN_KEY:-cosign.pub}"
SOAK_DAYS="${SOAK_DAYS:-14}"
SOURCE_TAG="${SOURCE_TAG:-}"
SKIP_SMOKE_CHECK="${SKIP_SMOKE_CHECK:-false}"
TODAY="${TODAY:-today}"
ATTESTATION_TYPE="https://github.com/boehringer-ingelheim/dino/smoke-test/v1"

log() { echo "$*" >&2; }

digest_of() {
  skopeo inspect --raw "docker://${IMAGE}:$1" | sha256sum | awk '{print "sha256:" $1}'
}

# Full commit of a tag's trailing short SHA (`...-<sha>`), if this clone knows it.
commit_from_tag() {
  local sha
  sha=$(sed -nE 's/.*-([0-9a-f]{7,40})$/\1/p' <<<"$1")
  [[ -n "${sha}" ]] || return 0
  git rev-parse --quiet --verify "${sha}^{commit}" 2>/dev/null || true
}

# Prints the commit recorded in the smoke-test attestation; fails without one.
smoke_test_commit() {
  local out
  out=$(cosign verify-attestation --key "${COSIGN_KEY}" --type "${ATTESTATION_TYPE}" \
    "${IMAGE}@$1" 2>/dev/null) || return 1
  jq -rs '[.[].payload | @base64d | fromjson | .predicate
           | select(.result == "passed") | .commit] | first // empty' <<<"${out}" |
    grep . || return 1
}

current=""
if current=$(digest_of stable 2>/dev/null); then :; else current=""; fi
echo "current=${current}"

# Candidate tags, newest first.
candidates=()
if [[ -n "${SOURCE_TAG}" ]]; then
  candidates=("${SOURCE_TAG}")
else
  cutoff=$(date -u -d "${TODAY} -${SOAK_DAYS} days" +%Y%m%d)
  log "Looking for latest-YYYYMMDD-<sha> images built on or before ${cutoff}."
  mapfile -t tagged < <(
    skopeo list-tags "docker://${IMAGE}" |
      jq -r '.Tags[]' |
      grep -E '^latest-[0-9]{8}-[0-9a-f]{7,40}$' |
      awk -F- -v cutoff="${cutoff}" '$2 <= cutoff'
  )
  # Same-day builds: order by the image's creation time.
  while IFS=$'\t' read -r _ tag; do
    [[ -n "${tag}" ]] && candidates+=("${tag}")
  done < <(
    for tag in "${tagged[@]}"; do
      created=$(skopeo inspect --format '{{.Created.Unix}}' "docker://${IMAGE}:${tag}" 2>/dev/null) ||
        continue
      printf '%s\t%s\n' "${created}" "${tag}"
    done | sort -rn
  )
fi

seen=" "
for tag in "${candidates[@]}"; do
  if ! digest=$(digest_of "${tag}" 2>/dev/null); then
    log "${tag}: not found"
    [[ -z "${SOURCE_TAG}" ]] && continue
    echo "promote=false"
    echo "reason=Tag ${SOURCE_TAG} does not exist."
    exit 1
  fi
  [[ "${seen}" == *" ${digest} "* ]] && continue
  seen+="${digest} "

  if ! cosign verify --key "${COSIGN_KEY}" "${IMAGE}@${digest}" >/dev/null 2>&1; then
    log "${tag} (${digest}): no valid signature, skipped"
    [[ -z "${SOURCE_TAG}" ]] && continue
    echo "promote=false"
    echo "reason=${SOURCE_TAG} has no valid signature."
    exit 1
  fi

  commit=""
  if commit=$(smoke_test_commit "${digest}"); then
    smoke_test=passed
  elif [[ "${SKIP_SMOKE_CHECK}" == "true" ]]; then
    smoke_test=skipped
  elif [[ -n "${SOURCE_TAG}" && "${SOURCE_TAG}" == stable* ]]; then
    # Rollback to an image that already was stable; older ones predate #111.
    smoke_test=previously-stable
  else
    log "${tag} (${digest}): no passed smoke test, skipped"
    [[ -z "${SOURCE_TAG}" ]] && continue
    echo "promote=false"
    echo "reason=${SOURCE_TAG} has no passed smoke test (set skip_smoke_check to override)."
    exit 1
  fi
  [[ -n "${commit}" ]] || commit=$(commit_from_tag "${tag}")

  log "Picked ${tag} (${digest}), smoke test: ${smoke_test}, commit: ${commit:-unknown}"
  echo "digest=${digest}"
  echo "source_tag=${tag}"
  echo "commit=${commit}"
  echo "smoke_test=${smoke_test}"
  if [[ "${digest}" == "${current}" ]]; then
    echo "promote=false"
    echo "reason=${tag} (${digest}) already is stable."
  else
    echo "promote=true"
  fi
  exit 0
done

echo "promote=false"
echo "reason=No latest image at least ${SOAK_DAYS} days old with a valid signature and a passed smoke test."
