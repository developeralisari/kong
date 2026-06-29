-- ==========================================================================
-- kafka-log-oss — Plugin Handler
--
-- Custom OSS Kafka log plugin for Kong.
-- Uses lua-resty-kafka (bundled with kong/kong-gateway image).
-- Sends events in log phase (after response sent to client) so it never
-- blocks upstream latency.
--
-- PHASE STRATEGY (KATIK KURAL):
--   LOG PHASE'INDE HİÇBİR kong.* API'Sİ ÇAĞRILMAZ.
--   Nedeni: globalpatches.lua her kong.* çağrısında faz kontrolü yapar;
--   birçoğu (kong.request.*, kong.client.get_credential, vb.) log fazında
--   "API disabled in the context of log_by_lua*" fırlatır. Hangi sürümde
--   hangi API'nin yasaklandığı net değil, dolayısıyla en güvenli yol
--   hiç çağırmamak.
--
--   :access       — Tüm kong.* çağrılarını burada yap:
--                     kong.request.*, kong.router.*, kong.client.*
--                   Sonuçları kong.ctx.shared.kafka_log_oss'a yaz.
--   :body_filter  — Response header + body'yi topla:
--                     kong.response.get_status / get_header (body_filter'da OK)
--                     response body chunk'larını biriktir
--   :log          — YALNIZCA:
--                     ngx.var.*, ngx.status, ngx.now(), os.time()
--                     cjson.encode
--                     kong.ctx.shared.kafka_log_oss (access'te yazdığımız)
--                     producer:send (lua-resty-kafka)
-- ==========================================================================

local cjson = require("cjson.safe")
local producer = require("resty.kafka.producer")

ngx.log(ngx.NOTICE, "[kafka-log-oss] HANDLER LOADED v1.2.0 (zero kong.* in log phase)")

-- ═══════════════════════════════════════════════════════════════════════════
-- Producer cache: her worker process için bootstrap_servers başına bir
-- producer tutar. Aynı broker'a sahip 1000 route aynı producer'ı paylaşır.
-- Worker restart (reload) olunca cache sıfırlanır — sorun değil, async
-- producer'lar zaten state-less.
-- ═══════════════════════════════════════════════════════════════════════════
local producer_cache = {}

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
-- Plugin handler struct
-- ═══════════════════════════════════════════════════════════════════════════
local KafkaLogHandler = {
  PRIORITY = 1,
  VERSION = "1.2.0",
}

-- ──────────────────────────────────────────────────────────────────────────
-- ACCESS phase: HER ŞEYİ burada topla, log phase'ine hazır paket bırak
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:access(conf)
  local route = kong.router.get_route()
  local service = route and route.service
  local cred = kong.client.get_credential()

  local ctx = {
    -- Request
    method  = kong.request.get_method(),
    path    = kong.request.get_path(),
    query   = kong.request.get_raw_query(),
    headers = kong.request.get_headers(),

    -- Route (cached for log phase)
    route_id   = route and route.id or nil,
    route_name = route and route.name or nil,

    -- Service (cached for log phase)
    service_id   = service and service.id or nil,
    service_name = service and service.name or nil,
    service_host = service and service.host or nil,

    -- Consumer (cached for log phase — kong.client.get_credential log'da yasak)
    consumer_id       = cred and cred.consumer and cred.consumer.id or nil,
    consumer_username = cred and cred.consumer and cred.consumer.username or nil,
  }

  -- Request body (eager capture — yalnızca log_request_body=true olduğunda)
  if conf.log_request_body then
    local body = kong.request.get_raw_body()
    if body and body ~= "" then
      ctx.body = body
    end
  end

  kong.ctx.shared.kafka_log_oss = ctx
end

-- ──────────────────────────────────────────────────────────────────────────
-- BODY_FILTER phase: response header + body topla
-- kong.response.* API'leri bu fazda çalışır (header_filter, body_filter, log).
-- Body_filter'da topluyoruz çünkü log phase'inde body buffer recycle edilmiş.
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:body_filter(conf)
  local ctx = kong.ctx.shared.kafka_log_oss
  if not ctx then
    return
  end

  -- Response header'ları ilk chunk'te bir kez yakala
  if not ctx.response_headers_captured then
    ctx.response_status = kong.response.get_status()
    ctx.response_content_length = tonumber(kong.response.get_header("content-length")) or 0
    ctx.response_headers_captured = true
  end

  -- Response body chunk'larını biriktir (sadece log_response_body=true)
  if conf.log_response_body then
    local chunk = ngx.arg[1]
    if chunk and chunk ~= "" then
      ctx.response_body = (ctx.response_body or "") .. chunk
    end
  end
end

-- ──────────────────────────────────────────────────────────────────────────
-- LOG phase: Kafka'ya gönder — SIFIR kong.* çağrısı
-- Tek istisna: ngx.var.* (her zaman OK), ngx.status, ngx.now(), producer.send
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:log(conf)
  local ctx = kong.ctx.shared.kafka_log_oss or {}

  local ok, err = pcall(function()
    local event = {
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
    }

    -- Request body (access'te yakalanmışsa)
    if conf.log_request_body and ctx.body and ctx.body ~= "" then
      local max_size = conf.max_request_body_size or 8192
      if #ctx.body > max_size then
        event.request.body_truncated = true
        event.request.body = string.sub(ctx.body, 1, max_size)
      else
        event.request.body = ctx.body
      end
    end

    -- Response body (body_filter'da biriktirilmişse)
    if conf.log_response_body and ctx.response_body and ctx.response_body ~= "" then
      local max_size = conf.max_response_body_size or 8192
      if #ctx.response_body > max_size then
        event.response.body_truncated = true
        event.response.body = string.sub(ctx.response_body, 1, max_size)
      else
        event.response.body = ctx.response_body
      end
    end

    -- JSON serialize
    local payload, jerr = cjson.encode(event)
    if not payload then
      ngx.log(ngx.ERR, "[kafka-log-oss] cjson.encode FAILED: ", tostring(jerr))
      return
    end

    -- Producer init
    local bp, perr = get_producer(conf)
    if not bp then
      if conf.log_send_errors ~= false then
        ngx.log(ngx.ERR, "[kafka-log-oss] producer init FAILED: ", tostring(perr))
      end
      return
    end

    -- Message key
    local key = resolve_key(conf.message_key, {
      request_id  = event.request_id,
      client_ip   = event.request and event.request.client_ip or "",
      path        = event.request and event.request.path or "",
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
