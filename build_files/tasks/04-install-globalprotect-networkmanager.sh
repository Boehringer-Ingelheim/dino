#!/usr/bin/bash

set -ouex pipefail

# Install the GlobalProtect VPN service and KDE Plasma 6 NetworkManager editor.
dnf5 install -y network-manager-gpclient network-manager-gpclient-plasma