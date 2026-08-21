# Kafka HA trên Strimzi (KRaft) — triển khai bằng Helm

Toàn bộ triển khai qua **Helm**, không dùng file YAML thô. Gồm **2 Helm release**
(không gộp được thành 1 — xem "Vì sao 2 release" bên dưới):

| Release | Chart | Tạo ra |
|---|---|---|
| `strimzi-operator` | `strimzi/strimzi-kafka-operator` + `values-operator.yaml` | operator + CRDs |
| `fss-kafka` | `./fss-kafka` (chart nội bộ) | StorageClass, Kafka CR, node pools, topics, users, NetworkPolicy |

## Topology HA
| Thành phần | Replicas | Chịu lỗi |
|---|---|---|
| dual-role node (controller+broker) | 3 | mất 1 node → còn quorum 2/3 + RF=3 → 0 mất dữ liệu (ISR=2, **producer acks=all**) |

Mỗi node đóng cả 2 vai trò KRaft (controller quorum) và broker (data). 3 pod, 1/node —
hợp cluster nhỏ. Có ≥6 node worker riêng thì cân nhắc tách dedicated (2 pool).

HA đến từ 4 lớp: replication (RF=3, min.insync=2, no unclean election) · rack awareness
(replica trải 3 zone) · topology spread (`DoNotSchedule`, 1 pod/zone) · PDB (`maxUnavailable=1`).

---

## Cài đặt

### 0. Namespace + PSS labels (bootstrap, 1 lần)
Namespace phải tồn tại + có nhãn PSS **trước** khi cài operator (operator cài *vào* ns này).
```bash
kubectl create namespace kafka
kubectl label namespace kafka \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

### 1. Operator (release 1)
```bash
helm repo add strimzi https://strimzi.io/charts/ && helm repo update
helm upgrade --install strimzi-operator strimzi/strimzi-kafka-operator \
  -n kafka -f values-operator.yaml
kubectl -n kafka rollout status deploy/strimzi-cluster-operator
```
`values-operator.yaml` xử lý trọn PSS restricted (khai báo, không patch tay):
- `extraEnvs: STRIMZI_POD_SECURITY_PROVIDER_CLASS=restricted` → pod Kafka đạt restricted
  (chart KHÔNG có key `podSecurityProviderClass` — phải qua `extraEnvs`).
- `podSecurityContext` + `securityContext` → chính pod operator đạt restricted.

Xác nhận biến đã vào:
```bash
kubectl -n kafka get deploy strimzi-cluster-operator \
  -o jsonpath='{..env[?(@.name=="STRIMZI_POD_SECURITY_PROVIDER_CLASS")].value}{"\n"}'   # -> restricted
```

### 2. Validate chart TRƯỚC KHI cài app (release 2)
```bash
helm lint ./fss-kafka
helm template fss-kafka ./fss-kafka -n kafka | kubectl apply --server-side --dry-run=server -f -
```

### 3. App: cụm Kafka (release 2)
```bash
# storage.create=true => chart tạo StorageClass kafka-ssd (Longhorn, numberOfReplicas=1).
# Nếu kafka-ssd đã tồn tại: kubectl delete sc kafka-ssd  (an toàn, không xoá PV/PVC).
helm upgrade --install fss-kafka ./fss-kafka -n kafka

kubectl -n kafka wait kafka/fss-kafka --for=condition=Ready --timeout=600s
kubectl -n kafka get pods -o wide -L topology.kubernetes.io/zone
```

Dev (single-zone, no TLS/auth):
```bash
helm upgrade --install fss-kafka ./fss-kafka -n kafka -f ./fss-kafka/values-dev.yaml
```

---

## Vì sao 2 release (không gộp 1 `helm install`)
Operator cài **CRD** (`Kafka`, `KafkaNodePool`). Nếu Kafka CR nằm chung release với
operator, Helm apply CR khi CRD chưa đăng ký → `no matches for kind "Kafka"`. Strimzi vì
thế yêu cầu operator trước, CR sau. Đây là ràng buộc thật, không né được bằng chart lồng nhau.

## Values quan trọng (`fss-kafka/values.yaml`)
| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `nodes.replicas` | 3 | số node dual-role (quy mô HA) |
| `nodes.storage.size` | 10Gi | phải < disk trống Longhorn mỗi node |
| `tolerations` | control-plane | cho phép chạy trên control-plane (cluster 3-node) |
| `kafka.config.min.insync.replicas` | 2 | cần producer acks=all mới có tác dụng |
| `kafka.rack` | `{topologyKey: ...zone}` | `null` để tắt (dev/single-zone) |
| `kafka.authorization` | `{type: simple}` | `null` để tắt ACL (dev) |
| `listeners` | TLS+mTLS 9093 (internal) + 9094 (loadbalancer) | override plain cho dev |
| `externalListener.enabled` | `true` | bật external listener loadbalancer |
| `externalListener.bootstrapIP` / `brokerIPs` | `""` / `[]` | IP cố định trong dải MetalLB pool; trống -> MetalLB tự cấp |
| `storage.create` / `storage.className` | `true` / `kafka-ssd` | chart tạo SC Longhorn |
| `networkPolicy.enabled` | `true` | default-deny + allow client namespace |
| `topics` / `users` | ví dụ | khai báo declaratively |

---

## Validate HA
```bash
kubectl -n kafka get pods -o wide -L topology.kubernetes.io/zone   # 1 broker+1 controller mỗi zone
kubectl -n kafka get pdb                                            # maxUnavailable=1
kubectl get nodes -L topology.kubernetes.io/zone                   # đủ 3 zone? thiếu -> pod Pending
kubectl -n kafka get pods | grep -i pending                        # phải RỖNG

# RF thật của __consumer_offsets (listener chỉ TLS 9093 -> dùng admin config Strimzi mount sẵn):
kubectl -n kafka exec -it fss-kafka-broker-0 -- \
  bin/kafka-topics.sh --describe --topic __consumer_offsets \
  --bootstrap-server fss-kafka-kafka-bootstrap:9093 --command-config /tmp/strimzi.properties

# Diễn tập chịu lỗi (staging, KHÔNG prod): xoá 1 broker, producer acks=all phải KHÔNG lỗi:
kubectl -n kafka delete pod fss-kafka-broker-1
```

## Client mTLS
```bash
kubectl -n kafka get secret fss-kafka-cluster-ca-cert -o jsonpath='{.data.ca\.crt}'   | base64 -d > ca.crt
kubectl -n kafka get secret app-orders-producer      -o jsonpath='{.data.user\.crt}' | base64 -d > user.crt
kubectl -n kafka get secret app-orders-producer      -o jsonpath='{.data.user\.key}' | base64 -d > user.key
# Bootstrap nội bộ: fss-kafka-kafka-bootstrap.kafka.svc:9093
```

## External access (LoadBalancer 9094)
Kafka KHÔNG phải HTTP — client dùng `host:port` (bootstrap), không phải web URL.
```bash
# Xem IP LB đã cấp (1 bootstrap + 3 broker):
kubectl -n kafka get svc -l strimzi.io/cluster=fss-kafka | grep -i loadbalancer
# Bootstrap external (địa chỉ đưa cho client ngoài): <bootstrapIP>:9094
# Client vẫn cần mTLS: import ca.crt (truststore) + user.crt/user.key (keystore).
# Strimzi tự thêm SAN cho IP external -> TLS handshake khớp, không phải sửa SAN tay.
```
⚠️ Fintech: giữ TLS+mTLS+ACL trên external listener; firewall/NetworkPolicy giới hạn IP nguồn
tới 4 IP LB; KHÔNG bơm dữ liệu khách hàng thật để test (dùng synthetic). Draft cần human review.

## Yêu cầu phía client (BẮT BUỘC để HA có nghĩa)
`min.insync.replicas=2` chỉ chống mất dữ liệu khi producer chờ đủ replica ack:
```properties
acks=all
enable.idempotence=true
max.in.flight.requests.per.connection=5
retries=2147483647
delivery.timeout.ms=120000
```
`acks=1`/`acks=0` => mất message dù cụm vẫn "HA". Đưa vào code review chuẩn.

## Nâng cấp / rollback
```bash
helm -n kafka history fss-kafka
helm -n kafka upgrade fss-kafka ./fss-kafka          # xem diff trước nếu có plugin helm-diff
helm -n kafka rollback fss-kafka <REVISION>
```
- `reclaimPolicy: Retain` + `deleteClaim: false` => `helm uninstall` KHÔNG xoá PVC/dữ liệu.
- Đổi `kafka.version` rồi mới set `kafka.metadataVersion` ở upgrade sau (2 bước, không đảo ngược).
- DR thật: MirrorMaker2 / snapshot PVC (Velero) — replication nội cụm KHÔNG thay backup.

## Bảo mật (fintech / NĐ 13/2023)
- Listener chỉ internal + TLS + mTLS; authorization `simple` deny-by-default.
- Cert do Strimzi CA tự sinh & xoay vòng; cân nhắc rút ngắn `clusterCa.renewalDays` cho prod.
- Mọi thứ là **draft cần human review + qua CI/CD** trước prod.

## Điều kiện để HA thực sự "đảm bảo" (không đổi so với bản raw)
≥3 node ở ≥3 zone · StorageClass `WaitForFirstConsumer` · **producer acks=all** ·
đã diễn tập xoá 1 broker. Helm chỉ đổi cách đóng gói, không thay đổi các điều kiện này.

---

## Kafka UI (release 3, tuỳ chọn)

Dùng chart upstream `kafbat/kafka-ui` + values ở `kafka-ui/` — **không viết chart riêng**.
Cài **trong ns `kafka`**: `secretKeyRef` không đọc được Secret ở ns khác, mà cert
KafkaUser + cluster CA đều nằm ở ns `kafka`.

```bash
# 0. Tạo KafkaUser `kafka-ui` (đã có trong users[] của fss-kafka/values.yaml)
helm -n kafka upgrade --install fss-kafka ./fss-kafka
kubectl -n kafka get secret kafka-ui fss-kafka-cluster-ca-cert   # phải tồn tại trước bước 2

# 1. NetworkPolicy: cho pod trong ns kafka nối tới listener 9093
kubectl label namespace kafka kafka-client=true --overwrite

# 2. Cài UI
helm repo add kafbat https://kafbat.github.io/helm-charts && helm repo update kafbat
helm -n kafka upgrade --install kafka-ui kafbat/kafka-ui -f kafka-ui/values.yaml
kubectl -n kafka rollout status deploy/kafka-ui

# 3. Truy cập (không ingress)
kubectl -n kafka port-forward svc/kafka-ui 8080:80   # http://localhost:8080
```

Dev (đi với `fss-kafka/values-dev.yaml`, listener plain 9093, không TLS/ACL):
```bash
helm -n kafka upgrade --install kafka-ui kafbat/kafka-ui \
  -f kafka-ui/values.yaml -f kafka-ui/values-dev.yaml
```

Mặc định đã chọn:
- `KAFKA_CLUSTERS_0_READONLY=true` + KafkaUser chỉ có ACL đọc (2 lớp) — UI không sửa được cụm.
- Config qua ENV `KAFKA_CLUSTERS_0_*`, **không** `yamlApplicationConfig`: Spring ghi đè list
  `kafka.clusters` theo cả list, trộn 2 nguồn sẽ mất config.
- `ingress.enabled=false`. **Bật ingress thì phải bật auth trước** (`AUTH_TYPE=LOGIN_FORM` +
  `SPRING_SECURITY_USER_*` qua `envs.secretMappings`, hoặc OIDC): UI không auth = xem được
  toàn bộ nội dung message, vi phạm yêu cầu bảo mật dữ liệu khách hàng.

Gỡ: `helm -n kafka uninstall kafka-ui` (KafkaUser `kafka-ui` xoá riêng trong `users[]` nếu cần).
