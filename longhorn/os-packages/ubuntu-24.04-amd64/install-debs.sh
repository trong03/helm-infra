#!/usr/bin/env bash
# Chạy TRÊN TỪNG NODE Ubuntu 24.04 production (air-gapped). Cài open-iscsi + nfs-common +
# cryptsetup (và toàn bộ dependency đã tải kèm sẵn), không cần apt repo / internet.
#
# Usage: sudo ./install-debs.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Kiểm tra checksum =="
(cd "$DIR" && sha256sum -c SHA256SUMS)

echo "== Cài toàn bộ .deb (dpkg tự tính thứ tự dependency) =="
dpkg -i "$DIR"/*.deb

echo "== Bật iscsid =="
systemctl enable --now iscsid

echo "Xong. Tiếp tục các bước module/multipathd trong longhorn/helm/README.md."
