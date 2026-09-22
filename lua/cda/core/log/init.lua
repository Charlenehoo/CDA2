local Constants = include("cda/core/constants.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "Log"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

local log = include("edae2/core/log/log.lua")
log.level = "trace"

package.loaded[KEY] = log
return log
