-- ==========================================================================
-- kafka-log-oss — Plugin Handler
--
-- Custom OSS Kafka log plugin for Kong.
-- Uses lua-resty-kafka (bundled with kong/kong-gateway image).
-- Runs in log phase (after response sent to client) so it never blocks
-- upstream latency.
--
-- All config fields are dynamic — reloaded from DB on every request.
-- Schema defined in schema.lua.
-- ==========================================================================

local cjson = require("cjson.safe")
local producer = require("resty.kafka.producer")

-- Module load marker: eğer bu görünüyorsa Kong yeni kodu yükledi demektir
ngx.log(ngx.NOTICE, "[kafka-log-oss] HANDLER LOADED v1.0.0")

-- ═══════════════════════════════════════════════════════════════════════════
-- Producer cache: her worker process için bootstrap_servers başına bir
-- producer tutar. Aynı broker'a sahip 1000 route aynı producer'ı paylaşır.
-- Worker restart (reload) olunca cache sıfırlanır — sorun değil, async
-- producer'lar zaten state-less.
-- ═══════════════════════════════════════════════════════════════════════════
local producer_cache = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Body capture hard limit. log_request_body / log_response_body açıksa
-- body'nin bu kadar byte'ı log'a yazılır, aşan kısım kesilir.
--
-- 10 MB seçildi çünkü:
--   - KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE (varsayılan 10-20 MB) seviyesinde,
--     yani pratikte "limitsiz" — istek zaten bundan büyük gelemez
--   - KAFKA_MESSAGE_MAX_BYTES (16 MB) altında — diğer event alanları
--     (request, response header'ları, vs.) için yer kalır
--   - Operatörün ayarlaması gerekmiyor, çakışma/yanlış konfigürasyon riski yok
--
-- DEĞİŞTİRMEK İÇİN: Bu sabit değeri değiştir ve yeni bir container image
-- build et. Runtime'da override EDİLEMEZ (schema'da alan yok).
-- ═══════════════════════════════════════════════════════════════════════════
local MAX_BODY_CAPTURE_BYTES = 10 * 1024 * 1024  -- 10 MB

-- ═══════════════════════════════════════════════════════════════════════════
-- bootstrap_servers string → {{host=, port=}, ...} array dönüşümü
-- Geçersiz format → nil + hata mesajı
-- ═══════════════════════════════════════════════════════════════════════════
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
-- Cache'lenmiş producer al (worker process başına bir tane)
-- ═══════════════════════════════════════════════════════════════════════════
local function get_producer(conf)
  local cache_key = conf.bootstrap_servers .. "|" .. conf.client_id
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
  })

  if not p then
    return nil, perr
  end

  producer_cache[cache_key] = p
  ngx.log(ngx.NOTICE, "[kafka-log-oss] producer created: brokers=", conf.bootstrap_servers,
    " client_id=", conf.client_id)
  return p
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Message key template substitution
-- Desteklenen placeholder'lar: {request_id}, {client_ip}, {path}, {consumer_id}
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
-- Log event'ini serialize et
-- Bu obje JSON olarak Kafka'ya yazılır
-- ═══════════════════════════════════════════════════════════════════════════
local function build_event(conf)
  local route = kong.router.get_route()
  local service = route and route.service
  local cred = kong.client.get_credential()

  local event = {
    cluster = conf.cluster_name or "uat",
    service_id = conf.service_id or "",
    timestamp = os.time(),
    timestamp_ms = ngx.now() * 1000,
    request_id = ngx.var.kong_request_id or "unknown",

    request = {
      method = kong.request.get_method(),
      path = kong.request.get_path(),
      query = kong.request.get_raw_query(),
      client_ip = kong.client.get_ip(),
      user_agent = kong.request.get_header("user-agent"),
      content_type = kong.request.get_header("content-type"),
      content_length = tonumber(kong.request.get_header("content-length")) or 0,
      referer = kong.request.get_header("referer"),
    },

    route = {
      id = route and route.id or nil,
      name = route and route.name or nil,
    },

    service = {
      id = service and service.id or nil,
      name = service and service.name or nil,
      host = service and service.host or nil,
    },

    consumer = cred and cred.consumer and {
      id = cred.consumer.id,
      username = cred.consumer.username,
    } or nil,

    response = {
      status = kong.response.get_status(),
      content_length = tonumber(kong.response.get_header("content-length")) or 0,
    },

    latency = {
      request_ms = tonumber(ngx.var.request_time) and (tonumber(ngx.var.request_time) * 1000) or 0,
      proxy_ms = tonumber(ngx.var.upstream_response_time) and (tonumber(ngx.var.upstream_response_time) * 1000) or 0,
    },

    upstream = {
      addr = ngx.var.upstream_addr or nil,
      status = ngx.var.upstream_status or nil,
    },

    custom = conf.custom_fields or {},
  }

  -- İsteğe bağlı: request body
  if conf.log_request_body then
    local body = kong.request.get_raw_body()
    if body and body ~= "" then
      if #body > MAX_BODY_CAPTURE_BYTES then
        event.request.body_truncated = true
        event.request.body = string.sub(body, 1, MAX_BODY_CAPTURE_BYTES)
      else
        event.request.body = body
      end
    end
  end

  -- İsteğe bağlı: response body
  if conf.log_response_body then
    local body = kong.service.response.get_raw_body()
    if body and body ~= "" then
      if #body > MAX_BODY_CAPTURE_BYTES then
        event.response.body_truncated = true
        event.response.body = string.sub(body, 1, MAX_BODY_CAPTURE_BYTES)
      else
        event.response.body = body
      end
    end
  end

  return event
end

local KafkaLogHandler = {
  PRIORITY = 1,    -- log phase'inde en son çalışsın (response çoktan gönderildi)
  VERSION = "1.0.0",
}

function KafkaLogHandler:log(conf)
  local ok, err = pcall(function()
    local event = build_event(conf)
    local payload, jerr = cjson.encode(event)
    if not payload then
      ngx.log(ngx.ERR, "[kafka-log-oss] cjson.encode FAILED: ", tostring(jerr))
      return
    end

    local bp, perr = get_producer(conf)
    if not bp then
      if conf.log_send_errors ~= false then
        ngx.log(ngx.ERR, "[kafka-log-oss] producer init FAILED: ", tostring(perr))
      end
      return
    end

    -- Message key
    local key = resolve_key(conf.message_key, {
      request_id = event.request_id,
      client_ip = event.request and event.request.client_ip or "",
      path = event.request and event.request.path or "",
      consumer_id = event.consumer and event.consumer.id or "",
    })

    -- Async send (fire-and-forget: blocking yapmaz)
    local serr
    if key and key ~= "" then
      serr = bp:send(conf.topic, key, payload, conf.kafka_headers)
    else
      serr = bp:send(conf.topic, nil, payload, conf.kafka_headers)
    end

    if serr and conf.log_send_errors ~= false then
      ngx.log(ngx.ERR, "[kafka-log-oss] send FAILED topic=", conf.topic,
        " err=", tostring(serr))
    end
  end)

  if not ok then
    ngx.log(ngx.ERR, "[kafka-log-oss] log phase ERROR: ", tostring(err))
  end
end

return KafkaLogHandler
