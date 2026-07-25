# Kafka HA trên Strimzi (KRaft)

Triển khai **hoàn toàn bằng Helm**. Không còn file YAML thô.

- Runbook đầy đủ (cài đặt, validate HA, rollback, bảo mật): **[helm/README.md](helm/README.md)**
- Chart cụm Kafka: `helm/fss-kafka/`
- Values cho Strimzi operator (PSS restricted): `helm/values-operator.yaml`

Tóm tắt cài (chi tiết ở helm/README.md):
```bash
# 0. namespace + PSS labels
kubectl create namespace kafka
kubectl label namespace kafka pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted --overwrite
# 1. operator
helm repo add strimzi https://strimzi.io/charts/ && helm repo update
helm upgrade --install strimzi-operator strimzi/strimzi-kafka-operator -n kafka -f helm/values-operator.yaml
kubectl -n kafka rollout status deploy/strimzi-cluster-operator
# 2. cụm Kafka
helm upgrade --install fss-kafka helm/fss-kafka -n kafka
kubectl -n kafka wait kafka/fss-kafka --for=condition=Ready --timeout=600s
```
