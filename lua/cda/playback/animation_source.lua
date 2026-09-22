-- lua/cda/playback/animation_source.lua
--
-- AnimationSource —— 单次播放一段动画，输出下一轮起点。
--
-- 职责边界：
--   * 只负责一次播放。生命周期 = 从 New 到 _Finish。
--   * 不管理 loop —— loop 是上层编排的事（Remove 旧的 + 从 nextPos New 新的）。
--   * 不自行 Remove —— 结束后设 _Finished 并回调，由上层决定何时回收。
--
-- 输出：
--   * _NextPos —— 一次播放结束时，若要以本轮终点无缝衔接下一轮，
--     下一轮 Track.Pos 应该是什么。上层直接用它 New 新的 AnimationSource
--     即可。垂直分量已包含（实体 z 已由地形跟随放到正确高度）。
--
-- 设计推演与日志证据见 docs/animation_source_timing.md。
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
-- 详见 docs/animation_source_timing.md 的「垂直通道：地形跟随」。
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

    -- Pos / Ang 必须在 Spawn 之前设置——Spawn 是引擎建立骨骼世界矩阵的
    -- 时刻，此时设位置一次到位。
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
---@field _Duration number          内容时长（秒），New 时确定
---@field _EndTime number           结束时刻，Play 时重算
---@field _BaseRootPos Vector       起点根骨世界坐标（基线）
---@field _BaseGroundZ number|nil   起点地面高度（基线）
---@field _BaseEntZ number|nil      起点实体 z（基线）
---@field _Finished boolean
---@field _NextPos Vector|nil       下一轮起点（未完成时 nil）
---@field _OnFinished fun(nextPos: Vector)|nil
---@field _LastLogTime number
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupRootBone fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupBaseline fun(self: AnimationSource): boolean
---@field _ApplyGroundFollow fun(self: AnimationSource)
---@field _Finish fun(self: AnimationSource, nextPos: Vector)
---@field GetRootBonePos fun(self: AnimationSource): Vector

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

-- ============================================================================
-- _TrySetup* 系列
-- ============================================================================
-- 契约：建立某种初始状态。失败返回 false，调用方决定是否回收。
-- 前三个在构造期调用；_TrySetupBaseline 在 Play 之后调用。
-- ----------------------------------------------------------------------------

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_TrySetupEntity(track)
    local ent = acquireEntity(track.ModelName, track.Pos, track.Ang)
    if not ent then return false end

    self._Ent = ent
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

    self._SequenceID = sequenceID
    self._SequenceName = track.SequenceName
    self._Duration = track.Duration or sequenceDuration or math.huge
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

--- 根骨世界坐标。不是 _Ent:GetPos()。
--- 两者关系详见 docs/animation_source_timing.md 的「两个 pos 的关系」。
---@param self AnimationSource
---@return Vector
function AnimationSource:GetRootBonePos()
    local pos, _ = self._Ent:GetBonePosition(self._RootBoneID)
    return pos
end

--- 是否已完成本次播放。
---@param self AnimationSource
---@return boolean
function AnimationSource:IsFinished()
    return self._Finished == true
end

--- 下一轮起点。未完成时返回 nil。
---
--- 语义：上层若要以本轮终点无缝衔接下一轮，用此值作为下一轮 Track.Pos。
--- 垂直分量已包含——实体 z 已由 _ApplyGroundFollow 放到正确高度。
---@param self AnimationSource
---@return Vector|nil
function AnimationSource:GetNextPos()
    return self._NextPos
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

--- 建立本轮基线：_BaseRootPos / _BaseGroundZ / _BaseEntZ。
---
--- 若实体失效返回 false；若此刻射线 miss，地面基线留 nil，由
--- _ApplyGroundFollow 下一帧惰性建立。
---
--- 为什么基线要与 _BaseRootPos 同一时刻采样、为什么用基线而非差分，
--- 详见 docs/animation_source_timing.md 的「垂直通道：地形跟随」。
---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TrySetupBaseline()
    if not self._Ent:IsValid() then return false end

    local rootPos = self:GetRootBonePos()
    self._BaseRootPos = rootPos

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

--- 开始本次播放。
---
--- ResetSequence 是同步 Lua API（非 Fire），立即生效。但仍需等一帧让骨骼
--- 世界矩阵重算——Spawn 时的矩阵是针对 Spawn 时的 sequence 状态。
--- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
---
--- onFinished 只在正常完成或实体失效时触发一次。nextPos 是下一轮起点
--- （Vector(0,0,0) 表示失败或无位移）。AnimationSource 不自行 Remove——
--- 由上层决定何时回收。
---@param self AnimationSource
---@param onFinished fun(nextPos: Vector)|nil
function AnimationSource:Play(onFinished)
    self._OnFinished = onFinished
    self._Finished = false
    self._NextPos = nil

    self._Ent:ResetSequence(self._SequenceID)

    self._EndTime = CurTime() + self._Duration

    timer.Simple(0, function ()
        if not self:_TrySetupBaseline() then
            self:Remove()
        end
    end)
end

-- ============================================================================
-- 垂直通道：地形跟随
-- ============================================================================

--- 每帧从根骨位置向下打射线测地面，用基线公式算目标 z 并应用到实体。
---
--- 为什么参考点是根骨位置而非实体位置、为什么用基线而非差分、
--- 为什么动画自身的垂直起伏不污染信号、GROUND_EPSILON 的存在理由，
--- 详见 docs/animation_source_timing.md 的「垂直通道：地形跟随」。
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
        "[AnimationSource] %s t=%.3f entPos=%s rootPos=%s baseRootPos=%s baseGZ=%s baseEZ=%s endTime=%.3f finished=%s",
        tag, now,
        tostring(self._Ent:GetPos()),
        tostring(self:GetRootBonePos()),
        tostring(self._BaseRootPos),
        tostring(self._BaseGroundZ),
        tostring(self._BaseEntZ),
        self._EndTime,
        tostring(self._Finished)))
end

--- 完成本次播放。幂等——只在首次调用时触发回调。
---@param self AnimationSource
---@param nextPos Vector
function AnimationSource:_Finish(nextPos)
    if self._Finished then return end

    self._Finished = true
    self._NextPos = nextPos

    -- 先清回调再调用——避免回调里重入 _Finish。
    local cb = self._OnFinished
    self._OnFinished = nil

    self:_LogState("finish", CurTime())

    if cb then cb(nextPos) end
end

---@param self AnimationSource
function AnimationSource:_Think()
    -- 每帧地形跟随——早退前执行，保证整个播放期间连续生效。
    self:_ApplyGroundFollow()

    if self._Finished then return end

    local now = CurTime()

    if now - (self._LastLogTime or 0) >= LOG_INTERVAL then
        self._LastLogTime = now
        self:_LogState("tick", now)
    end

    if not self._Ent:IsValid() then
        self:_Finish(self._Ent and self._Ent:GetPos() or Vector(0, 0, 0))
        return
    end

    if now < self._EndTime then return end

    -- 算下一轮起点：实体当前位置 + 根骨水平位移。
    -- 垂直方向 _ApplyGroundFollow 已把实体 z 放到正确高度，直接用。
    -- 推导见 docs/animation_source_timing.md 的「水平通道：根运动转移」。
    local endPos = self:GetRootBonePos()
    local delta = endPos - self._BaseRootPos
    local delta2D = Vector(delta.x, delta.y, 0)
    local nextPos = self._Ent:GetPos() + delta2D

    self:_Finish(nextPos)
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self._Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
