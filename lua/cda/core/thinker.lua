-- lua/cda/core/thinker.lua

local Constants = include("cda/core/constants.lua")
local helper = include("cda/core/helper.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "Thinker"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

---@class Thinker
---@field _DenseIndex number|nil
---@field _Think fun(self: Thinker)
---@field _OnRemove fun(self: Thinker)
---@field Remove fun(self: Thinker)

---@class ThinkerClass
---@field _Dense Thinker[]
---@field New fun(self: ThinkerClass): Thinker
local Thinker = {}
Thinker.__index = Thinker
Thinker._Dense = {}

---@return Thinker
function Thinker:New()
    local instance = setmetatable({}, self)
    ---@cast instance Thinker

    local dense = Thinker._Dense
    local index = #dense + 1
    dense[index] = instance
    instance._DenseIndex = index

    return instance
end

function Thinker:Remove()
    if not self._DenseIndex then return end

    local index = self._DenseIndex
    local _, moved = helper.SwapRemove(Thinker._Dense, index)
    if moved then
        moved._DenseIndex = index
    end
    self._DenseIndex = nil

    self:_OnRemove()
end

function Thinker:_Think() end

function Thinker:_OnRemove() end

local function think()
    local dense = Thinker._Dense
    local count = #dense
    for i = 1, count do
        local instance = dense[i]
        if instance then
            instance:_Think()
        end
    end
end

local EVENT = "Think"
local ID = KEY .. "_" .. EVENT
hook.Add(EVENT, ID, think)

package.loaded[KEY] = Thinker
return Thinker
