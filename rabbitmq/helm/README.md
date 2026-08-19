# RabbitMQ HA trên RabbitMQ Cluster Operator — triển khai bằng Helm

Cùng mô hình với Kafka/Strimzi: **operator trước, CR sau**. Khác biệt quan trọng so với
Strimzi (ghi rõ để không nhầm):

| Điểm | Strimzi (Kafka) | RabbitMQ Cluster Operator |
|---|---|---|
| Cài operator | có Helm chart chính chủ | **KHÔNG có Helm chart chính chủ** → cài bằng manifest release (`kubectl apply`) |
| Cert TLS | operator tự sinh CA + xoay vòng | **operator KHÔNG sinh cert** → phải cấp Secret qua cert-manager |
| PDB | chart này tự tạo | operator không tạo → **chart này tự tạo** |
| HA queue | RF=3 + min.insync=2 (broker) | **quorum queues** (Raft) + replicas lẻ |

## HA đến từ đâu

| Lớp | Cơ chế |
|---|---|
| Replication dữ liệu | **quorum queues** (Raft) — mỗi queue nhân bản qua các node; cần majority sống |
| Metadata | Khepri/Mnesia đồng thuận qua các node (cũng cần majority) |
| Split-brain | `cluster_partition_handling = pause_minority` — phe thiểu số TỰ DỪNG |
| Phân tán pod | podAntiAffinity CỨNG theo hostname — 1 pod/node |
| Disruption | PDB `maxUnavailable=1` khi drain/upgrade |

**replicas phải LẺ (3/5/7)** để quorum có majority rõ ràng — giống KRaft controller. 3 node
chịu mất 1; 5 node chịu mất 2.

⚠️ Classic mirrored queues đã bị loại bỏ ở RabbitMQ 4.x. HA = **quorum queues**
(`default_queue_type = quorum` đã set sẵn trong `values.yaml`). Đừng khai báo `ha-mode` policy kiểu cũ.

---

## Cài đặt

### 0. Namespace + PSS labels (bootstrap, 1 lần)
```bash
kubectl create namespace rabbitmq
kubectl label namespace rabbitmq \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```
> Operator gần đây (2.x) sinh pod tương thích `restricted` (runAsNonRoot, secc, drop ALL).
> Xác nhận sau khi cluster chạy: `kubectl -n rabbitmq get pods` không bị PSS chặn.

### 1. Hai operator (release "operator" — bằng manifest chính chủ)
RabbitMQ **không** phát hành Helm chart chính chủ cho operator; đường cài chuẩn là manifest
release đã version-hoá (không phải YAML app tự chế — đây là artifact chính chủ, verify được):
```bash
# Cluster Operator — quản lý RabbitmqCluster
kubectl apply -f "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml"
kubectl -n rabbitmq-system rollout status deploy/rabbitmq-cluster-operator

# Messaging Topology Operator — quản lý Vhost/User/Permission/Queue/Policy
# (cần cert-manager cài trước; topology operator dùng webhook có TLS)
kubectl apply -f "https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator-with-certmanager.yaml"
kubectl -n rabbitmq-system rollout status deploy/messaging-topology-operator
```
> PROD fintech: **pin phiên bản** thay vì `latest` (đổi `latest` → tag release cụ thể), lưu
> manifest vào repo để reproducible + audit. `latest` chỉ hợp lab.

### 2. Validate chart TRƯỚC KHI cài
```bash
helm lint ./fss-rabbitmq
helm template fss-rabbitmq ./fss-rabbitmq -n rabbitmq | kubectl apply --server-side --dry-run=server -f -
```

### 3. App: cụm RabbitMQ (release "fss-rabbitmq")
```bash
# storage.create=true => chart tạo StorageClass rabbitmq-ssd (Longhorn, numberOfReplicas=1).
# Nếu rabbitmq-ssd đã tồn tại: kubectl delete sc rabbitmq-ssd  (không xoá PV/PVC).
helm upgrade --install fss-rabbitmq ./fss-rabbitmq -n rabbitmq

kubectl -n rabbitmq wait rabbitmqcluster/fss-rabbitmq --for=condition=AllReplicasReady --timeout=600s
kubectl -n rabbitmq get pods -o wide
```

Dev (no TLS, no NetworkPolicy, SC sẵn có):
```bash
helm upgrade --install fss-rabbitmq ./fss-rabbitmq -n rabbitmq -f ./fss-rabbitmq/values-dev.yaml
```

---

## Values quan trọng (`fss-rabbitmq/values.yaml`)
| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `nodes.replicas` | 3 | số node — GIỮ LẺ cho quorum |
| `nodes.storage.size` | 8Gi | phải < disk trống Longhorn mỗi node |
| `nodes.antiAffinityTopologyKey` | `kubernetes.io/hostname` | đổi `topology.kubernetes.io/zone` khi có zone thật |
| `rabbitmq.additionalConfig.default_queue_type` | `quorum` | queue mới mặc định là quorum (HA) |
| `rabbitmq.additionalConfig.cluster_partition_handling` | `pause_minority` | an toàn split-brain |
| `rabbitmq.image` | `""` | trống = operator chọn image đã test; prod pin theo digest |
| `tls.enabled` | `false` | **bật ở prod**; cần cert-manager cấp Secret |
| `tls.disableNonTLSListeners` | `false` | `true` = chỉ cho TLS |
| `pdb.maxUnavailable` | 1 | operator không tự tạo PDB → chart tạo |
| `storage.create` / `storage.className` | `true` / `rabbitmq-ssd` | chart tạo SC Longhorn |
| `networkPolicy.enabled` | `true` | default-deny + allow nội cụm + allow client namespace |
| `vhosts`/`users`/`permissions`/`queues`/`policies` | ví dụ | khai báo declarative qua Topology Operator |

---

## Kết nối client (Spring Boot, v.v.)

Credentials do Topology Operator sinh vào Secret **`<user>-user-credentials`** (key `username`,
`password`). Xác nhận tên chính xác: `kubectl -n rabbitmq get user app-orders -o jsonpath='{.status.credentials.name}'`.
```bash
kubectl -n rabbitmq get secret app-orders-user-credentials -o jsonpath='{.data.username}' | base64 -d ; echo
kubectl -n rabbitmq get secret app-orders-user-credentials -o jsonpath='{.data.password}' | base64 -d ; echo
```
Mount Secret vào pod app (KHÔNG hardcode), ví dụ Spring Boot `application.yml`:
```yaml
spring:
  rabbitmq:
    host: fss-rabbitmq.rabbitmq.svc
    port: 5671            # 5672 nếu chưa bật TLS
    virtual-host: /fss
    username: ${RABBITMQ_USERNAME}     # từ Secret app-orders-user-credentials
    password: ${RABBITMQ_PASSWORD}
    ssl:
      enabled: true       # khi tls.enabled=true
      # trust store trỏ tới CA cấp cho tls.secretName (cert-manager issuer CA)
```
> AMQP là giao thức TCP nhị phân — nối `host:port`, KHÔNG phải URL trình duyệt (management UI là 15672/15671).

## Validate HA
```bash
kubectl -n rabbitmq get pods -o wide                 # 3 pod, mỗi node 1 (anti-affinity)
kubectl -n rabbitmq get pdb                           # maxUnavailable=1
kubectl -n rabbitmq exec fss-rabbitmq-server-0 -- rabbitmqctl cluster_status
kubectl -n rabbitmq exec fss-rabbitmq-server-0 -- rabbitmq-queues quorum_status orders-events

# Diễn tập chịu lỗi (staging, KHÔNG prod): xoá 1 pod, quorum queue phải vẫn phục vụ:
kubectl -n rabbitmq delete pod fss-rabbitmq-server-1
```

## Nâng cấp / rollback
```bash
helm -n rabbitmq history fss-rabbitmq
helm -n rabbitmq rollback fss-rabbitmq <REVISION>
```
- `reclaimPolicy: Retain` => `helm uninstall` KHÔNG xoá PVC/dữ liệu.
- Nâng version RabbitMQ: đổi `rabbitmq.image` rồi upgrade; operator rolling-update theo ordinal
  (đọc release notes — nhảy nhiều minor version một lần không được hỗ trợ).
- DR thật: export definitions + backup PVC (Velero). Quorum queue nội cụm KHÔNG thay backup.

## Bảo mật (fintech / NĐ 13/2023)
- Chỉ listener nội cluster; bật TLS (`tls.enabled=true`) + cân nhắc `disableNonTLSListeners=true` ở prod.
- User/permission scope hẹp theo vhost + regex (deny-by-default); không dùng user `guest`.
- Credentials chỉ nằm trong Secret + env; KHÔNG hardcode, KHÔNG commit git.
- Mọi thứ là **draft cần human review + qua CI/CD**. Test bằng dữ liệu **synthetic**.

## Điều kiện để HA thực sự "đảm bảo"
≥3 node · replicas LẺ · dùng **quorum queues** (không classic) · `pause_minority` ·
publisher confirms bật phía client · đã diễn tập xoá 1 node. Helm chỉ đóng gói, không thay các điều kiện này.
