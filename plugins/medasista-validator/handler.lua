local validator = require("kong.plugins.medasista-validator.request_validator")

local MedasistaValidatorHandler = {
  PRIORITY = 1200, -- Runs in access phase before AI Proxy and Rate Limiting
  VERSION = "1.0.0",
}

function MedasistaValidatorHandler:access(conf)
  validator.validate()
end

return MedasistaValidatorHandler
