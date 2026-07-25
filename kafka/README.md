# Kafka HA trên Strimzi (KRaft)

Cụm Kafka production HA quản lý bởi Strimzi Operator ở **KRaft mode** (không ZooKeeper).

## Topology HA
| Thành phần | Replicas | Vai trò | Chịu lỗi |
|---|---|---|---|
| controller (KafkaNodePool) | 3 | KRaft metadata quorum | mất 1 controller → không downtime metadata |
| broker (KafkaNodePool) | 3 | data plane | mất 1 broker → 0 mất dữ liệu (RF=3, ISR=2, acks=all) |

Đảm bảo HA đến từ **4 lớp**:
1. **Replication**: `default.replication.factor=3`, `min.insync.replicas=2`, `unclean.leader.election.enable=false`.
2. **Rack awareness** (`rack.topologyKey`): replica của mỗi partition trải trên 3 zone → mất cả 1 AZ vẫn còn quorum.
3. **Topology spread** (`DoNotSchedule`): 1 broker + 1 controller mỗi zone, không dồn pod.
4. **PodDisruptionBudget** `maxUnavailable=1`: drain/upgrade node không hạ quá 1 broker cùng lúc.

## Trước khi apply — BẮT BUỘC chỉnh
- `10-*.yaml`, `11-*.yaml`: thay `REPLACE-storageclass` bằng StorageClass thật.
  - Khuyến nghị: `allowVolumeExpansion: true`, `reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer` (để PV bám đúng zone của pod).
- Nếu **on-prem không có** label `topology.kubernetes.io/zone`: gán label zone cho node, hoặc đổi `topologyKey` sang `kubernetes.io/hostname` (chỉ chống trùng node, KHÔNG chống mất zone).
- Chỉnh `resources`/`jvmOptions` theo capacity thật. Quy tắc: `-Xmx == -Xms` và ≤ ~50% memory limit (phần còn lại cho OS page cache).

## Cài đặt

### 1. Cài Strimzi Operator (một lần)
```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka --create-namespace \
  --set watchNamespaces="{kafka}"          # namespace-scoped, ít quyền hơn cluster-wide
kubectl -n kafka rollout status deploy/strimzi-cluster-operator
```

### 2. Apply theo thứ tự (dry-run trước)
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 05-storageclass.yaml        # đã chọn đúng block nền tảng, xoá block thừa
kubectl get sc kafka-ssd                     # xác nhận VOLUMEBINDINGMODE = WaitForFirstConsumer
# Validate schema + server-side dry run TRƯỚC KHI apply thật:
for f in 10-nodepool-controller 11-nodepool-broker 20-kafka-cluster; do
  kubectl apply --server-side --dry-run=server -f $f.yaml
done
kubectl apply -f 10-nodepool-controller.yaml
kubectl apply -f 11-nodepool-broker.yaml
kubectl apply -f 20-kafka-cluster.yaml
kubectl apply -f 40-networkpolicy.yaml

# Chờ cụm Ready (Strimzi set condition Ready khi tất cả pod up + quorum ok):
kubectl -n kafka wait kafka/fss-kafka --for=condition=Ready --timeout=600s

kubectl apply -f 30-topic-example.yaml
kubectl apply -f 31-user-example.yaml
```

## Validate HA
```bash
# 1. Pod trải đủ 3 zone (mỗi zone 1 broker + 1 controller):
kubectl -n kafka get pods -o wide -L topology.kubernetes.io/zone

# 2. PDB tồn tại, maxUnavailable=1:
kubectl -n kafka get pdb

# 3. Topic __consumer_offsets có RF=3 (kiểm tra thật thay vì tin config).
#    Cụm CHỈ mở listener TLS+mTLS 9093 (không có plaintext 9092) => phải dùng
#    cert. Cách gọn: exec vào broker và dùng chính admin config Strimzi đã mount:
kubectl -n kafka exec -it fss-kafka-broker-0 -- \
  bin/kafka-topics.sh --describe --topic __consumer_offsets \
  --bootstrap-server fss-kafka-kafka-bootstrap:9093 \
  --command-config /tmp/strimzi.properties
#    (Nếu file trên khác đường dẫn, chạy: kubectl -n kafka exec fss-kafka-broker-0 --
#     ls /tmp | grep -i properties  — Strimzi sinh admin config sẵn trong pod.)

# 4. Diễn tập chịu lỗi (staging, KHÔNG chạy thẳng prod):
kubectl -n kafka delete pod fss-kafka-broker-1     # producer acks=all phải KHÔNG lỗi

# 5. Node/zone thật sự đủ cho topology spread (nếu thiếu, pod sẽ Pending):
kubectl get nodes -L topology.kubernetes.io/zone
kubectl -n kafka get pods -o wide | grep -i pending    # phải RỖNG
```

## Lấy credential mTLS cho client
```bash
# CA cluster + cert/key của KafkaUser:
kubectl -n kafka get secret fss-kafka-cluster-ca-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl -n kafka get secret app-orders-producer -o jsonpath='{.data.user\.crt}' | base64 -d > user.crt
kubectl -n kafka get secret app-orders-producer -o jsonpath='{.data.user\.key}' | base64 -d > user.key
# Bootstrap (nội bộ cluster): fss-kafka-kafka-bootstrap.kafka.svc:9093
```

## Yêu cầu phía client (BẮT BUỘC để HA có nghĩa)
`min.insync.replicas=2` chỉ chống mất dữ liệu khi producer chờ đủ replica ack.
Server không ép được — FSS phải cấu hình producer:
```properties
acks=all
enable.idempotence=true
max.in.flight.requests.per.connection=5
retries=2147483647
delivery.timeout.ms=120000
```
Nếu producer để `acks=1`/`acks=0`, khi broker leader chết trước lúc replica kịp
copy => **mất message dù cụm vẫn "HA"**. Đưa yêu cầu này vào code review chuẩn.

## Rollback / recovery
- **Cấu hình sai**: `kubectl apply` lại revision trước từ git; Strimzi hòa giải (reconcile) rolling, an toàn.
- **Đổi version Kafka**: chỉnh `spec.kafka.version` rồi (sau khi ổn) nâng `metadataVersion` — hai bước riêng, không nâng metadataVersion trước.
- **Xoá cụm**: `deleteClaim: false` giữ lại PVC → dữ liệu KHÔNG mất khi xoá Kafka CR. Xoá PVC thủ công nếu thực sự muốn huỷ dữ liệu.
- Sao lưu ngoài cluster (MirrorMaker2 sang cụm/DR khác, hoặc snapshot PVC qua Velero) cho DR thật sự — replication trong cụm KHÔNG thay thế backup.

## Lưu ý bảo mật (fintech / NĐ 13/2023)
- Listener chỉ internal + TLS + mTLS; authorization `simple` deny-by-default. Không expose ra ngoài trừ khi thật cần external listener.
- Mọi cert do Strimzi CA tự sinh & tự xoay vòng; cân nhắc rút ngắn `clusterCa.renewalDays` cho môi trường critical.
- Toàn bộ artifact là **draft cần human review + qua CI/CD** trước khi apply prod.
