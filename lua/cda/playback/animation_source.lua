-- lua/cda/playback/animation_model.lua

local Constants = include("cda/core/constants.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "AnimationSource"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

---@param modelName string
---@return Entity|nil
local function acquireEntity(modelName)
    if type(modelName) ~= "string" or not util.IsValidModel(modelName) then return nil end

    local ent = ents.Create("prop_dynamic")
    if not IsValid(ent) then return nil end

    ent:SetModel(modelName)
    ent:Spawn()
    return ent
end

---@param ent Entity
local function releaseEntity(ent)
    if IsValid(ent) then
        ent:Remove()
    end
end

local Thinker = include("cda/core/thinker.lua")

---@class AnimationSource:Thinker
---@field _Ent Entity
---@field _SequenceID number
---@field _AnchorID number
---@field _ShouldLoop boolean
---@field _EndTime number
---@field _StartPos Vector
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupAnchor fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _RecordStartPos fun(self: AnimationSource)
---@field _ApplyRootMotion fun(self: AnimationSource)
---@field GetPos fun(self: AnimationSource): Vector
---@field Play fun(self: AnimationSource)

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_TrySetupEntity(track)
    local ent = acquireEntity(track.ModelName)
    if not ent then
        return false
    end
    self._Ent = ent
    return true
end

local PELVIS = "ValveBiped.Bip01_Pelvis"

---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TrySetupAnchor()
    local id = self._Ent:LookupBone(PELVIS)
    if not id or type(id) ~= "number" or id < 0 then
        return false
    end
    self._AnchorID = id
    return true
end

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_TrySetupSequence(track)
    local sequenceID, sequenceDuration = self._Ent:LookupSequence(track.SequenceName)
    if not sequenceID or type(sequenceID) ~= "number" or sequenceID == -1 then
        return false
    end
    local duration = track.Duration or sequenceDuration or math.huge
    local endTime = CurTime() + duration
    self._SequenceID = sequenceID
    self._EndTime = endTime
    self._ShouldLoop = track.CanLoop
    return true
end

---@param self AnimationSourceClass
---@param track Track
---@return AnimationSource|nil
function AnimationSource:New(track)
    local instance = Thinker.New(self) --[[@as AnimationSource]]
    if not instance:_TrySetupEntity(track) or
        not instance:_TrySetupAnchor() or
        not instance:_TrySetupSequence(track) then
        instance:Remove()
        return nil
    end
    return instance
end

---@param self AnimationSource
---@return Vector
function AnimationSource:GetPos()
    local pos, _ = self._Ent:GetBonePosition(self._AnchorID)
    return pos
end

---@param self AnimationSource
function AnimationSource:_RecordStartPos()
    if not self._Ent:IsValid() then
        self:Remove()
        return
    end
    self._StartPos = self:GetPos()
end

---@param self AnimationSource
function AnimationSource:Play()
    self._Ent:ResetSequence(self._SequenceID)
    self._Ent:ResetSequenceInfo()
    self._Ent:SetCycle(0)

    timer.Simple(0, function ()
        self:_RecordStartPos()
    end)
end

-- 循环播放时，把根骨在一轮里累积的水平位移转移到实体上，避免循环处骨骼回跳。
--
-- 背景：
--   Blender 里 Object 可以完全不动，只有根骨在动画里走。
--   导入 Source 后表现为：
--
--       self._Ent:GetPos()                 全程不变
--       self._Ent:GetBonePosition(_AnchorID)  每帧在变
--
-- 时序：
--   T0            Play() → ResetSequence 到第 0 帧
--   T0 + 1 帧     _RecordStartPos() 采样，此时 BonePos = v1，Ent:GetPos() = e1
--   播放中         Ent 不动，骨骼局部偏移随动画变化，BonePos = v2
--   到达 EndTime   _Think 触发
--
-- 如果没有本函数：
--   直接 Play() → ResetSequence → 骨骼局部偏移回到初值
--   → BonePos = e1 + 初值 = v1
--   视觉上骨骼从 v2 瞬间跳回 v1，循环处一顿。
--
-- 有了本函数：
--   delta2D = (v2 - v1) 的水平分量
--   Ent:SetPos(e1 + delta2D)，然后 Play()
--   → 新的 BonePos 水平上与 v2 对齐，循环处不跳。
--
-- 为什么只取水平分量：
--   垂直方向有意留给动画本身控制，避免实体在 z 上累积漂移。
--
-- 注：_StartPos 存的是骨骼世界坐标，不是实体坐标，和 _Ent:GetPos() 不同坐标系。
---@param self AnimationSource
function AnimationSource:_ApplyRootMotion()
    local endPos = self:GetPos()
    local delta = endPos - self._StartPos
    local delta2D = Vector(delta.x, delta.y, 0)
    self._Ent:SetPos(self._Ent:GetPos() + delta2D)
end

---@param self AnimationSource
function AnimationSource:_Think()
    local now = CurTime()
    if now < self._EndTime then return end
    if not self._Ent:IsValid() or not self._ShouldLoop then
        self:Remove()
        return
    end
    self:_ApplyRootMotion()
    self:Play()
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self._Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
