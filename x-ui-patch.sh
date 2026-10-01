#!/bin/bash
#################### 3x-ui-pro patch #############################
#
# Re-applies the current 3x-ui-pro layout to an already-installed server:
# nginx SNI router, all inbounds, the eternal client, hosts, WARP egress,
# cover site and diagnostics. Existing ports/paths/domains are read from
# /etc/x-ui/3x-ui-pro/install.env so inbounds and subscription URLs stay put.
#
# The heavy lifting lives in x-ui-latest.sh (-patch y); this file is only a
# bootstrapper so `bash <(curl .../x-ui-patch.sh)` keeps working.
#
# WARNING: educational purposes only. Use only on servers you own and comply
# with the laws of your country. Provided "as is", without warranty — see
# DISCLAIMER.md in the repository.
#
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

RAW="${XUI_PRO_RAW:-https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main}"

echo "Applying current 3x-ui-pro features to the existing installation..."
exec bash <(curl -fsSL "${RAW}/x-ui-latest.sh") -patch y "$@"
