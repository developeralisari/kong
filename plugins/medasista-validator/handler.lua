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
function MedasistaValidatorHandler:body_filter(conf)
  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  ngx.log(ngx.NOTICE, "[medasista-validator] body_filter | eof=", tostring(eof),
    " | chunk_size=", chunk and #chunk or 0)

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
    -- Streaming delta veya beklenmeyen format, dokunma
    return
  end

  local content = first.message.content or ""

  local simplified = cjson.encode({
    request_id = kong.request.get_id(),
    content = content,
    usage = parsed.usage,
  })

  ngx.arg[1] = simplified
  -- Body boyutu degisti, Content-Length'i temizle ki nginx yeniden hesaplasin
  kong.response.clear_header("Content-Length")

  ngx.log(ngx.NOTICE, "[medasista-validator] body_filter DONE | new_size=", #simplified)
end

return MedasistaValidatorHandler
