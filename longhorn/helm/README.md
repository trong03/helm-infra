# Longhorn — storage nền cho Kafka/ClickHouse

Longhorn phải cài **trước** Kafka/ClickHouse — cả 2 chart đó dùng `storage.create: true`
để tự tạo StorageClass (`kafka-ssd`, `clickhouse-ssd`) trỏ `provisioner: driver.longhorn.io`.
Không có Longhorn chạy trước, PVC của Kafka/ClickHouse sẽ kẹt `Pending`.

## Cài đặt (online, có internet)

### 0. Chuẩn bị OS trên MỖI node (trước khi động tới k8s)
```bash
sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common cryptsetup
sudo systemctl enable --now iscsid

sudo modprobe nfs
sudo modprobe dm_crypt
echo -e "nfs\ndm_crypt" | sudo tee /etc/modules-load.d/longhorn.conf
sudo systemctl disable --now multipathd
sudo systemctl disable --now multipathd.socket
sudo systemctl mask multipathd.service multipathd.socket
```

### 1. Namespace + PSS + preflight
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest --overwrite

./longhornctl check preflight
```
`longhornctl` là binary riêng (không phải kubectl plugin), xem mục offline bên dưới để tải.

### 2. Cài Helm chart
```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.1 \
  --set persistence.defaultClassReplicaCount=2 \
  --set defaultSettings.defaultReplicaCount=2
```
`replicaCount=2`: dữ liệu Longhorn tự nhân bản 2 bản trên 2 node khác nhau — lớp HA riêng
của Longhorn, **độc lập** với RF=3 của Kafka hay `replicasCount` của ClickHouse (2 lớp
replication khác nhau, không thay thế nhau).

**Production offline (không internet):**
```bash
helm install longhorn charts-offline/longhorn-1.12.1/ \
  --namespace longhorn-system \
  --set persistence.defaultClassReplicaCount=2 \
  --set defaultSettings.defaultReplicaCount=2
```
(bỏ `--version` vì cài thẳng từ thư mục chart, không qua repo — xem
[../../OFFLINE-INSTALL.md](../../OFFLINE-INSTALL.md)).

## Kiểm tra
```bash
kubectl -n longhorn-system get pods -o wide          # manager 1/node (=2), csi-*, ui... Running
kubectl -n longhorn-system get ds longhorn-manager   # DESIRED=2 READY=2
kubectl get storageclass                             # 'longhorn' (default)
```

Test 1 PVC rồi xoá:
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lh-test, namespace: longhorn-system }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl -n longhorn-system get pvc lh-test    # Bound
kubectl -n longhorn-system delete pvc lh-test
```

## Bảo mật (fintech / NĐ 13/2023)
- Namespace `longhorn-system` dùng PSS **privileged** (bắt buộc — Longhorn cần quyền host-level
  cho iSCSI/mount), khác hẳn `restricted` của Kafka/ClickHouse. Không nới PSS ở namespace khác
  vì lý do này.
- `defaultReplicaCount=2` là dữ liệu volume, không phải business data mã hoá — nếu ổ đĩa chứa
  dữ liệu khách hàng thật, cân nhắc bật encryption ở StorageClass (`parameters.encrypted: "true"`
  + `csi.storage.k8s.io/node-publish-secret-name`) — chart này hiện CHƯA bật.
- Draft cần human review + qua CI/CD trước khi áp lên production, như mọi phần khác.
