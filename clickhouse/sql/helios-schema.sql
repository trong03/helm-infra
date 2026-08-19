-- ============================================================================
-- helios-schema.sql — schema Helios trên ClickHouse HA (cluster 'fss')
--
-- Thiết kế "future-safe": app LUÔN đọc/ghi qua bảng Distributed `orders`.
-- Giờ 1 shard x 2 replica -> vẫn chạy đúng. Sau lên 3 shard x 2 replica (6 node)
-- CHỈ đổi values.yaml (shardsCount: 3) + helm upgrade, KHÔNG sửa dòng code app nào.
--
-- Chạy 1 lần (DDL propagate cả cụm nhờ ON CLUSTER):
--   kubectl -n clickhouse exec -it <chi-pod> -- clickhouse-client --multiquery < helios-schema.sql
-- hoặc qua service:
--   clickhouse-client -h clickhouse-fss-clickhouse.clickhouse.svc --port 9000 \
--     -u app_helios --password "$PW" --multiquery < helios-schema.sql
--
-- 'fss' = clickhouse.clusterName trong values.yaml. Đổi 2 chỗ nếu bạn đổi tên cluster.
-- ============================================================================

-- 1) Database (ON CLUSTER -> tạo trên mọi node)
CREATE DATABASE IF NOT EXISTS helios ON CLUSTER 'fss';

-- 2) BẢNG DỮ LIỆU THẬT (Replicated) — đây là chỗ HA nằm.
--    ReplicatedMergeTree dạng ngắn: operator đã set default_replica_path/name qua macros
--    {shard}/{replica} nên KHÔNG cần truyền path Keeper tường minh.
CREATE TABLE IF NOT EXISTS helios.orders_local ON CLUSTER 'fss'
(
    order_id    UInt64,
    account_id  UInt64,
    symbol      LowCardinality(String),
    side        Enum8('BUY' = 1, 'SELL' = 2),
    qty         UInt32,
    price       Decimal(18, 2),
    event_time  DateTime64(3),
    -- audit columns theo chuẩn Helios lakehouse
    _loaded_at      DateTime DEFAULT now(),
    _source_system  LowCardinality(String) DEFAULT 'orders-events'
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)          -- partition theo tháng: prune nhanh + drop tháng cũ rẻ
ORDER BY (account_id, event_time)          -- primary/sort key: query theo account + thời gian
TTL toDateTime(event_time) + INTERVAL 3 YEAR DELETE;   -- giữ 3 năm (chỉnh theo quy định lưu trữ)

-- 3) BẢNG TRUY VẤN (Distributed) — điểm vào DUY NHẤT cho app.
--    Không chứa data; chỉ route đọc/ghi xuống orders_local trên các shard.
--    Shard key cityHash64(account_id): cùng account -> cùng shard (JOIN/GROUP local nhanh,
--    phân tán đều). Giờ 1 shard nên mọi dòng về shard 0; khi 3 shard sẽ tự rải.
CREATE TABLE IF NOT EXISTS helios.orders ON CLUSTER 'fss'
AS helios.orders_local
ENGINE = Distributed('fss', helios, orders_local, cityHash64(account_id));

-- ============================================================================
-- CÁCH APP DÙNG (luôn qua helios.orders — KHÔNG đụng orders_local)
-- ============================================================================
-- GHI:  INSERT INTO helios.orders (order_id, account_id, symbol, side, qty, price, event_time)
--       VALUES (...);
-- ĐỌC:  SELECT symbol, sum(qty) FROM helios.orders WHERE event_time >= today() GROUP BY symbol;
--
-- Distributed tự: khi ghi -> đẩy về đúng shard; khi đọc -> gom mọi shard rồi ghép.

-- ============================================================================
-- DỮ LIỆU SYNTHETIC để smoke-test (XOÁ trước prod — KHÔNG dùng data khách hàng thật)
-- ============================================================================
-- INSERT INTO helios.orders (order_id, account_id, symbol, side, qty, price, event_time) VALUES
--   (1001, 88001, 'FPT', 'BUY',  100, 92500.00, '2026-07-27 09:15:00.123'),
--   (1002, 88002, 'VNM', 'SELL',  50, 61000.00, '2026-07-27 09:15:02.456'),
--   (1003, 88001, 'HPG', 'BUY',  200, 28000.00, '2026-07-27 09:16:10.000');
--
-- SELECT symbol, sum(qty) AS total_qty FROM helios.orders GROUP BY symbol ORDER BY symbol;
