local validator = require("kong.plugins.medasista-validator.request_validator")

local MedasistaValidatorHandler = {
  PRIORITY = 1200, -- Runs in access phase before AI Proxy and Rate Limiting
  VERSION = "1.0.0",
}

function MedasistaValidatorHandler:access(conf)
  validator.validate()
end

-- Response phase: vLLM OpenAI-format cevabini basit JSON'a donusturur.
-- Girdi:  { "choices": [{"message": {"content": "..."}}], "usage": {...}, ... }
-- Cikti:  { "request_id": "<kong uuid>", "content": "...", "usage": {...} }
function MedasistaValidatorHandler:response(conf)
  local cjson = require("cjson.safe")

  local body, err = kong.service.response.get_raw_body()
  if not body then
    kong.log.notice("[medasista-validator] response body empty: ", tostring(err))
    return
  end

  local parsed, perr = cjson.decode(body)
  if not parsed or not parsed.choices then
    -- JSON degil veya OpenAI formatinda degil, dokunma
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

  kong.service.response.set_raw_body(simplified)
  kong.response.set_header("Content-Type", "application/json; charset=utf-8")
end

return MedasistaValidatorHandler
