# fss-kafka Helm chart

Chart Helm bọc các Strimzi CR (Kafka + KafkaNodePool + KafkaTopic + KafkaUser +
NetworkPolicy). **KHÔNG** cài Strimzi operator — operator dùng chart chính chủ, cài riêng.

```
fss-kafka/
├── Chart.yaml
├── values.yaml          # DEFAULT = production HA (3 broker + 3 controller, TLS/mTLS, rack, ACL)
├── values-dev.yaml      # override: single-zone, no TLS/auth, footprint nhỏ
└── templates/
    ├── _helpers.tpl
    ├── storageclass.yaml     # chỉ tạo khi storage.create=true
    ├── nodepool-controller.yaml
    ├── nodepool-broker.yaml
    ├── kafka.yaml
    ├── networkpolicy.yaml    # chỉ tạo khi networkPolicy.enabled=true
    ├── topics.yaml           # range .Values.topics
    ├── users.yaml            # range .Values.users
    └── NOTES.txt
```

## Cài đặt

### 1. Operator (một lần, tách khỏi chart này)
```bash
helm repo add strimzi https://strimzi.io/charts/ && helm repo update
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  -n kafka --create-namespace --set watchNamespaces="{kafka}"
kubectl -n kafka rollout status deploy/strimzi-cluster-operator
```

### 2. Validate TRƯỚC KHI cài (bắt buộc)
```bash
helm lint ./fss-kafka
# Render + kiểm tra schema theo version cluster đích:
helm template rel ./fss-kafka | kubeconform -strict -kubernetes-version 1.30.0 \
  -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Server-side dry-run (cần CRD Strimzi đã có trên cluster):
helm template rel ./fss-kafka | kubectl apply --server-side --dry-run=server -f -
```

### 3. Cài
```bash
# Production HA (values.yaml mặc định) — nhớ chỉnh storage.className cho khớp cluster:
helm install fss-kafka ./fss-kafka -n kafka \
  --set storage.className=<storageclass-thật>

# Dev (single-zone, no TLS):
helm install fss-kafka ./fss-kafka -n kafka -f ./fss-kafka/values-dev.yaml \
  --set storage.className=<storageclass-thật>

kubectl -n kafka wait kafka/fss-kafka --for=condition=Ready --timeout=600s
```

## Nâng cấp / rollback
```bash
helm diff upgrade fss-kafka ./fss-kafka -n kafka   # cần plugin helm-diff — REVIEW trước
helm upgrade fss-kafka ./fss-kafka -n kafka
helm rollback fss-kafka <REVISION> -n kafka        # helm history fss-kafka -n kafka để xem revision
```
- `storage.reclaimPolicy: Retain` + `deleteClaim: false` => `helm uninstall` KHÔNG xoá PVC/dữ liệu.
  Xoá PVC thủ công nếu thực sự muốn huỷ dữ liệu.
- Đổi `kafka.version` rồi mới nâng `kafka.metadataVersion` ở lần upgrade sau (2 bước, không đảo ngược metadataVersion).

## Các knob values quan trọng
| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `broker.replicas` / `controller.replicas` | 3 / 3 | quy mô HA |
| `kafka.config.min.insync.replicas` | 2 | ISR tối thiểu (cần producer acks=all) |
| `kafka.rack` | `{topologyKey: ...zone}` | đặt `null` để tắt rack + topology spread (dev/single-zone) |
| `kafka.authorization` | `{type: simple}` | đặt `null` để tắt ACL (dev) |
| `listeners` | TLS+mTLS 9093 | override thành plain cho dev |
| `storage.className` | `kafka-ssd` | **BẮT BUỘC** khớp cluster |
| `storage.create` | `false` | `true` để chart tự tạo StorageClass |
| `networkPolicy.enabled` | `true` | default-deny + allow client namespace |
| `topics` / `users` | ví dụ | khai báo declaratively |

## Nhắc lại về HA (không đổi so với bản raw YAML)
HA chỉ "đảm bảo" khi: (1) cluster có ≥3 node ở ≥3 zone, (2) StorageClass
`WaitForFirstConsumer`, (3) **producer acks=all + idempotence**, (4) đã diễn tập
xoá 1 broker ở staging. Chart này không thay đổi các điều kiện đó — chỉ đổi cách đóng gói.
Toàn bộ là draft cần human review + qua CI/CD trước prod.
