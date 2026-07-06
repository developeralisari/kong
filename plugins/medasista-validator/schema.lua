-- ==========================================================================
-- MedAsista AI Gateway — Plugin Schema
--
-- Admin UI tip eşlemesi (Kong 3.9):
--   set + elements.one_of   → vue-multiselect chips (protocols gibi)
--   set + elements.string   → tag input (mevcut etiketler + yeni ekleme)
--   array + elements.string → JSON array textarea
--   string                  → text input (Kong OSS'ta multi-line/textarea YOK)
--   number                  → numeric input
--   boolean                 → checkbox
--   map                     → key-value editor (CXR → Radyoloji - ...)
--   record                  → nested form
--
-- 23 toplam alan:
--   A) Kritik / deployment'a göre değişir  (15)
--   B) Opsiyonel / güvenlik tuning         (8)
--
-- Schema format notu (Kong 3.9 metaschema):
--   Outer `fields` her zaman ARRAY (her eleman `{ name = def }`).
--   Inner record `fields` da ARRAY olmalı, named-key map değil.
--   Aynısı nested record (map.values, array.elements) için de geçerli.
-- ==========================================================================

return {
  name = "medasista-validator",
  fields = {
    { config = {
        type = "record",
        fields = {

          -- ═══════════════════════════════════════════════════════════════
          -- A. KRİTİK — Deployment'a göre değişir (15 alan)
          -- ═══════════════════════════════════════════════════════════════

          -- 1. HTTP methods (multi-select). set + one_of → vue-multiselect chips.
          { allowed_methods = {
              type = "set",
              elements = {
                type = "string",
                one_of = { "GET", "POST", "PUT", "PATCH", "DELETE" },
                len_min = 1,
              },
              default = { "POST", "PUT" },
              description = "HTTP methods this plugin will apply to.",
          } },

          -- 2. Max decoded image size (bytes)
          { max_file_size_bytes = {
              type = "number",
              default = 10485760, -- 10 MB
              description = "Maximum decoded image size in bytes (default 10 MB).",
          } },

          -- 3. Max image width (px)
          { max_image_width = {
              type = "number",
              default = 896,
              description = "Maximum allowed image width in pixels.",
          } },

          -- 4. Max image height (px)
          { max_image_height = {
              type = "number",
              default = 896,
              description = "Maximum allowed image height in pixels.",
          } },

          -- 5. Allowed medical categories (multi-select). set + free-form string
          --    elements → vue-multiselect chips. Categories are dynamic so ops
          --    can add new codes (MRG, CT, PET, ...) from Admin UI without a
          --    schema/code change. Runtime still enforces whitelist via
          --    array_contains() in request_validator.lua, so unknown values
          --    are rejected at request time.
          { allowed_categories = {
              type = "set",
              elements = {
                type = "string",
                len_min = 1,
              },
              default = { "CXR", "MSK", "AXR", "MAM", "DER", "FUN", "PAT", "USG", "ECH", "MRG" },
              description = "Medical image categories accepted by this gateway. Editable from Admin UI.",
          } },

          -- 6. Category-size hints (map: category_code → min dimensions)
          { category_size_hints = {
              type = "map",
              keys = { type = "string" },
              values = {
                type = "record",
                fields = {
                  { min_w = { type = "number", default = 100 } },
                  { min_h = { type = "number", default = 100 } },
                },
              },
              default = {
                ["PAT"] = { min_w = 100, min_h = 100 },
                ["FUN"] = { min_w = 200, min_h = 200 },
                ["DER"] = { min_w = 100, min_h = 100 },
              },
          } },

          -- 7. Min output_template length (chars)
          { template_min_length = {
              type = "number",
              default = 10,
          } },

          -- 8. Max output_template length (chars)
          { template_max_length = {
              type = "number",
              default = 500,
          } },

          -- 9. Max body field count
          { max_body_fields = {
              type = "number",
              default = 20,
          } },

          -- 10. Max metadata nesting depth
          { max_metadata_depth = {
              type = "number",
              default = 3,
          } },

          -- 11. Max metadata field count
          { max_metadata_fields = {
              type = "number",
              default = 10,
          } },

          -- 12. System prompt template (long string, {category} ve {output_template}
          --     placeholder'ları runtime'da değiştirilir). Boş bırakılırsa system
          --     mesajı hiç eklenmez (request_validator.lua'da has_system_prompt=false)
          --     — user text tek başına vLLM'e gider, model daha iyi çalışıyor.
          -- NOT: default verilmez — Kong 3.9 metaschema string default'unda
          -- "length must be at least 1" kuralı var, boş string default olamaz.
          -- nil/empty runtime'da Mesut'un 82408c0 commit'indeki `or ""` korumasıyla handle ediliyor.
          { system_prompt_template = {
              type = "string",
              description = "Boş bırakılırsa system mesajı hiç gönderilmez, sadece user prompt vLLM'e gider. {{category}} ve {{output_template}} placeholder'ları desteklenir.",
          } },

          -- 12b. User prompt template (user mesajının text kısmı, image ile birlikte gider).
          --     {category} ve {output_template} placeholder'ları runtime'da değiştirilir.
          --     Default olarak Ali'nin örnek şablonu set ediliyor; Admin UI'dan
          --     dinamik olarak güncellenebilir. Non-empty default Kong 3.9 metaschema'nın
          --     "length must be at least 1" kuralını geçer (system_prompt_template'in
          --     aksine — onda default veremiyoruz çünkü boş bırakılabilir olmalı).
          { user_prompt_template = {
              type = "string",
              default = "Aşağıdaki {category} görüntüsünü incele. Başka hiçbir metin, açıklama veya ek başlık yazmadan, sadece bu şablonu doldurarak dönüş yap:\n\n{output_template}",
              description = "User mesajının metin kısmı (image ile birlikte gönderilir). {category} ve {output_template} placeholder'ları desteklenir.",
          } },

          -- 13. Upstream LLM model adı
          { model_name = {
              type = "string",
              default = "google/medgemma-1.5-4b-it",
              description = "Upstream LLM model identifier (vLLM/HF format).",
          } },

          -- 14. Streaming response (LLM'e gönderilecek body.stream alanı)
          { stream_enabled = {
              type = "boolean",
              default = false,
          } },

          -- 15. Enable image_tokens calculation (true: base64 string'ten token say,
          --     false: image_tokens=0, sadece output_tokens döner)
          { calculate_image_tokens = {
              type = "boolean",
              default = true,
          } },

          -- ═══════════════════════════════════════════════════════════════
          -- B. OPSİYONEL — Güvenlik tuning (8 alan)
          -- ═══════════════════════════════════════════════════════════════

          -- 19. Jailbreak patterns (EN). set + string → tag input (select2/chosen style,
          --     admin mevcut pattern'ları görür, yenilerini de ekleyebilir).
          { jailbreak_patterns = {
              type = "set",
              elements = { type = "string" },
              default = {
                "ignore previous instructions",
                "ignore all previous",
                "you are now",
                "pretend you are",
                "forget your training",
                "override your",
                "disregard your",
                "new instructions",
                "you are a helpful assistant",
                "answer any question",
                "general ai",
                "jailbreak",
                "do anything now",
                "dan mode",
                "developer mode",
                "sudo mode",
                "bypass safety",
                "ignore safety",
                "ignore guidelines",
                "respond without",
                "without restrictions",
                "enable nsfw",
                "unfiltered",
                "translate the previous",
                "anti ai",
                "bypass your rules",
                "break your guidelines",
                "act as a different",
                "you are free now",
                "no longer restricted",
              },
          } },

          -- 20. Turkish injection patterns. set + string → tag input.
          { turkish_injection_patterns = {
              type = "set",
              elements = { type = "string" },
              default = {
                "talimatları görmezden gel",
                "önceki kuralları unut",
                "kuralları görmezden gel",
                "şimdi sen bir",
                "bir doktorsun",
                "bir radyologsun",
                "bir uzmanın",
                "reçete yaz",
                "teşhis koy",
                "tanı koy",
                "ilaç öner",
                "dozaj belirt",
                "sistem promptunu",
                "talimatlarını göster",
                "kurallarını tekrar et",
                "güvenliği devre dışı",
                "filtreleri kaldır",
                "kısıtlamaları kaldır",
                "sansürsüz mod",
                "filtresiz mod",
                "herhangi bir soruya cevap ver",
                "her şeyi cevapla",
                "yapay zeka değilsin",
                "sen bir insansın",
                "kısıtlamaların yok",
                "programlanmadın",
              },
          } },

          -- 21. Medical safety patterns (EN). set + string → tag input.
          { medical_safety_en = {
              type = "set",
              elements = { type = "string" },
              default = {
                "give me a diagnosis",
                "give diagnosis",
                "provide diagnosis",
                "what is the diagnosis",
                "confirm the diagnosis",
                "diagnose this",
                "diagnose the patient",
                "prescribe",
                "prescribe medication",
                "write a prescription",
                "recommend medication",
                "what dosage",
                "what dose should",
                "how many mg",
                "how many pills",
                "should i take",
                "should the patient take",
                "treatment plan",
                "treatment recommendation",
                "medical advice",
                "legal advice",
                "is this cancer",
                "is this malignant",
                "is this benign",
                "am i going to die",
                "will the patient die",
                "second opinion",
                "definitive diagnosis",
                "guarantee",
                "100 percent certain",
                "certain diagnosis",
                "you are a doctor",
                "act as doctor",
                "act as radiologist",
                "act as physician",
                "act as specialist",
                "act as medical",
                "act like a doctor",
                "you are a radiologist",
                "medical professional",
                "board certified",
              },
          } },

          -- 22. Medical safety patterns (TR). set + string → tag input.
          { medical_safety_tr = {
              type = "set",
              elements = { type = "string" },
              default = {
                "teşhis koy",
                "tanı koy",
                "bu ne hastalığı",
                "kanser mi",
                "kötü huylu mu",
                "iyi huylu mu",
                "reçete yaz",
                "ilaç yaz",
                "hangi ilacı almalıyım",
                "kaç mg almalıyım",
                "dozaj ne olmalı",
                "günde kaç kez",
                "ameliyat gerekli mi",
                "ameliyat olmalı mıyım",
                "doktor gibi davran",
                "radyolog gibi davran",
                "uzman gibi davran",
                "sen bir doktorsun",
                "kesin teşhis",
                "garanti ver",
                "yüzde 100 emin",
                "ölümcül mü",
                "hayati tehlike",
                "acil durum",
                "ne yapmalıyım",
                "nasıl tedavi",
                "tedavi öner",
                "ikinci görüş",
              },
          } },

          -- 23. System prompt extraction patterns. set + string → tag input.
          { system_prompt_extraction_patterns = {
              type = "set",
              elements = { type = "string" },
              default = {
                "repeat your instructions",
                "show your instructions",
                "print your instructions",
                "output your instructions",
                "reveal your instructions",
                "what were you told",
                "show me your system prompt",
                "print your system prompt",
                "reveal your system prompt",
                "output your system prompt",
                "what is your system prompt",
                "show your configuration",
                "print your configuration",
                "reveal your configuration",
                "output your configuration",
                "show your training",
                "reveal your training",
                "repeat the above",
                "repeat everything above",
                "show everything before",
                "output the initial",
                "print the initial",
                "what is your base instruction",
                "initial prompt",
                "your original instructions",
                "your default behavior",
                "your hidden instructions",
                "your secret instructions",
                "internal instructions",
                "private instructions",
                "talimatlarını göster",
                "talimatlarını tekrar et",
                "sistem promptunu göster",
                "sistem promptunu tekrar et",
                "yapılandırmanı göster",
                "eğitimini göster",
                "gizli talimatların",
              },
          } },

          -- 24. Model identity discovery patterns. set + string → tag input.
          { model_identity_patterns = {
              type = "set",
              elements = { type = "string" },
              default = {
                "what model", "which model", "what ai", "which ai", "what llm",
                "your model name", "model name", "what are you", "who are you",
                "who made you", "who built you", "who trained you", "who created you",
                "what version", "which version", "your version", "model version",
                "what architecture", "what framework", "what technology",
                "are you gpt", "are you gemma", "are you medgemma", "are you gemini",
                "are you claude", "are you llama", "are you mistral",
                "powered by", "built on", "based on what", "underlying model",
                "foundation model", "base model", "fine-tuned from",
                "hugging face", "huggingface", "google ai", "openai", "anthropic",
                "meta ai", "deepmind",
                "hangi model", "hangi yapay zeka", "model adın", "sen nesin",
                "seni kim yaptı", "seni kim eğitti", "seni kim geliştirdi",
                "hangi versiyon", "versiyonun ne", "altyapın ne", "teknolojin ne",
                "sen gpt misin", "sen gemma mısın", "sen gemini misin",
                "neye dayanıyorsun", "temel modelin ne", "hangi şirket",
                "kimler geliştirdi", "açık kaynak mısın", "hangi dil modeli",
              },
              description = "Patterns to block model identity discovery attempts.",
          } },

          -- 25. Output sanitization patterns (XSS / HTML / JS / template).
          --     set + string → tag input.
          { output_sanitization_patterns = {
              type = "set",
              elements = { type = "string" },
              default = {
                "<script",
                "</script",
                "javascript:",
                "vbscript:",
                "data:text/html",
                "onerror=",
                "onload=",
                "onclick=",
                "onmouseover=",
                "onfocus=",
                "onblur=",
                "onchange=",
                "onsubmit=",
                "<iframe",
                "<object",
                "<embed",
                "<form",
                "<input",
                "<textarea",
                "<button",
                "<svg",
                "<math",
                "<meta",
                "<link",
                "<base",
                "<applet",
                "document.cookie",
                "document.write",
                "window.location",
                "eval(",
                "function(",
                "setTimeout(",
                "setInterval(",
                "fetch(",
                "XMLHttpRequest",
                "{{",
                "${",
                "<%=",
                "<%",
                "{%raw%}",
                "[link](javascript:",
                "![alt](javascript:",
                "url(javascript:",
              },
          } },

          -- 25. PHI/PII regex patterns (KVKK / GDPR)
          { phi_patterns = {
              type = "array",
              elements = {
                type = "record",
                fields = {
                  { pattern = { type = "string" } },
                  { type = { type = "string" } },
                },
              },
              default = {
                { pattern = "\\b[1-9][0-9]{10}\\b", type = "TC Kimlik No" },
                { pattern = "\\+?90[\\s-]?\\(?5[0-9]{2}\\)?[\\s-]?[0-9]{3}[\\s-]?[0-9]{2}[\\s-]?[0-9]{2}", type = "TR Telefon" },
                { pattern = "\\b0?5[0-9]{2}[\\s-]?[0-9]{3}[\\s-]?[0-9]{2}[\\s-]?[0-9]{2}\\b", type = "TR Telefon" },
                { pattern = "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", type = "Email" },
                { pattern = "\\b[0-9]{4}[\\s-]?[0-9]{4}[\\s-]?[0-9]{4}[\\s-]?[0-9]{4}\\b", type = "Kredi Kartı" },
                { pattern = "\\b[A-Z][0-9]{7,8}\\b", type = "Pasaport" },
              },
          } },


        },
    } },
  },
}