#!/usr/bin/env bash
# Chạy TRÊN TỪNG NODE production (air-gapped, không internet). Nạp tarball image vào
# container runtime của node đó (Docker, containerd qua nerdctl, hoặc containerd qua ctr).
# Kubernetes chạy pod ở node nào, node đó phải có sẵn image -> chạy script này trên CẢ 3 node.
#
# Usage: ./load-images.sh /path/to/fss-kafka-clickhouse-images.tar
set -euo pipefail

TAR="${1:?Usage: $0 <images-tar-path>}"
[ -f "$TAR" ] || { echo "Không tìm thấy file: $TAR" >&2; exit 1; }

if [ -f "$TAR.sha256" ]; then
  echo "== Kiểm tra checksum =="
  sha256sum -c "$TAR.sha256"
fi

if command -v docker >/dev/null 2>&1; then
  echo "== Nạp qua docker load =="
  docker load -i "$TAR"
elif command -v nerdctl >/dev/null 2>&1; then
  echo "== Nạp qua nerdctl (namespace k8s.io) =="
  nerdctl -n k8s.io load -i "$TAR"
elif command -v ctr >/dev/null 2>&1; then
  echo "== Nạp qua ctr (namespace k8s.io) =="
  ctr -n k8s.io images import "$TAR"
else
  echo "Không thấy docker/nerdctl/ctr trên node này — cài container runtime trước." >&2
  exit 1
fi

echo "Xong trên node $(hostname). Verify: xem scripts/offline/images.txt rồi \`crictl images\` / \`docker images\`."
