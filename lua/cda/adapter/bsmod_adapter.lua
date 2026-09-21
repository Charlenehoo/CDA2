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

---@class BSModCustomKillMoveResult
---@field [1] string? PlyKMModel 玩家 killmove 模型路径
---@field [2] string? TargetKMModel 目标 killmove 模型路径
---@field [3] string? AnimName 动画序列名
---@field [4] Vector? PlyKMPosition 玩家落点
---@field [5] Angle? PlyKMAngle 玩家朝向
---@field [6] number? PlyKMTime 玩家动画时长
---@field [7] number? TargetKMTime 目标动画时长
---@field [8] boolean? MoveTarget 是否交换玩家和目标

---@param bsResult BSModCustomKillMoveResult
---@return Scene|nil
local function parseSceneDescriptor(bsResult, killer, victim)
    local sequenceName = bsResult[3]
    if not sequenceName then return nil end

    local victimModel = bsResult[2]
    if not victimModel then return nil end

    local killerModel = bsResult[1]
    if not killerModel then return nil end

    ---@type Track
    local victimTrack = {
        ModelName = victimModel,
        SequenceName = sequenceName,
        Position = Vector(0, 0, 0),
        Angle = Angle(0, 0, 0),
        Duration = bsResult[7],
    }

    ---@type Track
    local killerTrack = {
        ModelName = victimModel,
        SequenceName = sequenceName,
        Position = Vector(0, 0, 0),
        Angle = Angle(0, 0, 0),
        Duration = bsResult[7],
    }

    ---@type Scene
    return {
        victimTrack,
        killerTrack,
    }
end

local EVENT = Event.RequestCustomKillMove
local ID = KEY .. "_" .. EVENT
hook.Add(EVENT, ID, function (killer, victim, angleAround)
    ---@type BSModCustomKillMoveResult?
    local bsModCustomKillMoveResult = hook.Run("CustomKillMoves", killer, victim, angleAround)
    if not bsModCustomKillMoveResult then return nil end

    return parseSceneDescriptor(bsModCustomKillMoveResult, killer, victim)
end)

package.loaded[KEY] = Adepter
return Adepter
