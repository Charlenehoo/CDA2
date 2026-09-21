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
    local instance = setmetatable({}, self) --[[@as Thinker]]

    local dense = Thinker._Dense
    local index = #dense + 1
    dense[index] = instance
    instance._DenseIndex = index

    return instance
end

---_Think 中只允许删除自身
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

-- Thinker._Dense 是密集数组，Remove 通过 helper.SwapRemove 实现 O(1) 删除：
-- 若删除的不是末尾，则把末尾元素补到被删位置。
--
-- 遍历方向必须与 SwapRemove 的“末尾补位”语义配合：
--
--   * 正向遍历 (i = 1 -> #dense)：
--       删除自身时，末尾元素会被补到当前已遍历的位置。
--       循环不会回头处理该位置，导致这个末尾元素本帧漏掉一次 _Think。
--
--   * 反向遍历 (i = #dense -> 1)：
--       删除自身时，末尾元素原本已经在更后位置被处理过；
--       补到当前位置后，反向循环已经越过该位置，不会再次访问。
--       因此不重不漏。
--
-- 前提约定：_Think 中只允许删除自身，不允许删除其他 Thinker。
-- 因此反向遍历不会触发“删除索引更小的其他实例，导致末尾元素补到
-- 未遍历区域而被第二次 _Think”的问题。
--
-- 如果未来需要在 _Think 中删除其他实例，请改为延迟删除：
-- 遍历期间只标记 _PendingRemove，遍历结束后统一从后往前 SwapRemove 清理。

local function think()
    local dense = Thinker._Dense
    for i = #dense, 1, -1 do
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
