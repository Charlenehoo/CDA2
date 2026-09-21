-- lua/cda/core/thinker.lua

local Constants = include("cda/core/constants.lua")
local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "Thinker"

local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

---@class Thinker
---@field _IsRemoved boolean
---@field _Think fun(self: Thinker)
---@field _OnRemove fun(self: Thinker)
---@field Remove fun(self: Thinker)

---@class ThinkerClass
---@field _Instances table<Thinker, boolean>
---@field New fun(self: ThinkerClass): Thinker
local Thinker = {}
Thinker.__index = Thinker
Thinker._Instances = {}

---@return Thinker
function Thinker:New()
    local instance = setmetatable({}, self)
    Thinker._Instances[instance] = true -- 这里用 Thinker 而不用 self 的原因是, 子类的子类也可以统一由老祖宗一起 Think

    ---@cast instance Thinker
    instance._IsRemoved = false
    return instance
end

function Thinker:Remove()
    if self._IsRemoved then return end
    self._IsRemoved = true

    Thinker._Instances[self] = nil
    self:_OnRemove()
end

function Thinker:_Think() end

function Thinker:_OnRemove() end

local function think()
    local snapshot = table.GetKeys(Thinker._Instances)
    for i = 1, #snapshot do
        local instance = snapshot[i]
        if Thinker._Instances[instance] then
            instance:_Think()
        end
    end
end

local EVENT = "Think"
local ID = KEY .. "_" .. EVENT
hook.Add(EVENT, ID, think)

package.loaded[KEY] = Thinker
return Thinker
