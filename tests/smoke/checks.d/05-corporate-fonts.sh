# shellcheck shell=bash
# Corporate fonts are installed in /usr and visible to fontconfig.
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