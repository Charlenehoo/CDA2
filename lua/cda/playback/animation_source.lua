-- lua/cda/playback/animation_source.lua
--
-- AnimationSource —— 播放一段动画，并把动画自带的位移转移到实体上。
--
-- 所有机制的详细推演与日志证据见 docs/animation_source_timing.md。
-- 本文件注释只写简要说明 + 引用章节名。

local Constants = include("cda/core/constants.lua")
local log = include("cda/core/log/init.lua")

local ADDON_NAME = Constants.ADDON_NAME
local MODULE_NAME = "AnimationSource"
local KEY = ADDON_NAME .. "_" .. MODULE_NAME
if package.loaded[KEY] then
    return package.loaded[KEY]
end

-- 调试打印间隔（秒）。
local LOG_INTERVAL = 0.25

-- 地形高度变化低于此值视为噪声，不修正 z。
-- 详见 docs/animation_source_timing.md 的「垂直通道：_ApplyGroundFollow」。
local GROUND_EPSILON = 0.01

-- ============================================================================
-- 实体创建 / 销毁
-- ============================================================================

---@param modelName string
---@param pos Vector
---@param ang Angle|nil
---@return Entity|nil
local function acquireEntity(modelName, pos, ang)
    if type(modelName) ~= "string" or not util.IsValidModel(modelName) then return nil end

    local ent = ents.Create("prop_dynamic")
    if not IsValid(ent) then return nil end

    ent:SetModel(modelName)

    -- Pos / Ang 必须在 Spawn 之前设置——Spawn 是引擎建立骨骼世界矩阵的时刻，
    -- 此时设位置一次到位，避免后续 GetBonePosition 读到旧坐标系。
    -- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
    if pos then ent:SetPos(pos) end
    if ang then ent:SetAngles(ang) end

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
---@field _SequenceName string
---@field _RootBoneID number
---@field _ShouldLoop boolean
---@field _Duration number          本轮内容时长（秒），New 时确定
---@field _EndTime number           本轮结束时刻，Play 时重算
---@field _BaseRootPos Vector       本轮起点的根位置（世界坐标）
---@field _BaseGroundZ number|nil   本轮起点地面高度
---@field _BaseEntZ number|nil      本轮起点实体 z
---@field _LastLogTime number
---@field _LoopCount number
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupRootBone fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupBaseline fun(self: AnimationSource): boolean
---@field _ApplyRootMotion fun(self: AnimationSource)
---@field _ApplyGroundFollow fun(self: AnimationSource)
---@field GetRootBonePos fun(self: AnimationSource): Vector
---@field Play fun(self: AnimationSource)

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

-- ============================================================================
-- _TrySetup* 系列
-- ============================================================================
-- 契约：建立某种初始状态。失败返回 false，调用方决定是否回收。
-- 前三个在构造期调用；最后一个在每轮循环起点调用。
-- ----------------------------------------------------------------------------

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_TrySetupEntity(track)
    local ent = acquireEntity(track.ModelName, track.Pos, track.Ang)
    if not ent then return false end

    self._Ent = ent
    self._LoopCount = 0
    self._LastLogTime = 0
    return true
end

local PELVIS = "ValveBiped.Bip01_Pelvis"

---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TrySetupRootBone()
    local id = self._Ent:LookupBone(PELVIS)
    if not id or type(id) ~= "number" or id < 0 then
        return false
    end
    self._RootBoneID = id
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

    -- _Duration 是常量（内容时长），_EndTime 是派生值（每次 Play 重算）。
    -- 若 _EndTime 只在 New 里写一次，循环重播时会立即再次触发。
    -- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
    self._SequenceID = sequenceID
    self._SequenceName = track.SequenceName
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
        not instance:_TrySetupRootBone() or
        not instance:_TrySetupSequence(track) then
        instance:Remove()
        return nil
    end
    return instance
end

-- ============================================================================
-- 公开查询
-- ============================================================================

--- 返回根骨骼的世界坐标。
---
--- 注意：不是 _Ent:GetPos()。两者关系详见
--- docs/animation_source_timing.md 的「两个 pos 的关系」。
---@param self AnimationSource
---@return Vector
function AnimationSource:GetRootBonePos()
    local pos, _ = self._Ent:GetBonePosition(self._RootBoneID)
    return pos
end

-- ============================================================================
-- 基线建立
-- ============================================================================

---@param ent Entity
---@param rootPos Vector
---@return number|nil groundZ
local function traceGroundZ(ent, rootPos)
    local trace = util.TraceLine({
        start  = rootPos + Vector(0, 0, 10),
        endpos = rootPos - Vector(0, 0, 100),
        mask   = MASK_SOLID,
        filter = { ent },
    })
    if not trace.Hit then return nil end
    return trace.HitPos.z
end

--- 每轮循环起点调用。建立 _BaseRootPos / _BaseGroundZ / _BaseEntZ。
---
--- 若实体失效返回 false；若此刻射线 miss，基线留 nil，由 _ApplyGroundFollow
--- 下一帧惰性建立。
---
--- 为什么基线要与 _BaseRootPos 同一时刻采样、为什么用基线而非差分，
--- 详见 docs/animation_source_timing.md 的「垂直通道：_ApplyGroundFollow」。
---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TrySetupBaseline()
    if not self._Ent:IsValid() then return false end

    local rootPos = self:GetRootBonePos()
    self._BaseRootPos = rootPos

    -- 每轮重新建立地面基线——旧基线会污染新一轮的绝对位置。
    self._BaseGroundZ = nil
    self._BaseEntZ = nil

    if rootPos then
        local groundZ = traceGroundZ(self._Ent, rootPos)
        if groundZ then
            self._BaseGroundZ = groundZ
            self._BaseEntZ = self._Ent:GetPos().z
        end
    end

    return true
end

-- ============================================================================
-- 播放
-- ============================================================================

---@param self AnimationSource
function AnimationSource:Play()
    -- 用 Fire 系列而非 ResetSequence + SetCycle(0)。后者在 prop_dynamic 上
    -- 会让动画停在最后一帧不循环。
    -- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
    self._Ent:Fire("SetPlaybackRate", 1)
    self._Ent:Fire("SetAnimation", self._SequenceName, 0)

    -- 每次 Play 都是新一轮，重算结束时刻（_Duration 是常量）。
    self._EndTime = CurTime() + self._Duration

    -- Fire 走 IO 队列，帧末生效。_TrySetupBaseline 里的 GetBonePosition
    -- 必须等新序列生效——timer.Simple(0, ...) 是最早的安全时机。
    -- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
    timer.Simple(0, function ()
        if not self:_TrySetupBaseline() then
            self:Remove()
        end
    end)
end

-- ============================================================================
-- 水平通道：根运动转移
-- ============================================================================

--- 一轮结束时把根骨累积的水平位移转移到实体上，避免循环处骨骼回跳。
---
--- 为什么只取水平分量、为什么参考点是 _BaseRootPos，
--- 详见 docs/animation_source_timing.md 的「水平通道：_ApplyRootMotion」。
---@param self AnimationSource
function AnimationSource:_ApplyRootMotion()
    local endPos = self:GetRootBonePos()
    local delta = endPos - self._BaseRootPos
    local delta2D = Vector(delta.x, delta.y, 0)
    self._Ent:SetPos(self._Ent:GetPos() + delta2D)
end

-- ============================================================================
-- 垂直通道：地形跟随
-- ============================================================================

--- 每帧从根骨位置向下打射线测地面，用基线公式算目标 z 并应用到实体。
---
--- 为什么参考点是根骨位置而非实体位置、为什么用基线而非差分、
--- 为什么动画自身的垂直起伏不污染信号、GROUND_EPSILON 的存在理由，
--- 详见 docs/animation_source_timing.md 的「垂直通道：_ApplyGroundFollow」。
---@param self AnimationSource
function AnimationSource:_ApplyGroundFollow()
    if not self._Ent:IsValid() then return end

    local rootPos = self:GetRootBonePos()
    if not rootPos then return end

    local groundZ = traceGroundZ(self._Ent, rootPos)
    if not groundZ then return end

    -- 惰性建立：_TrySetupBaseline 时射线 miss（悬空），此处补建。
    if not self._BaseGroundZ then
        self._BaseGroundZ = groundZ
        self._BaseEntZ = self._Ent:GetPos().z
        return
    end

    local diff = groundZ - self._BaseGroundZ
    if math.abs(diff) < GROUND_EPSILON then return end

    local entPos = self._Ent:GetPos()
    local newZ = self._BaseEntZ + diff
    self._Ent:SetPos(Vector(entPos.x, entPos.y, newZ))
end

-- ============================================================================
-- 主循环
-- ============================================================================

---@param self AnimationSource
function AnimationSource:_LogState(tag, now)
    log.debug(string.format(
        "[AnimationSource] %s t=%.3f entPos=%s rootPos=%s baseRootPos=%s baseGZ=%s baseEZ=%s endTime=%.3f loop=%d",
        tag, now,
        tostring(self._Ent:GetPos()),
        tostring(self:GetRootBonePos()),
        tostring(self._BaseRootPos),
        tostring(self._BaseGroundZ),
        tostring(self._BaseEntZ),
        self._EndTime,
        self._LoopCount or 0))
end

---@param self AnimationSource
function AnimationSource:_Think()
    -- 每帧地形跟随——早退前执行，保证整个播放期间连续生效。
    self:_ApplyGroundFollow()

    local now = CurTime()

    if now - (self._LastLogTime or 0) >= LOG_INTERVAL then
        self._LastLogTime = now
        self:_LogState("tick", now)
    end

    if now < self._EndTime then return end
    if not self._Ent:IsValid() or not self._ShouldLoop then
        self:Remove()
        return
    end

    -- 循环点：先水平转移，再开新一轮。
    -- 顺序不能反——_ApplyRootMotion 必须在本帧内完成，否则下一轮
    -- _TrySetupBaseline 采样的 _BaseRootPos 会带上未转移的水平位移。
    self:_LogState("loop-before", now)

    self:_ApplyRootMotion()
    self._LoopCount = (self._LoopCount or 0) + 1

    self:_LogState("loop-after", now)

    self:Play()
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    log.debug(string.format(
        "[AnimationSource] removing entPos=%s loops=%d",
        tostring(self._Ent and self._Ent:GetPos()),
        self._LoopCount or 0))

    releaseEntity(self._Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
