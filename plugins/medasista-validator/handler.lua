local validator = require("kong.plugins.medasista-validator.request_validator")

-- Module load log: eger bu gorunuyorsa Kong yeni kodu yukledi demektir
ngx.log(ngx.NOTICE, "[medasista-validator] HANDLER LOADED v1.1.0")

local MedasistaValidatorHandler = {
  PRIORITY = 1200, -- Runs in access phase before AI Proxy and Rate Limiting
  VERSION = "1.1.0",
}

function MedasistaValidatorHandler:access(conf)
  validator.validate()
end

-- Response body transform: vLLM OpenAI-format → basit JSON.
-- body_filter'da calisir (response body'si modify edilir), non-streaming response
-- chunked transfer-encoding ile gelir: ilk chunk tum body (eof=false), son chunk
-- sadece bos EOF marker (eof=true). Bu yuzden HER non-empty chunk'ta parse edip
-- simplify ediyoruz; streaming delta'lari delta objesi kullanir, skip edilir.
-- Tüm body_filter pcall ile sarili: hata olursa 502'ye yol acmaz, sadece log basar.
function MedasistaValidatorHandler:body_filter(conf)
  local ok, err = pcall(function()
    local chunk = ngx.arg[1]

    -- Bos chunk (EOF marker) veya nil: skip
    if not chunk or chunk == "" then
      return
    end

    local cjson = require("cjson.safe")
    local parsed, perr = cjson.decode(chunk)
    if not parsed or not parsed.choices then
      -- OpenAI formatinda degil (vLLM hata response'u olabilir), dokunma
      return
    end

    local first = parsed.choices[1]
    -- Streaming delta: choices[].delta var, .message yok. Non-streaming: .message var.
    if not first or not first.message then
      return
    end

    local content = first.message.content or ""

    local request_id = ngx.var.kong_request_id or "unknown"
    -- Manuel string format ile field sırası garantili: request_id → content → usage.
    -- cjson.encode(table) LuaJIT hash sırası kullanır, insertion order korunmaz.
    -- usage explicit 3 alanla (prompt_tokens, completion_tokens, total_tokens)
    -- oluşturuluyor — vLLM'in "prompt_tokens_details" gibi null metadata'ları düşer.
    local function enc(v)
      if v == nil then return "null" end
      return cjson.encode(v)
    end

    local usage_str = "null"
    if type(parsed.usage) == "table" then
      usage_str = string.format(
        '{"input_tokens":%s,"output_tokens":%s,"total_tokens":%s}',
        enc(parsed.usage.prompt_tokens),
        enc(parsed.usage.completion_tokens),
        enc(parsed.usage.total_tokens)
      )
    end

    local simplified = string.format(
      '{"request_id":%s,"content":%s,"usage":%s}',
      cjson.encode(request_id),
      cjson.encode(content),
      usage_str
    )

    ngx.arg[1] = simplified
    -- NOT: Content-Length clear etmiyoruz. Response zaten chunked transfer-encoding
    -- ile geliyor (log'lar onayladi: 1141-byte body tek chunk, sonra bos EOF marker).
    -- clear_header zaten flush edilmis header'a mudahale ederek 502'ye yol acabilir.
  end)

  if not ok then
    ngx.log(ngx.ERR, "[medasista-validator] body_filter ERROR: ", tostring(err))
  end
end

return MedasistaValidatorHandler
