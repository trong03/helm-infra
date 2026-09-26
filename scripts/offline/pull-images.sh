#!/usr/bin/env bash
# Chạy trên máy CÓ internet (bastion/dev), có Docker. Kéo toàn bộ image trong images.txt,
# đóng gói thành 1 tarball + sha256 để mang qua máy production air-gapped.
#
# Usage: ./pull-images.sh [output-dir]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$DIR/out}"
IMAGES_FILE="$DIR/images.txt"
TAR="$OUT/fss-k8s-images.tar"

command -v docker >/dev/null || { echo "Cần Docker để pull + save image." >&2; exit 1; }

mkdir -p "$OUT"
mapfile -t IMAGES < <(grep -vE '^\s*#|^\s*$' "$IMAGES_FILE")

echo "== Pulling ${#IMAGES[@]} image =="
for img in "${IMAGES[@]}"; do
  echo "-- $img"
  docker pull "$img"
done

echo "== Saving thành 1 tarball: $TAR =="
docker save -o "$TAR" "${IMAGES[@]}"

sha256sum "$TAR" > "$TAR.sha256"

echo
echo "Xong. Mang 2 file sau qua máy production (USB / file share nội bộ):"
echo "  $TAR"
echo "  $TAR.sha256"
echo "Kèm theo: longhorn/helm/charts-offline/, longhorn/bin/, kafka/helm/charts-offline/,"
echo "clickhouse/helm/charts-offline/, và toàn bộ repo (fss-kafka/, fss-clickhouse/ là"
echo "chart nội bộ, không cần tải)."
