#!/usr/bin/bash

set -ouex pipefail

### Install packages

# Microsoft Edge key import, repo already in system_files/etc/yum.repos.d/microsoft.repo (gpgcheck=1)
rpm --import https://packages.microsoft.com/keys/microsoft.asc

# this installs edge and onedrive
dnf5 install -y microsoft-edge-stable --setopt=tsflags=noscripts
dnf5 install -y onedrive

required_onedrive_version=2.5.12
installed_onedrive_version=$(rpm -q --qf '%{VERSION}' onedrive)
if [[ "$(printf '%s\n' "$required_onedrive_version" "$installed_onedrive_version" | sort -V | head -n1)" != "$required_onedrive_version" ]]; then
  echo "Fedora's OneDrive RPM is ${installed_onedrive_version}; Intune SSO requires ${required_onedrive_version} or newer for reliable broker activation" >&2
  exit 1
fi

systemctl --global preset onedrive.service

# Commented for now, let's see who uncoments this back
# fc-cache -fv

# edge as default browser
mkdir -p /etc/xdg

cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=microsoft-edge.desktop
x-scheme-handler/https=microsoft-edge.desktop
text/html=microsoft-edge.desktop
EOF

# Manually run post-install tasks since tsflags=noscripts disables scripts
# Install icons
for icon in product_logo_16.png product_logo_24.png product_logo_32.png product_logo_48.png product_logo_64.png product_logo_128.png product_logo_256.png; do
  size="$(echo ${icon} | sed 's/[^0-9]//g')"
  xdg-icon-resource install --size "${size}" "/opt/microsoft/msedge/${icon}" "microsoft-edge" || true
done

# Update desktop database
update-desktop-database > /dev/null 2>&1 || true
