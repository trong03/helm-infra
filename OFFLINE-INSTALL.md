# Cài đặt offline (production không internet) — Longhorn + Kafka + ClickHouse

Production `D:\k8-infra\longhorn`, `kafka`, `clickhouse` không có internet. Mọi thứ Helm/K8s cần
tải đều phải **chuẩn bị trước trên máy có internet**, rồi mang qua (USB / file share nội bộ).
Runbook cài đặt chi tiết (thứ tự lệnh, HA, security) vẫn ở từng `*/helm/README.md` — file này chỉ
nói **lấy tài nguyên ở đâu** và **đưa vào máy offline thế nào**.

**Thứ tự cài bắt buộc: Longhorn trước, rồi mới Kafka/ClickHouse** — cả 2 chart sau dùng
`storage.create: true` tạo StorageClass trỏ `provisioner: driver.longhorn.io`, không có Longhorn
chạy trước thì PVC kẹt `Pending`.

## Cần mang theo 4 nhóm tài nguyên

| Nhóm | Gồm gì | Đã có sẵn trong repo? |
|---|---|---|
| 1. Toàn bộ repo | `longhorn/`, `kafka/`, `clickhouse/` (chart nội bộ `fss-kafka`, `fss-clickhouse` không cần tải, chỉ cần copy) | Có — clone/copy cả `D:\k8-infra` |
| 2. Helm chart / manifest / binary bên thứ 3 | chart trần (chưa nén) trong `charts-offline/` + manifest operator ClickHouse + binary `longhornctl` | Có — xem bảng dưới |
| 3. Container image | 20 image, đóng gói qua `scripts/offline/pull-images.sh` | Có — đã pull sẵn, xem `scripts/offline/out/` |
| 4. Gói OS cho từng node (`open-iscsi`, `nfs-common`, `cryptsetup` + dependency) | Longhorn cần cài trên **mỗi node** trước khi deploy | Có — `longhorn/os-packages/ubuntu-24.04-amd64/` (105 file `.deb`, 39MB) |

### Nhóm 2 — Helm chart / manifest / binary đã tải sẵn trong repo
| File | Dùng cho |
|---|---|
| `longhorn/helm/charts-offline/longhorn-1.12.1/` | release `longhorn` (storage nền) |
| `longhorn/bin/longhornctl-linux-amd64` (+ `.sha256`) | lệnh `./longhornctl check preflight` trước khi cài |
| `kafka/helm/charts-offline/strimzi-kafka-operator-1.2.0/` | release `strimzi-operator` |
| `kafka/helm/charts-offline/kafka-ui-1.6.5/` | release `kafka-ui` |
| `clickhouse/helm/charts-offline/clickhouse-operator-install-bundle-0.27.2.yaml` | operator ClickHouse (`kubectl apply`, không phải Helm) |

Chart nội bộ `fss-kafka/` và `fss-clickhouse/` nằm sẵn trong repo — không tải, chỉ copy.
`longhornctl` không tự exec được trên Windows — chỉ copy binary này lên node Linux rồi
`chmod +x` (script `load-images.sh`/README đã nhắc).

### Nhóm 3 — Container image (20 image, xem `scripts/offline/images.txt`)
| Image | Dùng cho |
|---|---|
| `docker.io/longhornio/longhorn-manager:v1.12.1` | Longhorn manager (DaemonSet, 1/node) |
| `docker.io/longhornio/longhorn-engine:v1.12.1` | engine process mỗi volume |
| `docker.io/longhornio/longhorn-instance-manager:v1.12.1` | quản lý engine/replica process |
| `docker.io/longhornio/longhorn-share-manager:v1.12.1` | volume RWX (NFS) |
| `docker.io/longhornio/backing-image-manager:v1.12.1` | backing image (VM disk import...) |
| `docker.io/longhornio/longhorn-ui:v1.12.1` | dashboard Longhorn |
| `docker.io/longhornio/support-bundle-kit:v0.0.92` | thu log hỗ trợ debug |
| `docker.io/longhornio/csi-attacher:v4.12.0`, `csi-provisioner:v5.3.0`, `csi-resizer:v2.2.1`, `csi-snapshotter:v8.6.0`, `csi-node-driver-registrar:v2.17.0`, `livenessprobe:v2.19.0` | CSI sidecar chuẩn Kubernetes |
| `quay.io/strimzi/operator:1.2.0` | strimzi-cluster-operator + entity-operator (topic/user operator) + kafka init container |
| `quay.io/strimzi/kafka:1.2.0-kafka-4.3.0` | broker/controller Kafka (KRaft dual-role) |
| `ghcr.io/kafbat/kafka-ui:v1.5.0` | Kafka UI |
| `docker.io/altinity/clickhouse-operator:0.27.2` | clickhouse-operator |
| `docker.io/altinity/metrics-exporter:0.27.2` | sidecar metrics của operator |
| `docker.io/clickhouse/clickhouse-keeper:25.3` | ClickHouse Keeper (Raft) |
| `docker.io/clickhouse/clickhouse-server:25.3` | ClickHouse server |

Danh sách này khớp đúng version đã pin trong `longhorn/helm/charts-offline/longhorn-1.12.1/values.yaml`
(list gốc: `deploy/longhorn-images.txt` của release `v1.12.1`), `values-operator.yaml`,
`fss-kafka/Chart.yaml` (`appVersion: 4.3.0`), `fss-clickhouse/values.yaml` (`:25.3`) và bundle
operator 0.27.2. Đổi version ở values thì phải đổi lại `images.txt` và pull lại — không tự khớp.

**Không cần** image MetalLB/cert-manager ở đây — ngoài phạm vi 3 thư mục này.

---

## Bước 1 — Trên máy CÓ internet (bastion/dev, cần Docker)

```bash
cd scripts/offline
./pull-images.sh            # -> out/fss-k8s-images.tar (+ .sha256)
```

Kiểm tra lại `charts-offline/` của cả 3 thư mục đã đủ file ở bảng "Nhóm 2" (đã có sẵn trong repo,
script không đụng vào — chỉ cần nếu bạn đổi version thì tự tải lại bằng
`helm pull <repo>/<chart> --version X --untar -d charts-offline/` (giữ thư mục trần, không
`.tgz` — offline chỉ cần trỏ `helm install` thẳng vào thư mục chart) hoặc `curl` cho manifest
ClickHouse / binary `longhornctl`.

## Bước 2 — Mang sang máy production

Copy toàn bộ `D:\k8-infra` (đã gồm `charts-offline/*`, `longhorn/bin/*`) + file
`scripts/offline/out/fss-k8s-images.tar(.sha256)` qua USB/file share nội bộ.

## Bước 3 — Trên MỖI node Kubernetes production (không internet)

Pod có thể được schedule ở bất kỳ node nào trong 3 node — phải nạp image ở **cả 3 node**,
không chỉ node chạy `kubectl`/`helm`:

```bash
./scripts/offline/load-images.sh /path/to/fss-k8s-images.tar
```
Script tự nhận diện Docker / containerd (`nerdctl` hoặc `ctr`) đang chạy trên node đó.

Đồng thời trên mỗi node: cài gói OS cho Longhorn (xem cảnh báo Nhóm 4 bên dưới) + copy
`longhorn/bin/longhornctl-linux-amd64` vào PATH, `chmod +x`.

## Bước 4 — Cài như bình thường, dùng đường dẫn local

Chạy đúng runbook trong `longhorn/helm/README.md` → `kafka/helm/README.md` →
`clickhouse/helm/README.md` (đúng thứ tự), chỉ thay chỗ `helm repo add ...` /
`kubectl apply -f https://...` bằng file `charts-offline/` local — mỗi README đã có sẵn khối
lệnh "**Production offline**" ngay dưới bước tương ứng. `imagePullPolicy: IfNotPresent` đã cấu
hình sẵn trong `values-operator.yaml` và `kafka-ui/values.yaml` nên Kubernetes dùng image vừa
nạp, không cố pull ra ngoài. Longhorn image mặc định pull `IfNotPresent` (hành vi gốc upstream),
không cần chỉnh values.

## Xác minh không còn phụ thuộc internet

```bash
kubectl -n longhorn-system describe pods | grep -i "pulling image\|failed to pull"  # phải rỗng
kubectl -n kafka describe pods | grep -i "pulling image\|failed to pull"             # phải rỗng
kubectl -n clickhouse describe pods | grep -i "pulling image\|failed to pull"        # phải rỗng
```
`Pulling` xuất hiện + treo ở `ImagePullBackOff` nghĩa là thiếu image ở đúng node đó — chạy lại
`load-images.sh` trên node bị thiếu (`kubectl get pod -o wide` để biết node).

## Nhóm 4 — Gói OS cho Longhorn (Ubuntu 24.04 amd64)

`longhorn/helm/README.md` bước 0 yêu cầu chạy trên mỗi node:
```bash
sudo apt-get install -y open-iscsi nfs-common cryptsetup
```
Gói `.deb` này **không phải container image** — không nằm trong `pull-images.sh`/tarball ở
trên, máy air-gapped không `apt-get` được (không có apt repo). Đã tải sẵn full dependency
closure (105 file `.deb`, ~39MB, resolve bằng `apt-get install --download-only` trong container
`ubuntu:24.04` thật — không đoán tay) tại `longhorn/os-packages/ubuntu-24.04-amd64/`.

Trên mỗi node production (Ubuntu 24.04 amd64, sau khi copy thư mục này qua):
```bash
cd longhorn/os-packages/ubuntu-24.04-amd64
sudo ./install-debs.sh
```
Script tự verify checksum (`SHA256SUMS`) rồi `dpkg -i *.deb` (dpkg tự tính thứ tự dependency khi
cài cả loạt cùng lúc) + bật `iscsid`. Các bước `modprobe nfs/dm_crypt` + tắt `multipathd` trong
README vẫn phải chạy riêng sau đó (thuần lệnh kernel/systemd, không cần package gì thêm).

Nếu node production **không phải Ubuntu 24.04 amd64** (khác version/distro thật), bộ `.deb` này
sẽ KHÔNG cài được — báo lại để tải đúng bản.

## Bảo mật khi chuyển tài nguyên qua thiết bị vật lý (NĐ 13/2023 / nội bộ FSS)
- Image/chart ở trên là phần mềm public (Longhorn, Strimzi, ClickHouse, Kafbat, Altinity) —
  không chứa dữ liệu khách hàng. Không được kèm export DB, log sản xuất, hay credential thật lên
  cùng USB. Mật khẩu ClickHouse/Kafka user vẫn tạo trực tiếp trên production bằng
  `kubectl create secret` (xem README từng thư mục), không đi qua thiết bị chuyển file này.
- Toàn bộ bước cài là **draft cần human review trước khi chạy trên production**, qua đúng
  quy trình CI/CD hiện có — không có ngoại lệ vì "offline".
