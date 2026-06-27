local validator = require("kong.plugins.medasista-validator.request_validator")

-- Module load log: eger bu gorunuyorsa Kong yeni kodu yukledi demektir
ngx.log(ngx.NOTICE, "[medasista-validator] HANDLER LOADED v1.2.0")

-- ════════════════════════════════════════════════════════════════════════════
-- BPE-inspired token calculation for base64 image strings.
--
-- Gemma (SentencePiece BPE, ~256K vocab) treats base64 content as a string.
-- Algorithm:
--   1. Strip data URL prefix ("data:image/jpeg;base64," veya benzeri)
--   2. Process 4-char groups (base64 natural unit = 3 bytes of binary data)
--   3. For each group, count unique chars and apply merge rules:
--        - 1 unique char (e.g. "AAAA") → 1 token (heavy repetition, BPE merges)
--        - 2 unique chars (e.g. "AABB") → 2 tokens
--        - 3 unique chars (e.g. "ABCx") → 3 tokens (high entropy, less merging)
--        - 4 unique chars (e.g. "aB3x") → 3 tokens
--   4. Tail (1-3 chars, usually "=" padding) → 1 token per char
--
-- Bu method base64 string'i karakter karakter işler, BPE merge davranışını
-- taklit eder. Gerçek Gemma tokenizer'dan ~±10% sapma beklenir (faturalandırma
-- için güvenli tarafta).
-- ════════════════════════════════════════════════════════════════════════════
local function calculate_base64_tokens(b64_string)
  if not b64_string or b64_string == "" then
    return 0
  end

  -- Step 1: Strip data URL prefix. Format: "data:<mime>;base64,<data>"
  local comma_idx = string.find(b64_string, ",", 1, true)
  local pure_b64 = comma_idx and string.sub(b64_string, comma_idx + 1) or b64_string

  local len = #pure_b64
  if len == 0 then
    return 0
  end

  -- Step 2-4: Process 4-char base64 groups
  local tokens = 0
  local i = 1
  while i <= len do
    local remaining = len - i + 1
    if remaining >= 4 then
      local g = string.sub(pure_b64, i, i + 3)
      -- Count unique chars in this 4-char group (BPE merge rate estimation)
      local seen = {}
      local unique_count = 0
      for j = 1, 4 do
        local c = string.sub(g, j, j)
        if not seen[c] then
          seen[c] = true
          unique_count = unique_count + 1
        end
      end

      if unique_count == 1 then
        tokens = tokens + 1   -- "AAAA" → 1 token
      elseif unique_count == 2 then
        tokens = tokens + 2   -- "AABB" → 2 tokens
      else
        tokens = tokens + 3   -- "aB3x" → 3 tokens (3 or 4 unique chars)
      end

      i = i + 4
    else
      -- Tail (1-3 chars, usually "=" or "==" padding): 1 token per char
      tokens = tokens + remaining
      i = i + remaining
    end
  end

  return tokens
end

local MedasistaValidatorHandler = {
  PRIORITY = 1200, -- Runs in access phase before AI Proxy and Rate Limiting
  VERSION = "1.2.0",
}

function MedasistaValidatorHandler:access(conf)
  validator.validate()

  -- Image base64 string'i BPE-inspired tokenization ile say.
  -- vLLM'in "prompt_tokens" alanı multimodal image token'ları dahil etmiyor
  -- (veya eksik sayıyor); burada hesaplanan image_tokens, response phase'te
  -- vLLM'in prompt_tokens'ına eklenir.
  local body = kong.request.get_body()
  if body and type(body.image) == "string" then
    kong.ctx.shared.image_tokens = calculate_base64_tokens(body.image)
  else
    kong.ctx.shared.image_tokens = 0
  end
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
      -- Access phase'te hesaplanan image_tokens'ı vLLM'in prompt_tokens'ına ekle.
      -- vLLM sadece text sayıyor, multimodal image tokens eksik kalıyor.
      local image_tokens = kong.ctx.shared.image_tokens or 0
      local vllm_prompt = parsed.usage.prompt_tokens or 0
      local input_tokens = vllm_prompt + image_tokens
      local output_tokens = parsed.usage.completion_tokens or 0
      local total_tokens = input_tokens + output_tokens

      usage_str = string.format(
        '{"input_tokens":%s,"output_tokens":%s,"total_tokens":%s}',
        enc(input_tokens),
        enc(output_tokens),
        enc(total_tokens)
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
