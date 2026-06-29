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
--
-- Description metinleri Türkçedir — Admin UI'da alan adının yanındaki info
-- ikonunda tooltip olarak görünür. one_of / default değerlerine dokunma,
-- bunlar programatik değerlerdir (UI dropdown'unda da aynen görünür).
-- ==========================================================================

return {
  name = "kafka-log-oss",
  fields = {
    { config = {
        type = "record",
        fields = {

          -- ═══════════════════════════════════════════════════════════════
          -- A. BAĞLANTI — Kafka broker'a nasıl bağlanılacağı
          -- ═══════════════════════════════════════════════════════════════

          -- 1. Bootstrap servers (virgülle ayrılmış host:port listesi)
          { bootstrap_servers = {
              type = "string",
              required = true,
              description = "Virgülle ayrılmış Kafka broker listesi. Örn: 'kafka:9092' veya 'kafka-1:9092,kafka-2:9092'. Docker compose ağındaki servis adını kullan (ör. 'kafka').",
          } },

          -- 2. Topic adı (broker tarafında auto-create açıksa otomatik oluşur)
          { topic = {
              type = "string",
              required = true,
              description = "Mesajların yazılacağı Kafka topic adı. Broker'da KAFKA_AUTO_CREATE_TOPICS_ENABLE=true ise ilk mesajla birlikte otomatik oluşturulur. Örn: 'kong-access-logs'.",
          } },

          -- 3. Client ID (Kafka broker tarafında görünür)
          { client_id = {
              type = "string",
              default = "kong-kafka-log-oss",
              description = "Kafka producer client.id değeri. Broker log'larında ve metriklerde bu isimle görünür, debug için faydalıdır.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- B. SERİLEŞTİRME — Mesaj formatı
          -- ═══════════════════════════════════════════════════════════════

          -- 4. Mesaj formatı (şimdilik sadece JSON)
          { format = {
              type = "string",
              default = "json",
              one_of = { "json" },
              description = "Mesaj serileştirme formatı. Şimdilik tek desteklenen değer 'json' — Kafka'ya her event JSON string olarak yazılır.",
          } },

          -- 5. Cluster adı
          { cluster_name = {
              type = "string",
              default = "uat",
              description = "Her log event'inde 'cluster' alanı altına yazılan cluster tanımlayıcısı. Birden fazla ortamdan (dev/uat/prod) aynı Kafka'ya log yazıyorsan ayırt etmek için kullan.",
          } },

          -- 6. Service identifier (multi-tenant ortamlar için)
          { service_id = {
              type = "string",
              default = "",
              len_min = 0,
              description = "Her log event'inde 'service_id' alanı altına yazılan servis tanımlayıcısı. Aynı gateway'den birden fazla downstream servise log yazıyorsan ayırt etmek için kullan. Boş bırakılırsa yazılmaz.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- C. MESSAGE KEY — Kafka partitioning
          -- ═══════════════════════════════════════════════════════════════

          -- 7. Message key template
          { message_key = {
              type = "string",
              default = "",
              len_min = 0,
              description = "Kafka mesaj key şablonu. Aynı key'e sahip mesajlar aynı partition'a düşer (sıralama korunur). Desteklenen placeholder'lar: {request_id}, {client_ip}, {path}, {consumer_id}. Boş bırakırsan key null olur ve round-robin partition yapılır.",
          } },

          -- 8. Kafka message headers (record-level metadata, HTTP header'ı DEĞİL)
          { kafka_headers = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              default = {},
              description = "Statik Kafka record header'ları. HTTP header'larıyla karıştırma — bunlar Kafka consumer'ların göreceği record seviyesinde metadata'dır. Consumer tarafında routing/filtreleme için kullanışlıdır. Örn: {source='kong', team='platform'}.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- D. BODY YAKALAMA — Hassas, throughput'a etki eder
          -- ═══════════════════════════════════════════════════════════════

          -- 9. Request body logla
          { log_request_body = {
              type = "boolean",
              default = false,
              description = "HTTP istek body'sini log event'ine dahil et. UYARI: LLM isteklerinde base64 image'lar büyük olduğu için bellek kullanımını ciddi artırır. Yüksek-throughput route'lar için kapalı tut, sadece debug için aç.",
          } },

          -- 10. Response body logla
          { log_response_body = {
              type = "boolean",
              default = false,
              description = "HTTP yanıt body'sini log event'ine dahil et. UYARI: Streaming response'larda (Server-Sent Events, chunked) body güvenilir şekilde yakalanamayabilir, kısmi içerik yazılabilir. LLM streaming response'larını loglamak için uygun değil.",
          } },

          -- 11. Max request body size (bytes)
          { max_request_body_size = {
              type = "number",
              default = 8192,
              description = "İstek body'sinden yakalanacak maksimum byte (log_request_body=true olduğunda). Bu değeri aşan kısımlar kesilir ve event'e 'body_truncated: true' alanı eklenir. Varsayılan 8192 byte (8 KB) çoğu JSON isteği için yeterli.",
          } },

          -- 12. Max response body size (bytes)
          { max_response_body_size = {
              type = "number",
              default = 8192,
              description = "Yanıt body'sinden yakalanacak maksimum byte (log_response_body=true olduğunda). Bu değeri aşan kısımlar kesilir ve event'e 'body_truncated: true' alanı eklenir.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- E. PRODUCER AYARLARI
          -- ═══════════════════════════════════════════════════════════════

          -- 13. Acks (güvenilirlik seviyesi)
          { request_acks = {
              type = "number",
              default = 1,
              one_of = { 0, 1, -1 },
              description = "Producer'ın gönderdiği mesaj için broker'dan bekleyeceği onay seviyesi. 0=fire-and-forget (en hızlı, veri kaybı riski), 1=sadece leader replica yazsın (önerilen, iyi denge), -1=tüm in-sync replica'lar yazsın (en güvenli, en yavaş).",
          } },

          -- 14. Request timeout (ms)
          { request_timeout_ms = {
              type = "number",
              default = 10000,
              description = "Producer'ın broker ack'ı için bekleyeceği maksimum süre (milisaniye). Bu süre içinde onay gelmezse gönderim başarısız sayılır ve max_retries uygulanır.",
          } },

          -- 15. Buffer flush interval (ms)
          { flush_timeout_ms = {
              type = "number",
              default = 1000,
              description = "Buffer'da birikmiş mesajların broker'a gönderilme aralığı (milisaniye). Düşük değer = düşük gecikme, yüksek değer = daha iyi throughput (batch'leme avantajı). Varsayılan 1000ms çoğu kullanım için uygun.",
          } },

          -- 16. Max retries
          { max_retries = {
              type = "number",
              default = 3,
              description = "Geçici hatalarda (broker timeout, leader değişimi vs.) producer'ın mesajı tekrar gönderme denemesi sayısı. Tüm denemeler başarısız olursa event log_send_errors'a göre error log'a yazılır veya sessizce düşürülür.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- F. CUSTOM FIELDS — Operasyonel ek metadata
          -- ═══════════════════════════════════════════════════════════════

          -- 17. Custom key-value
          { custom_fields = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              default = {},
              description = "Her log event'inde 'custom' altına statik olarak eklenen key-value çiftleri. Operasyonel tag'ler için idealdir. Örn: {env='uat', team='platform', cost_center='engineering'}.",
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- G. HATA YÖNETİMİ — Başarısız gönderimler
          -- ═══════════════════════════════════════════════════════════════

          -- 18. Failed sends → Kong error log'a yazılsın mı
          { log_send_errors = {
              type = "boolean",
              default = true,
              description = "true ise: Kafka'ya gönderilemeyen mesajlar (broker çöktü, timeout, vs.) Kong error log'una yazılır — operasyonel görünürlük sağlar. false ise: sessizce düşürülür, log kirliliği olmaz ama hatalar görünmez. Genelde true önerilir.",
          } },

        },
    } },
  },
}
