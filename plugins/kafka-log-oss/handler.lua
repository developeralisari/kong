-- ==========================================================================
-- kafka-log-oss — Plugin Handler
--
-- Custom OSS Kafka log plugin for Kong.
-- Uses lua-resty-kafka (bundled with kong/kong-gateway image).
--
-- ÖNEMLİ: Bu plugin, aşağıdaki sorunları aşmak için özel bir pattern
-- kullanır. Üç ayrı hata bu pattern'i gerektirdi:
--
--   1. kong.request.* API'leri sadece access fazında çalışır.
--      → Çözüm: access'te topla, kong.ctx.shared'a yaz.
--
--   2. kong.response.* API'leri log fazında çalışmaz (bazı sürümlerde).
--      → Çözüm: body_filter'da topla.
--
--   3. lua-resty-kafka async producer, bp:send() içinde
--      ngx.timer.at(0, ...) çağırır (flush timer kurar). Bu çağrı
--      log fazında "API disabled in the context of log_by_lua*" hatası
--      verir.
--      → Çözüm: producer'ı access fazında pre-warm et, böylece
--      timer_running flag'i zaten true olur ve log'da timer kurmaya
--      gerek kalmaz.
--
-- Her adım ayrı pcall ile sarıldı — hata olursa tam olarak hangi
-- adımın patladığını log'a yazarız.
-- ==========================================================================

local cjson = require("cjson.safe")

-- ==========================================================================
-- PATCH: producer yüklenmeden ÖNCE ngx.log'u yakala
-- ==========================================================================
local original_ngx_log = ngx.log
ngx.log = function(level, ...)
    if level == ngx.ERR then
        local ok, str = pcall(table.concat, {...})
        if ok and str and str:find("err: closed, retryable: true", 1, true) then
            return -- Yut
        end
    end
    return original_ngx_log(level, ...)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Module cache temizliği
-- ══════════════════════════════════════════════════════════════════════════
-- lua-resty-kafka modülleri başında `local ngx_log = ngx.log` ile ngx.log'u
-- bir LOCAL değişkene cache'ler. Eğer bu modüller daha önce (Kong init_by_lua,
-- başka bir plugin, vs.) require edildiyse, Lua package.loaded'dan cache'lenmiş
-- modülü döndürür ve modül tekrar YÜKLENMEZ. Bu durumda modülün başındaki
-- `local ngx_log = ngx.log` satırı patch'ten ÖNCE çalışmış olur ve yukarıdaki
-- patch çalışmaz. Cache'i temizleyerek modülü yeniden yüklüyoruz.
-- ══════════════════════════════════════════════════════════════════════════
for _, mod in ipairs({
    "resty.kafka.producer",
    "resty.kafka.client",
    "resty.kafka.broker",
    "resty.kafka.ringbuffer",
    "resty.kafka.sendbuffer",
    "resty.kafka.request",
}) do
    package.loaded[mod] = nil
end

-- ŞİMDİ producer'ı yüklüyoruz — modül başındaki `local ngx_log = ngx.log`
-- artık patched ngx.log'u referans alacak
local producer = require("resty.kafka.producer")

-- ══════════════════════════════════════════════════════════════════════════
-- MONKEY-PATCH #1: request:new() — api_version'u zorla 2 yap
-- ══════════════════════════════════════════════════════════════════════════
-- KÖK NEDEN (source code analizi ile doğrulandı):
--
-- lua-resty-kafka/request.lua satır ~80:
--   function _M.new(self, apikey, correlation_id, client_id, api_version)
--       api_version = api_version or API_VERSION_V0  -- API_VERSION_V0 = 0
--
-- lua-resty-kafka/producer.lua produce_encode fonksiyonu:
--   local req = request:new(request.ProduceRequest,
--                           correlation_id(self), self.client.client_id, self.api_version)
--
-- Eğer self.api_version bir şekilde nil/false ise, request:new() içinde
-- api_version = nil or 0 = 0 olur. Kafka broker Produce API v0'ı desteklemez:
--   UnsupportedVersionException: Received request for api with key 0
--   (Produce) and unsupported version 0
--
-- EK SORUN: producer.lua'da cluster_inited cache'i var:
--   if async and cluster_inited[name] then
--       return cluster_inited[name]  -- producer_config YOK SAYILIR!
--   end
--
-- ÇÖZÜM: request:new() çağrıldığında api_version'u zorla 2 yap.
-- Bu EN ALT KATMAN — ne olursa olsun çalışır.
-- ══════════════════════════════════════════════════════════════════════════
local request_mod = require("resty.kafka.request")
local original_request_new = request_mod.new

request_mod.new = function(self, apikey, correlation_id, client_id, api_version)
    -- ProduceRequest (apikey=0) için api_version'u zorla en az 2 yap
    if apikey == request_mod.ProduceRequest then
        if not api_version or api_version < 2 then
            api_version = 2
        end
    end
    return original_request_new(self, apikey, correlation_id, client_id, api_version)
end


-- ══════════════════════════════════════════════════════════════════════════
-- MONKEY-PATCH #2: producer:new() — api_version'u zorla 2 yap
-- ══════════════════════════════════════════════════════════════════════════
-- producer:new() içinde:
--   api_version = opts.api_version or API_VERSION_V1  -- 1
-- satırı var. opts.api_version = nil ise 1 olur (0 değil, ama 1 de çalışmayabilir).
-- Ayrıca cluster_inited cache'i producer_config'i yok sayabilir.
-- ÇÖZÜM: producer:new() çağrıldığında producer_config.api_version'u zorla 2 yap.
-- ══════════════════════════════════════════════════════════════════════════
local producer_mod = require("resty.kafka.producer")
local original_producer_new = producer_mod.new

producer_mod.new = function(self, broker_list, producer_config, cluster_name)
    producer_config = producer_config or {}
    producer_config.api_version = 2  -- Zorla 2 yap
    return original_producer_new(self, broker_list, producer_config, cluster_name)
end


ngx.log(ngx.NOTICE, "[kafka-log-oss] HANDLER LOADED v2.0.0 (MONKEY-PATCH: request:new + producer:new → api_version=2 forced)")

-- ═══════════════════════════════════════════════════════════════════════════
-- Producer cache: her worker process için bootstrap_servers başına bir
-- producer tutar.
-- ═══════════════════════════════════════════════════════════════════════════
local producer_cache = {}

local function parse_brokers(servers)
  if not servers or servers == "" then
    return nil, "empty bootstrap_servers"
  end
  local list = {}
  for entry in string.gmatch(servers, "[^,]+") do
    local host, port = string.match(entry, "^%s*([^:]+):(%d+)%s*$")
    if host and port then
      table.insert(list, { host = host, port = tonumber(port) })
    else
      return nil, "invalid broker entry: " .. entry
    end
  end
  if #list == 0 then
    return nil, "no valid brokers parsed"
  end
  return list
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Producer al. İlk çağrıda oluşturur (timer kurulumu access phase'inde
-- yapılmış olmalı). pre-warmed=true ile erken uyarı verir.
-- ═══════════════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════════════
-- KRİTİK: api_version HARDCODED
-- ═══════════════════════════════════════════════════════════════════════════
-- Lua'da `0` TRUTHY'dir! Yani `conf.api_version or 2` ifadesi
-- conf.api_version = 0 iken `0 or 2 = 0` döndürür (2 DEĞİL).
-- Kong DB'deki eski plugin kaydında api_version = 0 olarak kayıtlı olabilir.
-- Bu durumda producer, Produce API version 0 kullanır ve modern Kafka (3.x+)
-- şu hatayı verir:
--   UnsupportedVersionException: Received request for api with key 0
--   (Produce) and unsupported version 0
-- ÇÖZÜM: api_version'u HARDCODED 2 yap. conf.api_version'a ASLA güvenme.
-- ═══════════════════════════════════════════════════════════════════════════
local HARDCODED_API_VERSION = 2

local function get_producer(conf)
  -- Cache key'e api_version ekle → eski (v0) producer otomatik invalidate olur
  local cache_key = conf.bootstrap_servers .. "|" .. conf.client_id .. "|v" .. HARDCODED_API_VERSION
  local cached = producer_cache[cache_key]
  if cached then
    return cached
  end

  local broker_list, err = parse_brokers(conf.bootstrap_servers)
  if not broker_list then
    return nil, err
  end

  local p, perr = producer:new(broker_list, {
    producer_type = "async",
    ["request.required.acks"] = conf.request_acks or 1,
    ["request.timeout.ms"] = conf.request_timeout_ms or 10000,
    ["queue.buffering.max.ms"] = conf.flush_timeout_ms or 1000,
    ["message.send.max.retries"] = conf.max_retries or 3,
    ["client.id"] = conf.client_id or "kong-kafka-log-oss",

    -- ═══════════════════════════════════════════════════════════════════════
    -- Socket keepalive ayarları (lua-resty-kafka client.lua beklenen isimler)
    -- ═══════════════════════════════════════════════════════════════════════
    -- keepalive_timeout (ms): sock:setkeepalive() timeout'u.
    --   ÖNEMLİ: Kafka broker'ın `connections.max.idle.ms` değerinden DÜŞÜK
    --   olmalı. Aksi halde Kafka, producer'dan ÖNCE idle bağlantıyı kapatır
    --   ve producer kapalı connection üzerinden mesaj göndermeye çalışarak
    --   "err: closed, retryable: true" hatası üretir.
    --   Kong handler: 480000ms (8dk)  <  Kafka: 540000ms (9dk)
    --
    -- keepalive_size: connection pool büyüklüğü (her broker için).
    --
    -- socket_timeout (ms): socket send/recv timeout (varsayılan 3000ms).
    -- ═══════════════════════════════════════════════════════════════════════
    keepalive_timeout = 480000,
    keepalive_size    = 10,
    socket_timeout    = 3000,

    -- ═══════════════════════════════════════════════════════════════════════
    -- KRİTİK: Produce API versiyonu — HARDCODED
    -- ═══════════════════════════════════════════════════════════════════════
    -- conf.api_version'a GÜVENME! Lua'da 0 truthy olduğu için
    -- `conf.api_version or 2` ifadesi conf.api_version=0 iken 0 döner.
    -- HARDCODED_API_VERSION = 2 (Kafka 0.10+ uyumlu, modern broker'larda çalışır)
    -- ═══════════════════════════════════════════════════════════════════════
    api_version = HARDCODED_API_VERSION,
  })

  if not p then
    return nil, perr
  end

  producer_cache[cache_key] = p
  ngx.log(ngx.NOTICE, "[kafka-log-oss] producer created: brokers=", conf.bootstrap_servers,
    " client_id=", conf.client_id, " api_version=", HARDCODED_API_VERSION, " (hardcoded)")
  return p
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Message key template substitution
-- ═══════════════════════════════════════════════════════════════════════════
local function resolve_key(template, vars)
  if not template or template == "" then
    return nil
  end
  local result = template
  for k, v in pairs(vars or {}) do
    if v then
      result = string.gsub(result, "{" .. k .. "}", tostring(v))
    end
  end
  return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Pure build_event — hiçbir kong.* çağrısı yok, sadece ngx.* ve ctx
-- ═══════════════════════════════════════════════════════════════════════════
local function build_event(ctx, conf)
  return {
    cluster      = conf.cluster_name or "uat",
    timestamp    = os.time(),
    timestamp_ms = ngx.now() * 1000,
    request_id   = ngx.var.kong_request_id or "unknown",

    request = {
      method         = ctx.method or ngx.var.request_method or "UNKNOWN",
      path           = ctx.path or ngx.var.uri or "",
      query          = ctx.query or ngx.var.args or "",
      client_ip      = ngx.var.remote_addr or "",
      user_agent     = ctx.headers and ctx.headers["user-agent"],
      content_type   = ctx.headers and ctx.headers["content-type"],
      content_length = ctx.headers and tonumber(ctx.headers["content-length"]) or 0,
      referer        = ctx.headers and ctx.headers["referer"],
    },

    route = {
      id   = ctx.route_id,
      name = ctx.route_name,
    },

    service = {
      id   = ctx.service_id,
      name = ctx.service_name,
      host = ctx.service_host,
    },

    consumer = ctx.consumer_id and {
      id       = ctx.consumer_id,
      username = ctx.consumer_username,
    } or nil,

    response = {
      status         = ctx.response_status or ngx.status or 0,
      content_length = ctx.response_content_length or 0,
    },

    latency = {
      request_ms = tonumber(ngx.var.request_time) and (tonumber(ngx.var.request_time) * 1000) or 0,
      proxy_ms   = tonumber(ngx.var.upstream_response_time) and (tonumber(ngx.var.upstream_response_time) * 1000) or 0,
    },

    upstream = {
      addr   = ngx.var.upstream_addr or nil,
      status = ngx.var.upstream_status or nil,
    },

    request_body_truncated  = false,
    response_body_truncated = false,
    request_body  = nil,
    response_body = nil,
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Plugin handler struct
-- ═══════════════════════════════════════════════════════════════════════════
local KafkaLogHandler = {
  PRIORITY = 1,
  VERSION = "2.0.0",
}

-- ──────────────────────────────────────────────────────────────────────────
-- ACCESS phase
--   - Request data topla (kong.request.* sadece burada çalışır)
--   - Route/Service/Consumer cache'le (log'da yasak olabilir)
--   - **Producer'ı pre-warm et** (timer kurulumu burada yapılır)
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:access(conf)
  local route = kong.router.get_route()
  local service = route and route.service
  local cred = kong.client.get_credential()

  local ctx = {
    method  = kong.request.get_method(),
    path    = kong.request.get_path(),
    query   = kong.request.get_raw_query(),
    headers = kong.request.get_headers(),

    route_id   = route and route.id or nil,
    route_name = route and route.name or nil,

    service_id   = service and service.id or nil,
    service_name = service and service.name or nil,
    service_host = service and service.host or nil,

    consumer_id       = cred and cred.consumer and cred.consumer.id or nil,
    consumer_username = cred and cred.consumer and cred.consumer.username or nil,
  }

  if conf.log_request_body then
    if ctx.method == "POST" or ctx.method == "PUT" or ctx.method == "PATCH" then
      local body = kong.request.get_raw_body()
      if body and body ~= "" then
        ctx.body = body
      end
    end
  end

  kong.ctx.shared.kafka_log_oss = ctx

  -- Pre-warm producer (timer kurulumu access phase'inde)
  local bp, perr = get_producer(conf)
  if not bp then
    ngx.log(ngx.ERR, "[kafka-log-oss] producer pre-warm FAILED: ", tostring(perr))
  else
    ngx.log(ngx.NOTICE, "[kafka-log-oss] producer pre-warmed in access phase")
  end
end

-- ──────────────────────────────────────────────────────────────────────────
-- BODY_FILTER phase: response header + body topla
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:body_filter(conf)
  local ctx = kong.ctx.shared.kafka_log_oss
  if not ctx then
    return
  end

  if not ctx.response_headers_captured then
    ctx.response_status = kong.response.get_status()
    ctx.response_content_length = tonumber(kong.response.get_header("content-length")) or 0
    ctx.response_headers_captured = true
  end

  if conf.log_response_body then
    local chunk = ngx.arg[1]
    if chunk and chunk ~= "" then
      ctx.response_body = (ctx.response_body or "") .. chunk
    end
  end
end

-- ──────────────────────────────────────────────────────────────────────────
-- LOG phase: HER ADIM AYRI PCALL İLE
-- Hangi adım patladıysa onu net log'larız
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:log(conf)
  local ctx = kong.ctx.shared.kafka_log_oss or {}

  -- Adım 1: Event'i oluştur
  local ok1, event_or_err = pcall(build_event, ctx, conf)
  if not ok1 then
    ngx.log(ngx.ERR, "[kafka-log-oss] build_event FAILED: ", tostring(event_or_err))
    return
  end
  local event = event_or_err

  -- Request body ekle (access'te yakalanmışsa)
  if conf.log_request_body and ctx.body and ctx.body ~= "" then
    local max_size = conf.max_request_body_size or 8192
    if #ctx.body > max_size then
      event.request.body_truncated = true
      event.request.body = string.sub(ctx.body, 1, max_size)
    else
      event.request.body = ctx.body
    end
  end

  -- Response body ekle (body_filter'da biriktirilmişse)
  if conf.log_response_body and ctx.response_body and ctx.response_body ~= "" then
    local max_size = conf.max_response_body_size or 8192
    if #ctx.response_body > max_size then
      event.response.body_truncated = true
      event.response.body = string.sub(ctx.response_body, 1, max_size)
    else
      event.response.body = ctx.response_body
    end
  end

  -- Adım 2: JSON encode
  local ok2, payload_or_err = pcall(cjson.encode, event)
  if not ok2 then
    ngx.log(ngx.ERR, "[kafka-log-oss] cjson.encode FAILED: ", tostring(payload_or_err))
    return
  end
  local payload = payload_or_err

  -- Adım 3: Producer al (pre-warmed olmalı, ama yine de kontrol)
  local bp, perr = get_producer(conf)
  if not bp then
    if conf.log_send_errors ~= false then
      ngx.log(ngx.ERR, "[kafka-log-oss] producer init FAILED: ", tostring(perr))
    end
    return
  end

  -- Adım 4: Message key
  local ok4, key_or_err = pcall(resolve_key, conf.message_key, {
    request_id  = event.request_id,
    client_ip   = event.request and event.request.client_ip or "",
    path        = event.request and event.request.path or "",
    consumer_id = event.consumer and event.consumer.id or "",
  })
  if not ok4 then
    ngx.log(ngx.ERR, "[kafka-log-oss] resolve_key FAILED: ", tostring(key_or_err))
    return
  end
  local key = key_or_err

  -- Adım 5: Kafka'ya gönder (bu adım en şüpheli — ngx.timer.at tetikler)
  -- NOT: conf.kafka_headers argümanını kaldırdık, çünkü lua-resty-kafka'nın
  -- bazı versiyonları headers beklerken boş table {} gelince paketi bozabilir
  -- ve Kafka broker'ın bağlantıyı anında kapatmasına (err: closed) sebep olabilir.
  local ok5, ok_send, err_send = pcall(bp.send, bp, conf.topic, key, payload)
  if not ok5 then
    ngx.log(ngx.ERR, "[kafka-log-oss] send PCALL FAILED: ", tostring(ok_send))
    return
  end
  if not ok_send then
    if conf.log_send_errors ~= false then
      ngx.log(ngx.ERR, "[kafka-log-oss] send returned err: topic=", conf.topic,
        " err=", tostring(err_send))
    end
  end
end

return KafkaLogHandler
