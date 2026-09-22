local MODULE_NAME = "Log"
_EDAE2Singletons = _EDAE2Singletons or {}
if _EDAE2Singletons[MODULE_NAME] then
    return _EDAE2Singletons[MODULE_NAME]
end

local log = include("edae2/core/log/log.lua")
log.level = "trace"

_EDAE2Singletons[MODULE_NAME] = log
return log
