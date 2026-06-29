-- ==========================================================================
-- kafka-log-oss — Plugin Schema
--
-- Custom OSS Kafka log plugin for Kong (Kong Gateway image).
-- Replaces the Enterprise-only `kafka-log` plugin.
-- Uses lua-resty-kafka (bundled with kong/kong-gateway image).
--
-- All config fields are dynamic: editable from Kong Admin UI / Admin API
-- at runtime. No restart needed when changing values.
--
-- Schema format (Kong 3.9 metaschema):
--   Outer `fields` is always an ARRAY (each element `{ name = def }`).
--   Inner `fields` for record/array/map values is also an ARRAY.
-- ==========================================================================

return {
  name = "kafka-log-oss",
  fields = {
    { config = {
        type = "record",
        fields = {

          -- ═══════════════════════════════════════════════════════════════
          -- A. CONNECTION — Kafka broker'a nasıl bağlanacağı
          -- ═══════════════════════════════════════════════════════════════

          -- 1. Bootstrap servers (csv, host:port formatında)
          { bootstrap_servers = {
              type = "string",
              required = true,
              description = "Comma-separated Kafka broker list, e.g. 'kafka:9092' or 'kafka-1:9092,kafka-2:9092'.",
          } },

          -- 2. Topic adı (auto-create KAFKA_AUTO_CREATE_TOPICS_ENABLE=true ile açık)
          { topic = {
              type = "string",
              required = true,
              description = "Kafka topic name. Auto-created if KAFKA_AUTO_CREATE_TOPICS_ENABLE=true on broker.",
          } },

          -- 3. Client ID (Kafka broker tarafında görünür)
          { client_id = {
              type = "string",
              default = "kong-kafka-log-oss",
              description = "Kafka producer client.id (visible in broker logs/metrics).",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- B. SERIALIZATION — Mesaj formatı
          -- ═══════════════════════════════════════════════════════════════

          -- 4. Mesaj formatı (şimdilik sadece JSON, ileride protobuf/avro eklenebilir)
          { format = {
              type = "string",
              default = "json",
              one_of = { "json" },
              description = "Message serialization format. JSON for now.",
          } },

          -- 5. Cluster adı (her log event'inde 'cluster' field'ı olarak yazılır)
          { cluster_name = {
              type = "string",
              default = "uat",
              description = "Cluster identifier written to every log event under 'cluster' field.",
          } },

          -- 6. Service identifier (multi-tenant ortamlar için)
          { service_id = {
              type = "string",
              default = "",
              len_min = 0,
              description = "Service identifier written to every log event under 'service_id'. Useful for multi-tenant setups.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- C. MESSAGE KEY — Kafka partitioning
          -- ═══════════════════════════════════════════════════════════════

          -- 7. Message key template (placeholders: {request_id}, {client_ip}, {path}, {consumer_id})
          { message_key = {
              type = "string",
              default = "",
              len_min = 0,
              description = "Kafka message key template. Supports placeholders: {request_id}, {client_ip}, {path}, {consumer_id}. Empty = null key (round-robin partition).",
          } },

          -- 8. Kafka message headers (record-level metadata, not HTTP headers)
          { kafka_headers = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              default = {},
              description = "Static Kafka message headers (record-level metadata). Useful for routing/filtering in Kafka consumers.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- D. BODY CAPTURE — Hassas, throughput'a etki eder
          -- ═══════════════════════════════════════════════════════════════

          -- 9. Request body logla
          { log_request_body = {
              type = "boolean",
              default = false,
              description = "Include HTTP request body in the log event. WARNING: increases memory usage, disable for high-throughput routes.",
          } },

          -- 10. Response body logla
          { log_response_body = {
              type = "boolean",
              default = false,
              description = "Include HTTP response body in the log event. WARNING: may not capture streaming responses reliably.",
          } },

          -- 11. Max request body size (bytes)
          { max_request_body_size = {
              type = "number",
              default = 8192,
              description = "Maximum bytes to capture from request body (when log_request_body=true). Truncated beyond this.",
          } },

          -- 12. Max response body size (bytes)
          { max_response_body_size = {
              type = "number",
              default = 8192,
              description = "Maximum bytes to capture from response body (when log_response_body=true). Truncated beyond this.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- E. PRODUCER TUNING
          -- ═══════════════════════════════════════════════════════════════

          -- 13. Acks (0=no ack, 1=leader only, -1=all replicas)
          { request_acks = {
              type = "number",
              default = 1,
              one_of = { 0, 1, -1 },
              description = "Producer acks: 0=fire-and-forget, 1=leader-only, -1=all in-sync replicas.",
          } },

          -- 14. Request timeout (ms)
          { request_timeout_ms = {
              type = "number",
              default = 10000,
              description = "Kafka producer request.timeout.ms (broker ack timeout).",
          } },

          -- 15. Buffer flush interval (ms) — bu sürede birikmiş mesajlar flush edilir
          { flush_timeout_ms = {
              type = "number",
              default = 1000,
              description = "Kafka producer queue.buffering.max.ms. How often buffered messages are flushed to broker.",
          } },

          -- 16. Max retries
          { max_retries = {
              type = "number",
              default = 3,
              description = "Producer message.send.max.retries on transient failures.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- F. CUSTOM FIELDS — Operasyonel ek metadata
          -- ═══════════════════════════════════════════════════════════════

          -- 17. Custom key-value (her event'e yazılır, düşük kartelı tag'ler için)
          { custom_fields = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              default = {},
              description = "Static key-value pairs added to every log event under 'custom'. Example: {env='uat', team='platform'}.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- G. ERROR HANDLING — Başarısız gönderimler
          -- ═══════════════════════════════════════════════════════════════

          -- 18. Failed sends → Kong error log'a yazılsın mı
          { log_send_errors = {
              type = "boolean",
              default = true,
              description = "If true, failed Kafka sends are written to Kong's error log. If false, silently dropped.",
          } },

        },
    } },
  },
}
