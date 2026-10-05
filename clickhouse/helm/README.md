# ClickHouse HA trên Altinity clickhouse-operator — triển khai bằng Helm

Cùng mô hình với Kafka/RabbitMQ: **operator trước, CR sau**. Một operator Altinity quản
**cả hai** CRD: `ClickHouseKeeperInstallation` (CHK) và `ClickHouseInstallation` (CHI).

## HA đến từ đâu

| Lớp | Cơ chế |
|---|---|
| Replication dữ liệu | bảng **ReplicatedMergeTree** + `replicasCount >= 2` — mỗi replica giữ full copy |
| Điều phối replication | **ClickHouse Keeper** (Raft, thay ZooKeeper), ensemble LẺ 3/5 node |
| Phân tán pod | `podDistribution: ReplicaAntiAffinity` (CH) + `MaxNumberPerNode=1` — 1 pod/node |
| Disruption | PDB `maxUnavailable=1` cho cả CH và Keeper |

⚠️ **HA chỉ có thật khi bảng là ReplicatedMergeTree.** `MergeTree` thường KHÔNG nhân bản —
mất 1 replica là mất dữ liệu. Tạo bảng: `... ENGINE = ReplicatedMergeTree(...) ... ON CLUSTER 'fss'`.

**Keeper phải có quorum.** Mất majority Keeper -> replication dừng, insert vào bảng replicated bị chặn.
Vì thế `keeper.replicas` GIỮ LẺ (3/5/7), giống KRaft controller / RabbitMQ quorum.

---

## So sánh với Strimzi/RabbitMQ (để không nhầm)

| | Strimzi | RabbitMQ | clickhouse-operator |
|---|---|---|---|
| Cài operator | Helm chart chính chủ | manifest | **Helm chart chính chủ HOẶC bundle manifest** (đều có) |
| Coordination | KRaft nội tại | Khepri nội tại | **Keeper riêng (CHK CR)** |
| Cert TLS | tự sinh | cert-manager | tự cấu hình (chart này CHƯA bật TLS — xem "Còn thiếu") |
| PDB | chart tự tạo | chart tự tạo | **chart tự tạo** |

---

## Cài đặt

### 0. Namespace + PSS labels (bootstrap, 1 lần)
```bash
kubectl create namespace clickhouse
kubectl label namespace clickhouse \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```
> Operator 0.27.x sinh pod tương thích restricted khi ta set securityContext (đã có trong
> `values.yaml`: runAsNonRoot, uid 101, seccomp RuntimeDefault, drop ALL). Xác nhận:
> `kubectl -n clickhouse get pods` không bị PSS chặn.

### 1. Operator (release "operator", cluster-scoped — cài 1 lần cho cả cluster)
Đường **canonical, verify được** là bundle manifest PIN version (0.27.2):
```bash
# Bản URL upstream cài vào kube-system. Bản offline (charts-offline/) đã sửa sang namespace clickhouse-operator.
kubectl apply -f "https://raw.githubusercontent.com/Altinity/clickhouse-operator/0.27.2/deploy/operator/clickhouse-operator-install-bundle.yaml"
kubectl -n kube-system rollout status deploy/clickhouse-operator
```

**Production offline (không internet):** dùng file đã tải sẵn trong `charts-offline/`
thay vì URL GitHub — xem **[../../OFFLINE-INSTALL.md](../../OFFLINE-INSTALL.md)** để
chuẩn bị images trước khi mang lên máy production.
```bash
kubectl create namespace clickhouse-operator
kubectl apply -f charts-offline/clickhouse-operator-install-bundle-0.27.2.yaml
kubectl -n clickhouse-operator rollout status deploy/clickhouse-operator
```
> Có Helm chart chính chủ `altinity-clickhouse-operator` (v0.27.2, tự cài CRD qua hook) nếu
> muốn quản operator bằng Helm — repo URL xác nhận trên Artifact Hub (không hardcode ở đây để
> tránh sai). PROD: pin version cụ thể (đừng `latest`), lưu manifest vào git để audit.

### 2. (nếu có users) Tạo Secret mật khẩu TRƯỚC khi cài
Mật khẩu ClickHouse khai báo dạng **sha256 hex**, lấy từ Secret — KHÔNG hardcode:
```bash
kubectl -n clickhouse create secret generic clickhouse-app-helios \
  --from-literal=password_sha256_hex=$(echo -n 'MẬT_KHẨU_MẠNH' | sha256sum | cut -d' ' -f1)
```

### 3. Validate chart TRƯỚC KHI cài
```bash
helm lint ./fss-clickhouse
helm template fss-clickhouse ./fss-clickhouse -n clickhouse | kubectl apply --server-side --dry-run=server -f -
```

### 4. App: Keeper + ClickHouse (release "fss-clickhouse")
```bash
# storage.create=true => chart tạo StorageClass clickhouse-ssd (Longhorn, numberOfReplicas=1).
helm upgrade --install fss-clickhouse ./fss-clickhouse -n clickhouse

kubectl -n clickhouse wait chk/fss-keeper     --for=condition=Ready --timeout=600s
kubectl -n clickhouse wait chi/fss-clickhouse --for=condition=Ready --timeout=600s
kubectl -n clickhouse get pods -o wide
```

Dev (no NetworkPolicy, SC sẵn có, sizing nhỏ):
```bash
helm upgrade --install fss-clickhouse ./fss-clickhouse -n clickhouse -f ./fss-clickhouse/values-dev.yaml
```

---

## Values quan trọng (`fss-clickhouse/values.yaml`)
| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `keeper.replicas` | 3 | ensemble Raft — GIỮ LẺ |
| `keeper.storage.size` | 10Gi | Raft log+snapshot; phải persist |
| `clickhouse.shardsCount` | 1 | scale-out ngang |
| `clickhouse.replicasCount` | 2 | **>=2 để HA** |
| `clickhouse.maxPerNode` | 1 | 1 CH pod/node -> replicasCount <= số node |
| `clickhouse.image` / `keeper.image` | `:25.3` | version KHỚP nhau; prod pin digest |
| `antiAffinityTopologyKey` | `kubernetes.io/hostname` | đổi `topology.kubernetes.io/zone` khi có zone thật |
| `storage.create` / `className` | `true` / `clickhouse-ssd` | chart tạo SC Longhorn |
| `pdb.maxUnavailable` | 1 | operator không tự tạo PDB |
| `networkPolicy.enabled` | `true` | default-deny + intra + client |
| `users[]` | app_helios | user declarative; password_sha256_hex từ Secret |

---

## Kết nối client
```yaml
# HTTP 8123 / native 9000. Ví dụ Spring Boot (clickhouse-jdbc / r2dbc):
spring:
  datasource:
    url: jdbc:clickhouse://clickhouse-fss-clickhouse.clickhouse.svc:8123/default
    username: app_helios
    password: ${CLICKHOUSE_PASSWORD}   # plaintext phía client; server so khớp sha256 đã cấu hình
```
> ClickHouse dùng HTTP(8123)/TCP nhị phân(9000) — nối `host:port`, management/monitoring qua HTTP.

## Validate HA
```bash
kubectl -n clickhouse get pods -o wide                 # CH 1/node, Keeper 1/node (anti-affinity)
kubectl -n clickhouse get pdb
# Keeper quorum:
kubectl -n clickhouse exec chi-... -- clickhouse-client -q "SELECT * FROM system.zookeeper WHERE path='/' FORMAT Vertical"
# Trạng thái replica:
kubectl -n clickhouse exec chi-... -- clickhouse-client -q "SELECT database, table, is_readonly, absolute_delay FROM system.replicas FORMAT Vertical"

# Diễn tập chịu lỗi (staging, KHÔNG prod): xoá 1 CH replica, insert vào bảng replicated phải vẫn chạy:
kubectl -n clickhouse delete pod chi-fss-clickhouse-fss-0-1-0
```

## Nâng cấp / rollback
```bash
helm -n clickhouse history fss-clickhouse
helm -n clickhouse rollback fss-clickhouse <REVISION>
```
- `reclaimPolicy: Retain` => `helm uninstall` KHÔNG xoá PVC/dữ liệu.
- Nâng version: đổi `clickhouse.image` + `keeper.image` (giữ KHỚP), upgrade; operator rolling theo host.
  Không nhảy quá nhiều version một lần (đọc release notes ClickHouse).
- DR thật: `clickhouse-backup` / snapshot PVC (Velero) + export schema. Replication nội cụm KHÔNG thay backup.

## Còn thiếu / cần bổ sung cho PROD
- **TLS/mTLS chưa bật** trong chart này (khác Kafka/RabbitMQ đã có). Fintech prod: bật listener
  HTTPS 8443 / native TLS 9440 + cert (cert-manager). Nói nếu bạn muốn tôi thêm.
- Backup định kỳ (`clickhouse-backup` CronJob).
- Quota/profile chi tiết theo user.

## Bảo mật (fintech / NĐ 13/2023)
- User scope hẹp: `networks/ip` chỉ subnet nội bộ (KHÔNG `::/0`), mật khẩu sha256 từ Secret.
- NetworkPolicy default-deny; Keeper KHÔNG expose ra client; chỉ CH mở 8123/9000 cho client namespace.
- Mọi thứ là **draft cần human review + qua CI/CD**. Test bằng dữ liệu **synthetic**.

## Điều kiện để HA thực sự "đảm bảo"
≥3 node · `keeper.replicas` LẺ · `replicasCount>=2` · bảng **ReplicatedMergeTree** ·
Keeper còn quorum · đã diễn tập xoá 1 replica. Helm chỉ đóng gói, không thay các điều kiện này.
