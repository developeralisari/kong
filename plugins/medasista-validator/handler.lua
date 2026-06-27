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
-- tek chunk olarak gelir (eof=true).
function MedasistaValidatorHandler:body_filter(conf)
  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  -- DEBUG: body_filter gercekten cagiriliyor mu kontrol edelim
  ngx.log(ngx.NOTICE, "[medasista-validator] body_filter CALLED | eof=", tostring(eof),
    " | chunk_size=", chunk and #chunk or 0)

  -- Streaming'de her chunk'ta calisir; biz sadece son chunk'ta toplu degisiklik yapariz
  if not eof then
    return
  end

  if not chunk or chunk == "" then
    ngx.log(ngx.NOTICE, "[medasista-validator] body_filter: empty chunk, skipping")
    return
  end

  local cjson = require("cjson.safe")
  local parsed, perr = cjson.decode(chunk)
  if not parsed or not parsed.choices then
    -- vLLM hata response'u veya OpenAI formatinda degil, dokunma
    ngx.log(ngx.NOTICE, "[medasista-validator] body_filter: not OpenAI format (err=", tostring(perr), "), skipping")
    return
  end

  local first = parsed.choices[1]
  local content = ""
  if first and first.message then
    content = first.message.content or ""
  end

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
