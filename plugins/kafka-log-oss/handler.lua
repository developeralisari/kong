-- ==========================================================================
-- kafka-log-oss — Plugin Handler
--
-- Custom OSS Kafka log plugin for Kong.
-- Uses lua-resty-kafka (bundled with kong/kong-gateway image).
-- Sends events in log phase (after response sent to client) so it never
-- blocks upstream latency.
--
-- PHASE STRATEGY (KRITIK — log phase kısıtlamaları nedeniyle):
--   :access       — kong.request.* API'leri YALNIZCA burada çalışır.
--                   request method/path/query/headers/body'yi topla,
--                   kong.ctx.shared.kafka_log_oss'a yaz.
--   :body_filter  — response body chunk'larını biriktir (log phase'inde
--                   response buffer da recycle edilmiş olur).
--   :log          — sadece ngx.var.*, ngx.status, kong.response.* (log'da
--                   çalışır), ve kong.ctx.shared'dan okur; asla
--                   kong.request.* çağırmaz.
--
-- All config fields are dynamic — reloaded from DB on every request.
-- Schema defined in schema.lua.
-- ==========================================================================

local cjson = require("cjson.safe")
local producer = require("resty.kafka.producer")

ngx.log(ngx.NOTICE, "[kafka-log-oss] HANDLER LOADED v1.1.0 (access+body_filter+log phases)")

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
  VERSION = "1.1.0",
}

-- ──────────────────────────────────────────────────────────────────────────
-- ACCESS phase: request data'yı topla ve stash'le
-- kong.request.* API'leri YALNIZCA burada çalışır; log phase'inde API
-- disabled hatası fırlatır.
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:access(conf)
  local ctx = {
    method  = kong.request.get_method(),
    path    = kong.request.get_path(),
    query   = kong.request.get_raw_query(),
    headers = kong.request.get_headers(),
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
-- BODY_FILTER phase: response body chunk'larını biriktir
-- Response buffer da log phase'inde recycle edildiği için burada toplamak
-- zorundayız. arg[1] = chunk, arg[2] = eof. Pass-through: arg[1]'i
-- değiştirmiyoruz, sadece biriktiriyoruz.
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:body_filter(conf)
  if not conf.log_response_body then
    return
  end

  local ctx = kong.ctx.shared.kafka_log_oss
  if not ctx then
    return  -- access phase never ran (very early failure), nothing to do
  end

  local chunk = ngx.arg[1]
  if chunk and chunk ~= "" then
    ctx.response_body = (ctx.response_body or "") .. chunk
  end
end

-- ──────────────────────────────────────────────────────────────────────────
-- LOG phase: Kafka'ya gönder
-- Bu fazda ASLA kong.request.* çağrısı yapma. Sadece:
--   - ngx.var.* / ngx.status (her zaman kullanılabilir)
--   - kong.response.* (header_filter/body_filter/log fazlarında çalışır)
--   - kong.client.get_ip / get_credential (log fazında çalışır)
--   - kong.router.get_route (log fazında çalışır)
--   - kong.ctx.shared.kafka_log_oss (access'te yazdığımız veri)
-- ──────────────────────────────────────────────────────────────────────────
function KafkaLogHandler:log(conf)
  local ctx = kong.ctx.shared.kafka_log_oss or {}

  local ok, err = pcall(function()
    local route = kong.router.get_route()
    local service = route and route.service
    local cred = kong.client.get_credential()

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
        id   = route and route.id or nil,
        name = route and route.name or nil,
      },

      service = {
        id   = service and service.id or nil,
        name = service and service.name or nil,
        host = service and service.host or nil,
      },

      consumer = cred and cred.consumer and {
        id       = cred.consumer.id,
        username = cred.consumer.username,
      } or nil,

      response = {
        status         = kong.response.get_status(),
        content_length = tonumber(kong.response.get_header("content-length")) or 0,
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
