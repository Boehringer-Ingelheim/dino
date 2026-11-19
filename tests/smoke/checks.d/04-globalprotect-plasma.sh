# shellcheck shell=bash
# The Plasma package requires and pulls in the GlobalProtect VPN core package.
package=network-manager-gpclient-plasma
if rpm -q "${package}" >/dev/null 2>&1; then
  pass "${package} is installed"
else
  fail "${package} is not installed"
fi