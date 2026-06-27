local validator = require("kong.plugins.medasista-validator.request_validator")

local MedasistaValidatorHandler = {
  PRIORITY = 1200, -- Runs in access phase before AI Proxy and Rate Limiting
  VERSION = "1.0.0",
}

function MedasistaValidatorHandler:access(conf)
  validator.validate()
end

-- Response body transform: vLLM OpenAI-format → basit JSON.
-- body_filter'da calisir (response body'si modify edilir), non-streaming response
-- tek chunk olarak gelir (eof=true).
function MedasistaValidatorHandler:body_filter(conf)
  local cjson = require("cjson.safe")

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  -- Streaming'de her chunk'ta calisir; biz sadece son chunk'ta toplu degisiklik yapariz
  if not eof then
    return
  end

  if not chunk or chunk == "" then
    return
  end

  local parsed, perr = cjson.decode(chunk)
  if not parsed or not parsed.choices then
    -- vLLM hata response'u veya OpenAI formatinda degil, dokunma
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
end

return MedasistaValidatorHandler
