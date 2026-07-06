-- ==========================================================================
-- MedAsista AI Gateway — Request Validator (MedGemma 1.5 Hardened)
-- Kong Plugin (access phase).
-- 2D tıbbi görsel işleme endpoint'leri için kapsamlı validasyon.
--
-- Kullanım (Kong UI → Plugin → access phase):
--   require("kong.plugins.medasista-validator.request_validator").validate(conf)
--
-- conf: Kong plugin config (schema.lua'dan). Tüm alanlar schema default'larına
--       sahip olduğu için her zaman dolu gelir. Yine de DEFAULT_CONFIG fallback
--       olarak tutulur (unit test / standalone kullanım için).
--
-- Spesifikasyon:
--   - Base64 JPG/PNG, max 896x896, max 10MB (varsayılan, hepsi config'den)
--   - Zorunlu: category (whitelist), image
--   - Opsiyonel: output_template, metadata
--
-- Güvenlik Modülleri:
--   1. Medical Safety Module (tıbbi tavsiye/teşhis/reçete - TR+EN)
--   2. System Prompt Protection (prompt extraction)
--   3. Output Sanitization (XSS/HTML/JS/Template injection)
--   4. PHI/PII Detection (TC, tel, email, KVKK/GDPR)
--   5. Multi-Language Injection (TR+EN+karışık)
--   6. Encoding Detection (Base64/ROT13/Unicode homoglyph)
--   7. Category-Image Consistency (basit heuristik)
--   8. Request Structure Limits (depth, field count)
-- ==========================================================================

local cjson = require("cjson.safe")

-- Lua string.gsub replacement string'inde % özel karakter (capture index gibi yorumlanır).
-- Kullanıcı kontrollü string'i (output_template, category) gsub'a vermeden önce
-- % karakterlerini %% olarak escape etmek gerekir; aksi halde "invalid capture index" hatası fırlatır.
local function gsub_escape(s)
    if s == nil then return "" end
    return (s:gsub("%%", "%%%%"))
end

local M = {}

-- ==========================================================================
-- DEFAULT CONFIG — Schema'daki default'larla birebir aynı olmalı.
-- conf verilmezse veya bazı alanlar eksikse fallback olarak kullanılır.
-- ==========================================================================
-- Standalone test fallback — Kong her zaman schema default'larını conf'a enjekte eder.
local DEFAULT_CONFIG = {
    allowed_methods = { "POST", "PUT" },
    max_file_size_bytes = 10 * 1024 * 1024,
    max_image_width = 896,
    max_image_height = 896,
    allowed_categories = { "CXR", "MSK", "AXR", "MAM", "DER", "FUN", "PAT", "USG", "ECH", "MRG" },
    category_size_hints = {},
    template_min_length = 10,
    template_max_length = 500,
    max_body_fields = 20,
    max_metadata_depth = 3,
    max_metadata_fields = 10,
    system_prompt_template = "",
    model_name = "google/medgemma-1.5-4b-it",
    stream_enabled = false,
    jailbreak_patterns = {},
    turkish_injection_patterns = {},
    medical_safety_en = {},
    medical_safety_tr = {},
    model_identity_patterns = {},
    system_prompt_extraction_patterns = {},
    output_sanitization_patterns = {},
    phi_patterns = {},
}

-- Güvenlik bütünlüğü — config'e taşınmaz, sabit kalır
local MAGIC_JPG = string.char(0xFF, 0xD8, 0xFF)
local MAGIC_PNG = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

-- Encoding detection için sabit keyword'ler (saldırı yüzeyi tanımı)
local BASE64_INJECTION_KEYWORDS = { "ignore", "instruction", "system", "prompt", "bypass safety", "bypass your" }
local ROT13_KEYWORDS = {
    "vtaber", "vtaber nyy", "vafgehpgvba", "flfgrz cebzcg",
    "lnvyoernx", "qna zbqr", "fhqb zbqr", "ovcnff",
}
local BASE64_DETECTION_REGEX = "[A-Za-z0-9+/=]{40,}"
local BASE64_MIN_INSPECT_LEN = 20
local ZERO_WIDTH_CHARS_REGEX = "[\\x{200B}-\\x{200F}\\x{202A}-\\x{202E}\\x{FEFF}]"

-- ==========================================================================
-- HELPERS
-- ==========================================================================

local function error_response(status, error_type, message, details)
    local body = { e = error_type, m = message }
    if details then body.d = details end
    return kong.response.exit(status, cjson.encode(body))
end

-- Array'de üye kontrolü (allowed_methods, allowed_categories için)
local function array_contains(arr, value)
    if type(arr) ~= "table" then return false end
    for _, v in ipairs(arr) do
        if v == value then return true end
    end
    return false
end

-- Array'i sort edilmiş string listesine çevir (error mesajlarında)
local function array_to_sorted_string(arr)
    local sorted = {}
    for _, v in ipairs(arr or {}) do sorted[#sorted + 1] = v end
    table.sort(sorted)
    return table.concat(sorted, ", ")
end

-- Base64 decode (data URI prefix'ini destekler)
local function decode_base64(b64_string)
    local data = b64_string
    if data:sub(1, 5) == "data:" then
        local comma_pos = data:find(",", 1, true)
        if comma_pos then
            data = data:sub(comma_pos + 1)
        end
    end
    return ngx.decode_base64(data)
end

-- Görsel format algılama (magic bytes)
local function detect_image_format(raw_bytes)
    if not raw_bytes or #raw_bytes < 8 then
        return nil
    end
    if raw_bytes:sub(1, 3) == MAGIC_JPG then
        return "jpg"
    end
    if raw_bytes:sub(1, 8) == MAGIC_PNG then
        return "png"
    end
    return nil
end

-- Görsel çözünürlük okuma
local function get_image_dimensions(raw_bytes, format)
    if format == "jpg" then
        local i = 3
        local len = #raw_bytes
        while i < len - 1 do
            if raw_bytes:byte(i) == 0xFF then
                local marker = raw_bytes:byte(i + 1)
                if marker == 0xC0 or marker == 0xC2 then
                    if i + 8 > len then return nil, nil end
                    local height = raw_bytes:byte(i + 5) * 256 + raw_bytes:byte(i + 6)
                    local width = raw_bytes:byte(i + 7) * 256 + raw_bytes:byte(i + 8)
                    return width, height
                elseif marker == 0xD8 or marker == 0xD9 then
                    i = i + 2
                elseif marker == 0x00 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
                    i = i + 2
                else
                    if i + 3 > len then return nil, nil end
                    local seg_len = raw_bytes:byte(i + 2) * 256 + raw_bytes:byte(i + 3)
                    i = i + 2 + seg_len
                end
            else
                i = i + 1
            end
        end
    elseif format == "png" then
        if #raw_bytes < 24 then return nil, nil end
        if raw_bytes:sub(13, 16) ~= "IHDR" then return nil, nil end
        local b17, b18, b19, b20 = raw_bytes:byte(17, 20)
        local b21, b22, b23, b24 = raw_bytes:byte(21, 24)
        local width = b17 * 16777216 + b18 * 65536 + b19 * 256 + b20
        local height = b21 * 16777216 + b22 * 65536 + b23 * 256 + b24
        return width, height
    end
    return nil, nil
end

-- Unicode homoglyph normalization: Cyrillic/full-width → ASCII
local HOMOGLYPHS = {
    ["\xD0\xB0"] = "a", ["\xD1\x81"] = "c", ["\xD0\xB5"] = "e",
    ["\xD0\xBE"] = "o", ["\xD1\x80"] = "p", ["\xD1\x85"] = "x",
    ["\xD1\x83"] = "y", ["\xD1\x96"] = "i", ["\xD1\x98"] = "j",
    ["\xD2\xBB"] = "h", ["\xD0\xBA"] = "k", ["\xD0\xBC"] = "m",
    ["\xD0\xBD"] = "n", ["\xD1\x82"] = "t", ["\xD0\xB2"] = "v",
}

local function normalize_text(text)
    if not text then return "" end
    -- Step 1: lowercase via ngx.re (unicode-aware)
    local lower = ngx.re.gsub(text, ".", function(m)
        return string.lower(m[0])
    end, "u") or string.lower(text)
    -- Step 2: replace known Cyrillic homoglyphs with ASCII equivalents
    for homoglyph, ascii in pairs(HOMOGLYPHS) do
        lower = lower:gsub(homoglyph, ascii)
    end
    -- Step 3: strip full-width ASCII (U+FF01-FF5E → 0x21-0x7E)
    lower = ngx.re.gsub(lower, "[\\x{FF01}-\\x{FF5E}]", function(m)
        local b1, b2, b3 = string.byte(m[0], 1, 3)
        local codepoint = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
        local ascii_cp = codepoint - 0xFEE0
        if ascii_cp >= 0x21 and ascii_cp <= 0x7E then
            return string.char(ascii_cp)
        end
        return m[0]
    end, "u") or lower
    -- Step 4: strip zero-width characters
    lower = ngx.re.gsub(lower, "[\\x{200B}-\\x{200F}\\x{202A}-\\x{202E}\\x{FEFF}\\x{00AD}]", "", "u") or lower
    return lower
end

-- Multi-pattern detection (plain text, unicode-normalized, case-insensitive)
local function detect_patterns(text, pattern_list)
    if not text or type(text) ~= "string" then return nil end
    if type(pattern_list) ~= "table" then return nil end
    local normalized = normalize_text(text)
    for _, pattern in ipairs(pattern_list) do
        if type(pattern) == "string" then
            if string.find(normalized, pattern, 1, true) then
                return pattern
            end
        end
    end
    return nil
end

-- Multi-pattern detection (regex via ngx.re.find)
local function detect_regex_patterns(text, pattern_list)
    if not text or type(text) ~= "string" then return nil, nil end
    if type(pattern_list) ~= "table" then return nil, nil end
    for _, entry in ipairs(pattern_list) do
        if type(entry) == "table" and type(entry.pattern) == "string" then
            local from, to = ngx.re.find(text, entry.pattern, "ijo")
            if from then
                return entry.type, string.sub(text, from, to)
            end
        end
    end
    return nil, nil
end

-- Encoding bypass detection (sabit kurallar)
local function detect_encoding_bypass(text)
    if not text or type(text) ~= "string" then return nil end

    -- Base64 encoded strings (uzun base64 blokları)
    if ngx.re.find(text, BASE64_DETECTION_REGEX, "jo") then
        for encoded in string.gmatch(text, "[A-Za-z0-9+/=]+") do
            if #encoded >= BASE64_MIN_INSPECT_LEN then
                local decoded = ngx.decode_base64(encoded)
                if decoded then
                    local lower = string.lower(decoded)
                    for _, kw in ipairs(BASE64_INJECTION_KEYWORDS) do
                        if string.find(lower, kw, 1, true) then
                            return "Base64 encoded injection: " .. kw
                        end
                    end
                end
            end
        end
    end

    -- Zero-width character detection
    if ngx.re.find(text, ZERO_WIDTH_CHARS_REGEX, "jo") then
        return "Zero-width characters detected"
    end

    -- ROT13 keyword detection
    local lower = string.lower(text)
    for _, kw in ipairs(ROT13_KEYWORDS) do
        if string.find(lower, kw, 1, true) then
            return "ROT13 encoded injection: " .. kw
        end
    end

    return nil
end

-- PHI/PII detection
local function detect_phi(text, phi_patterns)
    return detect_regex_patterns(text, phi_patterns)
end

-- Table depth hesaplama
local function table_depth(t, max_depth, current_depth)
    current_depth = current_depth or 1
    if current_depth > max_depth then return current_depth end
    if type(t) ~= "table" then return current_depth end
    local max_found = current_depth
    for _, v in pairs(t) do
        if type(v) == "table" then
            local d = table_depth(v, max_depth, current_depth + 1)
            if d > max_found then max_found = d end
        end
    end
    return max_found
end

-- Table field count
local function table_field_count(t)
    if type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- ==========================================================================
-- CONFIG
-- ==========================================================================

-- Kong schema zaten tüm default'ları conf'a enjekte eder.
-- DEFAULT_CONFIG sadece standalone test/fallback için tutulur.
local function get_config(conf)
    if type(conf) == "table" then return conf end
    return DEFAULT_CONFIG
end

-- ==========================================================================
-- MAIN VALIDATION
-- ==========================================================================
function M.validate(plugin_conf)
    local cfg = get_config(plugin_conf)

    -- 1. HTTP method kontrolü
    local method = kong.request.get_method()
    if not array_contains(cfg.allowed_methods, method) then
        return -- İzin verilmeyen methodlar için validasyon yok
    end

    -- 2. Body kontrolü
    local body = kong.ctx.shared.parsed_body
    if not body or type(body) ~= "table" then
        return error_response(400, "ValidationError", "Request body required")
    end

    -- 2a. Request structure limits
    local body_field_count = table_field_count(body)
    if body_field_count > cfg.max_body_fields then
        return error_response(400, "ValidationError",
            "Too many fields in request body",
            string.format("Max %d, got %d", cfg.max_body_fields, body_field_count))
    end

    -- 3. Category validasyonu (ZORUNLU)
    if not body.category then
        return error_response(400, "ValidationError", "Missing: category")
    end
    if type(body.category) ~= "string" then
        return error_response(400, "ValidationError", "category must be string")
    end
    if not array_contains(cfg.allowed_categories, body.category) then
        return error_response(400, "ValidationError",
            "Invalid category",
            "Allowed: " .. array_to_sorted_string(cfg.allowed_categories))
    end
    -- Category whitelist zaten koruyor (array_contains yukarıda). Ek pattern taraması gereksiz.

    -- 4. Image validasyonu (ZORUNLU)
    if not body.image then
        return error_response(400, "ValidationError", "Missing: image")
    end
    if type(body.image) ~= "string" then
        return error_response(400, "ValidationError", "image must be base64 string")
    end

    -- 4a. Base64 boyut kontrolü (max_file_size_bytes'tan otomatik hesapla)
    local max_base64_chars = math.ceil(cfg.max_file_size_bytes * 4 / 3) + 200
    if #body.image > max_base64_chars then
        return error_response(413, "ValidationError",
            "Image too large",
            string.format("Max %dMB", cfg.max_file_size_bytes / 1024 / 1024))
    end


    -- 4b. Base64 decode
    local raw_bytes = decode_base64(body.image)
    if not raw_bytes then
        return error_response(400, "ValidationError", "Invalid base64 encoding")
    end

    -- 4c. Decode sonrası gerçek boyut kontrolü
    if #raw_bytes > cfg.max_file_size_bytes then
        return error_response(413, "ValidationError",
            "Decoded image exceeds size limit")
    end

    -- 4d. Format kontrolü (yalnızca JPG ve PNG)
    local format = detect_image_format(raw_bytes)
    if not format then
        return error_response(415, "ValidationError",
            "Unsupported image format", "Only JPG and PNG are accepted")
    end

    -- 4e. Çözünürlük kontrolü
    local width, height = get_image_dimensions(raw_bytes, format)
    if width and height then
        if width > cfg.max_image_width or height > cfg.max_image_height then
            return error_response(400, "ValidationError",
                "Image resolution too high",
                string.format("Max %dx%d, got %dx%d",
                    cfg.max_image_width, cfg.max_image_height, width, height))
        end
        if width < 1 or height < 1 then
            return error_response(400, "ValidationError", "Invalid image dimensions")
        end

        -- 4f. Category-Image consistency
        local hints = cfg.category_size_hints and cfg.category_size_hints[body.category]
        if hints then
            if width < hints.min_w or height < hints.min_h then
                return error_response(400, "ValidationError",
                    "Image dimensions inconsistent with category",
                    string.format("Category %s typically requires min %dx%d",
                        body.category, hints.min_w, hints.min_h))
            end
        end
    end

    -- 5. output_template validasyonu (OPSİYONEL)
    if body.output_template ~= nil then
        if type(body.output_template) ~= "string" then
            return error_response(400, "ValidationError",
                "output_template must be string")
        end
        local tpl_len = #body.output_template
        if tpl_len > cfg.template_max_length then
            return error_response(400, "ValidationError",
                "output_template too long",
                string.format("Max %d chars", cfg.template_max_length))
        end
        if tpl_len < cfg.template_min_length then
            return error_response(400, "ValidationError",
                "output_template too short",
                string.format("Min %d chars", cfg.template_min_length))
        end

        -- 6a-6g: Multi-layer output_template kontrolü
        local tpl_match = detect_patterns(body.output_template, cfg.jailbreak_patterns)
        if tpl_match then
            return error_response(400, "PromptInjection", "Invalid template", tpl_match)
        end
        tpl_match = detect_patterns(body.output_template, cfg.turkish_injection_patterns)
        if tpl_match then
            return error_response(400, "PromptInjection", "Invalid template", tpl_match)
        end
        tpl_match = detect_patterns(body.output_template, cfg.medical_safety_en)
            or detect_patterns(body.output_template, cfg.medical_safety_tr)
        if tpl_match then
            return error_response(400, "MedicalSafetyViolation",
                "Template contains medical advice request", tpl_match)
        end
        tpl_match = detect_patterns(body.output_template, cfg.system_prompt_extraction_patterns)
        if tpl_match then
            return error_response(400, "SystemPromptExtraction",
                "Template attempts to extract system prompt", tpl_match)
        end
        tpl_match = detect_patterns(body.output_template, cfg.model_identity_patterns)
        if tpl_match then
            return error_response(400, "ModelIdentityProbe",
                "Template attempts to discover model identity", tpl_match)
        end
        tpl_match = detect_patterns(body.output_template, cfg.output_sanitization_patterns)
        if tpl_match then
            return error_response(400, "OutputSanitization",
                "Template contains unsafe HTML/JS", tpl_match)
        end
        local enc_match = detect_encoding_bypass(body.output_template)
        if enc_match then
            return error_response(400, "EncodingBypass",
                "Template contains encoded payload", enc_match)
        end
        local phi_type, phi_match = detect_phi(body.output_template, cfg.phi_patterns)
        if phi_type then
            return error_response(400, "PHIDetected",
                "Template contains personal health information",
                string.format("Type: %s, Match: %s", phi_type, phi_match))
        end
    end

    -- 6. metadata validasyonu (OPSİYONEL)
    if body.metadata ~= nil then
        if type(body.metadata) ~= "table" then
            return error_response(400, "ValidationError", "metadata must be object")
        end

        local depth = table_depth(body.metadata, cfg.max_metadata_depth + 1)
        if depth > cfg.max_metadata_depth then
            return error_response(400, "ValidationError",
                "metadata too deeply nested",
                string.format("Max depth %d", cfg.max_metadata_depth))
        end

        local field_count = table_field_count(body.metadata)
        if field_count > cfg.max_metadata_fields then
            return error_response(400, "ValidationError",
                "metadata has too many fields",
                string.format("Max %d, got %d", cfg.max_metadata_fields, field_count))
        end

        -- Metadata prompt'a enjekte edilmiyor, sadece structure/size kontrolü yeterli.
    end

    -- ═══════════════════════════════════════════════════════════════════
    -- Tüm validasyonlar başarılı, upstream'e gönderilecek body'yi hazırla
    -- ═══════════════════════════════════════════════════════════════════
    local category = body.category or "genel"
    local output_template = body.output_template or ""
    
    local image_url = body.image
    -- Ensure the image has a data URI prefix, otherwise vLLM URL validators might hang (ReDoS) or try to download it
    if image_url and string.sub(image_url, 1, 5) ~= "data:" then
        local ext = (format == "png") and "png" or "jpeg"
        image_url = "data:image/" .. ext .. ";base64," .. image_url
    end

    -- System prompt template: {category} ve {output_template} placeholder'ları
    -- config'den gelen template ile değiştirilir.
    -- Boş/nil ise system mesajı hiç eklenmez (test sonucumuz: user_text tek başına
    -- en iyi generic kaçışı azaltıyor; system prompt eklendiğinde model
    -- "<unused94>thought" düşünme moduna girip yapı kuruyor ama içerik atlayabiliyor).
    local prompt = cfg.system_prompt_template or ""
    local has_system_prompt = prompt ~= ""
    if has_system_prompt then
        prompt = string.gsub(prompt, "{category}", gsub_escape(category))
        prompt = string.gsub(prompt, "{output_template}", gsub_escape(output_template))
    end

    local user_text = "Lütfen iletilen " .. category ..
        " görselini analiz et ve aşağıdaki boş rapor şablonunu bulgularına göre doldur." ..
        " Başlıkları değiştirmeden sadece iki nokta üst üste (:) işaretinden sonraki kısımlara teşhislerini yaz.\n\n" ..
        output_template

    body.messages = {}
    if has_system_prompt then
        body.messages[#body.messages + 1] = {
            role = "system",
            content = prompt,
        }
    end
    body.messages[#body.messages + 1] = {
        role = "user",
        content = {
            {
                type = "image_url",
                image_url = { url = image_url },
            },
            {
                type = "text",
                text = user_text,
            },
        },
    }

    -- Özel alanları temizle
    body.category = nil
    body.image = nil
    body.output_template = nil
    body.metadata = nil

    body.model = cfg.model_name
    body.stream = cfg.stream_enabled
    body.temperature = 0.0
    body.repetition_penalty = 1.15

    -- JSON encode
    local ok, encoded_or_err = pcall(cjson.encode, body)
    if not ok then
        return error_response(500, "EncodeError", "Failed to encode body: " .. tostring(encoded_or_err))
    end

    -- Kong'un parsed body cache'ini override et
    ngx.ctx.KONG_REQUEST_BODY = body

    -- Upstream'e gönderilecek raw body'yi set et
    local ok_set, err_set = pcall(kong.service.request.set_raw_body, encoded_or_err)
    if not ok_set then
        local ok_req, err_req = pcall(kong.request.set_raw_body, encoded_or_err)
        if not ok_req then
            return error_response(500, "SetBodyError",
                "service.request.set_raw_body failed: " .. tostring(err_set) ..
                " | request.set_raw_body failed: " .. tostring(err_req))
        end
    end
end

-- ==========================================================================
-- EXPORT
-- ==========================================================================
return M