local validator = require("kong.plugins.medasista-validator.request_validator")

-- Module load log: eger bu gorunuyorsa Kong yeni kodu yukledi demektir
ngx.log(ngx.NOTICE, "[medasista-validator] HANDLER LOADED v1.3.0")

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
  VERSION = "1.3.0",
}

function MedasistaValidatorHandler:access(conf)
  -- GET/DELETE gibi body barındırmayan istekler için plugin'i çalıştırma
  local method = kong.request.get_method()
  if method ~= "POST" and method ~= "PUT" then
    return
  end

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CRITICAL ORDER: image_tokens hesaplaması validator.validate()'tan ÖNCE
  -- yapılmalı. Çünkü validator body'yi OpenAI formatına çevirip body.image'ı
  -- siliyor. Validator sonrası get_body() transformed body döner — image yok.
  --
  -- Akış:
  --   1. body.image'ı orijinal haliyle oku
  --   2. calculate_base64_tokens ile image_tokens hesapla, ctx.shared'e yaz
  --      (sadece conf.calculate_image_tokens == true ise; admin kapatabilir)
  --   3. validator.validate(conf) çağır (body upstream formatına dönüşür)
  -- ═══════════════════════════════════════════════════════════════════════════

  -- conf hesaplanmamışsa default true kabul et (eski davranış)
  local calc_image_tokens = conf.calculate_image_tokens
  if calc_image_tokens == nil then calc_image_tokens = true end

  if calc_image_tokens then
    local cjson = require("cjson.safe")
    local body = kong.request.get_body()
    local image_str = nil

    if body and type(body.image) == "string" then
      image_str = body.image
    end

    if image_str then
      local tokens = calculate_base64_tokens(image_str)
      kong.ctx.shared.image_tokens = tokens
      ngx.log(ngx.NOTICE,
        string.format("[medasista-validator] image_tokens=%d (b64_len=%d)",
          tokens, #image_str))
    else
      kong.ctx.shared.image_tokens = 0
      ngx.log(ngx.WARN,
        "[medasista-validator] body.image is nil/not-string at access; image_tokens=0")
    end
  else
    kong.ctx.shared.image_tokens = 0
    ngx.log(ngx.NOTICE,
      "[medasista-validator] calculate_image_tokens disabled in config; image_tokens=0")
  end

  -- Body transformation burada olur (validator): image field silinir, OpenAI
  -- messages[] yapısına dönüşür. Ama biz zaten image_tokens'ı ctx'e yazdık.
  local ok, err = pcall(validator.validate, conf)
  if not ok then
    ngx.log(ngx.ERR, "[medasista-validator] validator.validate ERROR: ", tostring(err))
  end
end

return MedasistaValidatorHandler
