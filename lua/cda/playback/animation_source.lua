-- lua/cda/playback/animation_source.lua
--
-- AnimationSource —— 单次播放一段动画，输出本次播放的最终位置。
--
-- 职责边界：
--   * 只负责一次播放。生命周期 = 从 New 到 _Finish。
--   * 不管理 loop —— loop 是上层编排的事（Remove 旧的 + 从 endPos New 新的）。
--   * 不自行 Remove —— 结束后设 _Finished 并回调，由上层决定何时回收。
--
-- 输出：
--   * _EndPos —— 本次播放结束时，若要以本轮终点无缝衔接下一轮，
--     下一轮的 Track.Pos 应该是什么。上层直接用它 New 新的 AnimationSource
--     即可。垂直分量已包含（实体 z 已由地形跟随放到正确高度）。
--
-- 播放速率：
--   * 速率由 Track.PlaybackRate 指定，默认 1。
--   * 运行时可经 SetPlaybackRate 修改——不变量是内容进度（rate 对时间的积分），
--     而非结束时刻。进度是连续单调的，rate 分段变化不破坏它。
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

local LOG_INTERVAL = 0.25
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

    -- Pos / Ang 必须在 Spawn 之前设置。
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
---@field _Ent Entity                          动画实体；对应 Blender 的 Object
---@field _SequenceName string                 动画序列名，供 Fire("SetAnimation") 使用
---@field _RootBoneID number                   根骨骼 ID（骨盆）；视觉立足点
---@field _Duration number                     内容时间轴长度（秒）——动画自身播完需要消耗多少内容时间，与速率无关
---@field _Rate number                         内容时间 / 真实时间的转换率，默认 1
---@field _ContentProgress number              内容时间轴上的当前位置（秒）——rate 对真实时间的积分，从 0 走到 _Duration
---@field _BaseRootPos Vector                  起点根骨世界坐标；水平通道的增量基准
---@field _BaseGroundZ number|nil              起点地面高度；与 _BaseEntZ 同一时刻采样
---@field _BaseEntZ number|nil                 起点实体 z；与 _BaseGroundZ 同一时刻采样
---@field _Finished boolean                    是否已完成；防止 _Finish 重入
---@field _EndPos Vector|nil                   本次播放结束时的输出位置
---@field _OnFinished fun(endPos: Vector)|nil  完成回调；只在 _Finish 首次调用时触发一次
---@field _LastLogTime number                  上次 trace 日志的时刻，用于日志节流
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupRootBone fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupBaseline fun(self: AnimationSource): boolean
---@field _ApplyGroundFollow fun(self: AnimationSource)
---@field _Finish fun(self: AnimationSource, endPos: Vector)
---@field GetRootBonePos fun(self: AnimationSource): Vector|nil

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
    -- sequenceID 只用于判有效性，不必存字段——Play 走 Fire("SetAnimation", name)。

    local rate = track.PlaybackRate or 1
    if type(rate) ~= "number" or rate <= 0 then
        rate = 1
    end

    self._SequenceName = track.SequenceName
    self._Duration = track.Duration or sequenceDuration or math.huge
    self._Rate = rate
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
---@return Vector|nil
function AnimationSource:GetRootBonePos()
    if not IsValid(self._Ent) then return nil end
    local pos, _ = self._Ent:GetBonePosition(self._RootBoneID)
    return pos
end

---@param self AnimationSource
---@return boolean
function AnimationSource:IsFinished()
    return self._Finished == true
end

--- 本次播放结束时的输出位置。未完成时返回 nil。
---
--- 语义：上层若要以本轮终点无缝衔接下一轮，用此值作为下一轮 Track.Pos。
--- 垂直分量已包含——实体 z 已由 _ApplyGroundFollow 放到正确高度。
---@param self AnimationSource
---@return Vector|nil
function AnimationSource:GetEndPos()
    return self._EndPos
end

--- 当前播放速率。
---@param self AnimationSource
---@return number
function AnimationSource:GetPlaybackRate()
    return self._Rate or 1
end

-- ============================================================================
-- 公开 API：运行时调参
-- ============================================================================

--- 设置播放速率（运行时调节）。
---
--- 不变量是内容进度（_ContentProgress）——它是 rate 对时间的积分，
--- 已累积的部分不因 rate 变化而改变，后续累积按新速率走。
--- 因此无需重算任何时刻，只需更新 _Rate 并通知引擎。
---
--- 边界：rate <= 0 拒绝。0 的语义是"暂停"，应由独立 Pause 接口承担。
---
--- 若在 Play 之前调用：只更新 _Rate；Play 时会用新速率初始化引擎。
--- 若在 Play 之后调用：同时 Fire 给引擎，立即生效。
---@param self AnimationSource
---@param rate number
---@return boolean ok
function AnimationSource:SetPlaybackRate(rate)
    if type(rate) ~= "number" or rate <= 0 then return false end

    self._Rate = rate

    if IsValid(self._Ent) then
        self._Ent:Fire("SetPlaybackRate", rate)
    end

    return true
end

-- ============================================================================
-- 日志
-- ============================================================================

---@param self AnimationSource
---@param level string
---@param tag string
---@param now number
function AnimationSource:_LogState(level, tag, now)
    if not IsValid(self._Ent) then return end
    log[level](string.format(
        "[AnimationSource] %s t=%.3f entPos=%s rootPos=%s baseRootPos=%s baseGZ=%s baseEZ=%s progress=%.3f/%.3f rate=%.2f finished=%s",
        tag, now,
        tostring(self._Ent:GetPos()),
        tostring(self:GetRootBonePos()),
        tostring(self._BaseRootPos),
        tostring(self._BaseGroundZ),
        tostring(self._BaseEntZ),
        self._ContentProgress or 0,
        self._Duration or 0,
        self._Rate or 1,
        tostring(self._Finished)))
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
--- 为什么基线要与 _BaseRootPos 同一时刻采样、为什么用基线而非差分，
--- 详见 docs/animation_source_timing.md 的「垂直通道：地形跟随」。
---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TrySetupBaseline()
    if not IsValid(self._Ent) then return false end

    local rootPos = self:GetRootBonePos()
    if not rootPos then return false end

    self._BaseRootPos = rootPos

    self._BaseGroundZ = nil
    self._BaseEntZ = nil

    local groundZ = traceGroundZ(self._Ent, rootPos)
    if groundZ then
        self._BaseGroundZ = groundZ
        self._BaseEntZ = self._Ent:GetPos().z
    end

    self:_LogState("debug", "init", CurTime())

    return true
end

-- ============================================================================
-- 播放
-- ============================================================================

--- 开始本次播放。
---
--- 用 Fire 系列而非 ResetSequence：实测 ResetSequence 在 prop_dynamic 上
--- 不会自动播放——playback rate 保持 0，动画冻结在第 0 帧。
--- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
---
--- 两层 timer：
---   第一层等 IO 生效（SetAnimation 应用到实体）。
---   第二层等骨骼姿势重算——单层 timer 采到的仍是旧序列残留的姿势。
--- 详见 docs/animation_source_timing.md 的「干预过程中的时序问题」。
---
--- 结束后触发 onFinished(endPos) 一次。endPos 是本次播放的输出位置
--- （见 GetEndPos 的说明）。AnimationSource 不自行 Remove——由上层决定。
---@param self AnimationSource
---@param onFinished fun(endPos: Vector)|nil
function AnimationSource:Play(onFinished)
    self._OnFinished = onFinished
    self._Finished = false
    self._EndPos = nil
    self._ContentProgress = 0

    self._Ent:Fire("SetPlaybackRate", self._Rate or 1)
    self._Ent:Fire("SetAnimation", self._SequenceName, 0)

    timer.Simple(0, function ()
        if not IsValid(self._Ent) then
            self:Remove()
            return
        end
        timer.Simple(0, function ()
            if not self:_TrySetupBaseline() then
                self:Remove()
            end
        end)
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
    if not IsValid(self._Ent) then return end

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

--- 完成本次播放。幂等——只在首次调用时触发回调。
---@param self AnimationSource
---@param endPos Vector
function AnimationSource:_Finish(endPos)
    if self._Finished then return end

    self._Finished = true
    self._EndPos = endPos

    local cb = self._OnFinished
    self._OnFinished = nil

    self:_LogState("debug", "finish", CurTime())

    if cb then cb(endPos) end
end

---@param self AnimationSource
function AnimationSource:_Think()
    if self._Finished then return end

    self:_ApplyGroundFollow()

    if not IsValid(self._Ent) then
        self:_Finish(Vector(0, 0, 0))
        return
    end

    -- 内容进度按 rate 积分累加。rate 分段变化时，已累积部分不变，
    -- 后续按新 rate 走——这是"积分"的语义。
    local dt = FrameTime()
    if dt > 0 then
        self._ContentProgress = (self._ContentProgress or 0) + dt * (self._Rate or 1)
    end

    local now = CurTime()
    if now - (self._LastLogTime or 0) >= LOG_INTERVAL then
        self._LastLogTime = now
        self:_LogState("trace", "tick", now)
    end

    if self._ContentProgress < self._Duration then return end

    -- 算本次播放的输出位置：
    --   水平 = 终点根骨位置 - 起点根骨位置 + 起点实体位置
    --        （详见 docs/animation_source_timing.md 的「水平通道」）
    --   垂直 = 保留当前实体 z（地形跟随已处理，详见「垂直通道」）
    local endPos = self:GetRootBonePos()
    local entPos = self._Ent:GetPos()
    if not endPos then
        self:_Finish(entPos)
        return
    end

    local delta = endPos - self._BaseRootPos
    local delta2D = Vector(delta.x, delta.y, 0)
    local outPos = entPos + delta2D

    self:_Finish(outPos)
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    if IsValid(self._Ent) then
        log.debug(string.format(
            "[AnimationSource] removing entPos=%s",
            tostring(self._Ent:GetPos())))
    end

    releaseEntity(self._Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
