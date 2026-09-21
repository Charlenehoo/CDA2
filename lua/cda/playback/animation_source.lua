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
---@field _Duration number
---@field _EndTime number
---@field _StartPos Vector
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupAnchor fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _TryRecordStartPos fun(self: AnimationSource): boolean
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
    self._SequenceID = sequenceID
    self._Duration = track.Duration or sequenceDuration or math.huge
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
---@return boolean ok
function AnimationSource:_TryRecordStartPos()
    if not self._Ent:IsValid() then
        return false
    end
    self._StartPos = self:GetPos()
    return true
end

---@param self AnimationSource
function AnimationSource:Play()
    self._EndTime = CurTime() + self._Duration
    self._Ent:ResetSequence(self._SequenceID)
    self._Ent:ResetSequenceInfo()
    self._Ent:SetCycle(0)
    timer.Simple(0, function ()
        if not self._Ent:IsValid() then
            self:Remove()
            return
        end
        self._StartPos = self:GetPos()
    end)
end

-- 每帧从骨骼位置向下打射线，测地面高度，把地面高度变化应用到实体 z 上。
--
-- 为什么参考点是骨骼位置，而不是实体位置：
--   * 根运动机制下，实体位置在循环内是锚点 e1——在 _ApplyRootMotion 执行前
--     它一直不动。用它当参考，等于假设"视觉对象不动"，与 draw 场景矛盾。
--   * 视觉上真正在哪儿由骨骼表达：BonePos = e1 + 骨骼局部偏移，每帧都在变。
--     射线从骨骼位置出发，捕捉的才是视觉立足点下方的地面。
--
-- 与 EDAE2 OneShot 的差异：
--   * OneShot 里 prop_dynamic 是 no draw，只作驱动源；视觉是 ragdoll，
--     贴地由 ragdoll 物理完成。所以 OneShot 用固定的 model:GetPos().z
--     作参考高度，配合 lastHitZ / lastAddZ 累积出"骨骼相对原点的偏移量"，
--     再由 ragdoll 物理体现。
--   * AnimationSource 里 self._Ent 是 draw 的，它就是视觉对象。没有下游
--     物理替它贴地，因此它的 z 必须主动跟随地形。
--
-- 算法：
--   * 射线起点 = 骨骼位置 + (0,0,10)，终点 = 骨骼位置 - (0,0,100)。
--   * 命中得 groundZ。
--   * diff = groundZ - _LastGroundZ，直接加到实体 z 上。
--   * 首次调用只记录 _LastGroundZ，不做修正——避免把第一帧的绝对高度
--     当作变化量。
--
-- 为什么不需要 lastAddZ 式的累积：
--   * OneShot 的 lastAddZ 累积的是"骨骼相对固定原点的偏移量"，
--     最终由 ragdoll 物理表达。
--   * 这里直接改实体 z，每帧的 diff 就是增量，不需要再累积。
--
-- 为什么动画自身的垂直起伏不会污染信号：
--   * 骨骼在局部空间上下浮动时，射线起点随之浮动，但地面高度不变，
--     groundZ 不变，diff = 0，不修正。
--   * 只有地形本身变化（骨骼水平漂移到不同地面高度）才产生非零 diff。
---@param self AnimationSource
function AnimationSource:_TraceGround()
    if not self._Ent:IsValid() then return end

    local bonePos = self:GetPos()
    if not bonePos then return end

    local trace = util.TraceLine({
        start  = bonePos + Vector(0, 0, 10),
        endpos = bonePos - Vector(0, 0, 100),
        mask   = MASK_SOLID,
        filter = { self._Ent },
    })
    if not trace.Hit then return end

    local groundZ = trace.HitPos.z

    if not self._LastGroundZ then
        self._LastGroundZ = groundZ
        return
    end

    local diff = groundZ - self._LastGroundZ
    self._LastGroundZ = groundZ

    if diff ~= 0 then
        self._Ent:SetPos(self._Ent:GetPos() + Vector(0, 0, diff))
    end
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
--   T0 + 1 帧     _TryRecordStartPos() 采样，此时 BonePos = v1，Ent:GetPos() = e1
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
