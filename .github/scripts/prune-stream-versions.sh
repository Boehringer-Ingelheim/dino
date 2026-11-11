#!/usr/bin/env bash
# Prune old latest-*/stable-* image versions from GHCR, by age.
#
# A version is deleted only if ALL of these hold:
#   - it carries at least one latest* or stable* tag (feat-*/fix-* are handled
#     by the ephemeral-branch job, untagged versions by the untagged job)
#   - it is older than RETENTION_DAYS
#   - it does not carry the floating `latest` or `stable` tag
#   - it is not among the MIN_KEEP newest versions of any stream it belongs to
#     (a promoted image carries both latest-* and stable-* tags)
# The cosign signature and attestation versions (tags sha256-<digest>.sig and
# .att) of each deleted image are deleted with it, so they don't pile up as
# orphans.
#
# RETENTION_DAYS must stay above the stable promotion soak time (#93), so the
# promotion candidate is never pruned before it can be promoted.
#
# Env:
#   ORG, PACKAGE       GHCR owner and package name (lower case)
#   RETENTION_DAYS     default 28
#   MIN_KEEP           default 2
#   DRY_RUN            "true" to only print what would be deleted
#   VERSIONS_FILE      testing only: read the versions JSON array from a file
#                      instead of the GitHub API
#   NOW                testing only: reference time (ISO 8601), default now

set -euo pipefail

: "${ORG:?ORG is required}" "${PACKAGE:?PACKAGE is required}"
RETENTION_DAYS="${RETENTION_DAYS:-28}"
MIN_KEEP="${MIN_KEEP:-2}"
DRY_RUN="${DRY_RUN:-false}"
VERSIONS_FILE="${VERSIONS_FILE:-}"
NOW="${NOW:-now}"

api_path="/orgs/${ORG}/packages/container/${PACKAGE}/versions"

if [[ -n "${VERSIONS_FILE}" ]]; then
  versions=$(jq -c '.' "${VERSIONS_FILE}")
else
  versions=$(gh api --paginate --slurp "${api_path}?per_page=100" | jq -c 'add // []')
fi

cutoff=$(date -u -d "${NOW} -${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

to_delete=$(jq -c --arg cutoff "${cutoff}" --argjson min "${MIN_KEEP}" '
  def tags: [.metadata.container.tags[]?];
  def streams: [tags[] | capture("^(?<s>latest|stable)(-|$)").s] | unique;

  . as $all
  | [$all[] | select((streams | length) > 0)] as $stream_versions

  # The MIN_KEEP newest versions of each stream are always kept.
  | ([["latest", "stable"][] as $s
       | [$stream_versions[] | select(streams | any(. == $s))]
       | sort_by(.created_at) | reverse | .[:$min][] | .id]) as $keep_newest

  | [$stream_versions[]
      | select(.created_at < $cutoff)
      | select(tags | any(. == "latest" or . == "stable") | not)
      | select(.id as $id | $keep_newest | any(. == $id) | not)]
    as $images

  # Attach the signature and attestation version(s) of each image, so they are
  # deleted together.
  | $images
  | map((.name | sub("^sha256:"; "sha256-")) as $prefix
      | [$prefix + ".sig", $prefix + ".att"] as $sig_tags
      | {id, created_at, tags: (tags | join(",")),
         sig_ids: ([$all[] | select(tags | any(. as $t | $sig_tags | index($t))) | .id] | join(","))})
' <<<"${versions}")

count=$(jq 'length' <<<"${to_delete}")
echo "Retention: ${RETENTION_DAYS} days (cutoff ${cutoff}), keeping the ${MIN_KEEP} newest per stream."
echo "${count} image version(s) to delete."

delete_version() {
  gh api -X DELETE "${api_path}/$1" >/dev/null
}

failed=0
while IFS=$'\t' read -r id created tags sig_ids; do
  [[ -n "${id}" ]] || continue
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] would delete ${id} (${created}): ${tags}${sig_ids:+ + signature ${sig_ids}}"
    continue
  fi
  if ! delete_version "${id}"; then
    # GHCR refuses some deletes (e.g. heavily downloaded public versions).
    # Report it, keep its signature so the image stays verifiable, and go on.
    echo "::warning::Could not delete version ${id} (${tags}); keeping its signature."
    failed=$((failed + 1))
    continue
  fi
  echo "Deleted ${id} (${created}): ${tags}"
  # Only remove the signature once its image is gone.
  for sig in ${sig_ids//,/ }; do
    if delete_version "${sig}"; then
      echo "  Deleted signature ${sig}"
    else
      echo "::warning::Could not delete signature version ${sig} of ${id}"
      failed=$((failed + 1))
    fi
  done
done < <(jq -r '.[] | [.id, .created_at, .tags, .sig_ids] | @tsv' <<<"${to_delete}")

if [[ "${failed}" -gt 0 ]]; then
  echo "::warning::${failed} version(s) could not be deleted."
fi
