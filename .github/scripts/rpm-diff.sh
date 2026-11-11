#!/usr/bin/env bash
# Markdown table of RPM package changes between two images.
#
# Usage: rpm-diff.sh <old-image-ref> <new-image-ref>
# The old ref may be empty (first release): then only the package count is printed.

set -euo pipefail

old_ref="$1"
new_ref="$2"

packages() {
  podman run --rm --pull=always --entrypoint rpm "$1" \
    -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n' |
    grep -v '^gpg-pubkey' | sort -u -t $'\t' -k1,1
}

new=$(packages "${new_ref}")
if [[ -z "${old_ref}" ]]; then
  echo "First stable release: $(wc -l <<<"${new}") packages."
  exit 0
fi
old=$(packages "${old_ref}")

changes=$(join -t $'\t' -a1 -a2 -e '' -o 0,1.2,2.2 <(echo "${old}") <(echo "${new}") |
  awk -F'\t' '$2 != $3 {
    if ($2 == "") print "| " $1 " | | " $3 " |";
    else if ($3 == "") print "| " $1 " | " $2 " | removed |";
    else print "| " $1 " | " $2 " | " $3 " |";
  }')

if [[ -z "${changes}" ]]; then
  echo "No package changes."
  exit 0
fi
echo "$(wc -l <<<"${changes}") package(s) changed:"
echo
echo "| Package | Before | After |"
echo "| --- | --- | --- |"
echo "${changes}"
