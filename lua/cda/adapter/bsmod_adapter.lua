-- lua/cda/adapter/bsmod_adapter.lua

local Constants = include("cda/core/constants.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "BSModAdapter"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

local Event = Constants.Event
local BSMOD_EVENT_RequestCustomKillMove = "CustomKillMoves"

local Adepter = {}

---@param bsResult BSModCustomKillMoveResult
---@return SceneDescriptor|nil
local function parseSceneDescriptor(bsResult)
    -- ① 必需的：victim 决定这是不是一个可解析的请求
    local victimModel = bsResult[2]
    if not victimModel then return nil end

    -- ② 必需的：animName 决定能不能播
    local animName = bsResult[3]
    if not animName then return nil end

    -- ③ 可选：killer 由 model 是否存在决定
    local killerModel = bsResult[1]
    local killer
    if killerModel then
        killer = {
            Model    = killerModel,
            Duration = bsResult[6], -- 可为 nil，由消费方兜底
        }
    end

    ---@type SceneDescriptor
    return {
        AnimName          = animName,
        Victim            = {
            Model    = victimModel,
            Duration = bsResult[7], -- 可为 nil
        },
        Killer            = killer,
        ShouldAlignVictim = bsResult[8],
    }
end

local EVENT = Event.RequestCustomKillMove
local ID = KEY .. "_" .. EVENT
hook.Add(EVENT, ID, function (ply, target, angleAround)
    ---@type BSModCustomKillMoveResult?
    local bsModCustomKillMoveResult = hook.Run("CustomKillMoves", ply, target, angleAround)
    if not bsModCustomKillMoveResult then return nil end

    local animName = bsModCustomKillMoveResult[3]
    if not animName then return nil end

    local victimModel = bsModCustomKillMoveResult[2]
    local victimDuration = bsModCustomKillMoveResult[7]
    if not victimModel or not victimDuration then return nil end
    local victim = {
        Model = victimModel,
        Duration = victimDuration
    }

    local killerModel = bsModCustomKillMoveResult[1]
    local killerDuration = bsModCustomKillMoveResult[6]
    local killer
    if killerModel and killerDuration then
        killer = {
            Model = killerModel,
            Duration = killerDuration
        }
    end

    ---@type SceneDescriptor
    local myCustomKillMoveResult = {
        AnimName = animName,
        Victim = victim,
        Killer = killer
    }

    return myCustomKillMoveResult
end)

package.loaded[KEY] = Adepter
return Adepter
