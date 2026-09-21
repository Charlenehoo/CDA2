-- lua/cda/playback/animation_model.lua

local Constants = include("cda/core/constants.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "AnimationModel"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

local Thinker = include("cda/core/thinker.lua")

---@class AnimationModel:Thinker
---@field Play fun(self: AnimationModel)

---@class AnimationModelClass:ThinkerClass
---@field New fun(self: AnimationModelClass): AnimationModel
local AnimationModel = setmetatable({}, { __index = Thinker })
AnimationModel.__index = AnimationModel

---@param self AnimationModelClass
---@return AnimationModel
function AnimationModel:New()
    local instance = Thinker.New(self) --[[@as AnimationModel]]
    return instance
end

---@param self AnimationModel
function AnimationModel:Play()

end

package.loaded[KEY] = AnimationModel
return AnimationModel
