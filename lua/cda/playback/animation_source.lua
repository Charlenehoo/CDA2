-- lua/cda/playback/animation_source.lua

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

-- AnimationSource —— 播放一段动画，并把动画自带的位移转移到实体上。
--
-- 核心问题：
--   Blender 里 Object 可以完全不动，只有根骨在动画里走。导入 Source 后表现为：
--       self._Ent:GetPos()                    实体原点全程不变
--       self._Ent:GetBonePosition(_AnchorID)  骨骼世界位置每帧在变
--   如果什么都不做，下一轮循环 ResetSequence 时骨骼会瞬移回动画第一帧的
--   局部偏移，视觉上"一顿"。
--
-- 解决方案（水平 + 垂直，两条独立通道）：
--   * 水平：_ApplyRootMotion —— 一轮结束时把根骨累积的水平位移转移到实体
--     x/y 上，让下一轮骨骼起点与这一轮终点对齐。
--   * 垂直：_TraceGround —— 每帧从骨骼位置向下打射线测地形高度，让实体 z
--     跟随地形。不做差分累积，用基线法避免浮点漂移。
--
-- 与 EDAE2 OneShot 的关键差异（重要）：
--   OneShot 的 prop_dynamic 是 no draw 的，它只作"驱动源"，视觉对象是
--   ragdoll 本身；贴地由 ragdoll 物理完成。AnimationSource 的 _Ent 是
--   draw 的，它就是视觉对象——没有下游物理替它贴地，所以它的 z 必须主动
--   跟随地形。
--
-- 私有字段（_PascalCase 约定）：
--   所有实例状态都私有。公开接口只有 New / Remove / Play / GetPos。

---@class AnimationSource:Thinker
---@field _Ent Entity
---@field _SequenceID number
---@field _SequenceName string
---@field _AnchorID number
---@field _ShouldLoop boolean
---@field _Duration number          本轮内容时长（秒），New 时确定
---@field _EndTime number           本轮结束时刻（CurTime 基准），Play 时重算
---@field _StartPos Vector          本轮骨骼起点世界坐标，_TryInitLoop 时采样
---@field _BaseGroundZ number|nil   基线：本轮起点处的地面高度
---@field _BaseEntZ number|nil      基线：本轮起点处的实体 z
---@field _TrySetupEntity fun(self: AnimationSource, track: Track): boolean
---@field _TrySetupAnchor fun(self: AnimationSource): boolean
---@field _TrySetupSequence fun(self: AnimationSource, track: Track): boolean
---@field _TryInitLoop fun(self: AnimationSource): boolean
---@field _ApplyRootMotion fun(self: AnimationSource)
---@field _TraceGround fun(self: AnimationSource)
---@field GetPos fun(self: AnimationSource): Vector
---@field Play fun(self: AnimationSource)

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

-- ============================================================================
-- 构造期的 _TrySetup* 系列
-- ============================================================================
-- 契约：尝试做一件事；失败返回 false，由调用方（New）决定是否回收。
-- 命名用 _TrySetup* 而非 _Update* —— 它们只在构造期调用一次，
-- 是"建立初始状态"，不是"更新已有状态"。
-- ----------------------------------------------------------------------------

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

    -- 存名字而不只是 ID —— Play 里走 Fire("SetAnimation", name, 0)。
    -- 原因：ResetSequence + SetCycle(0) 在 prop_dynamic 上会让动画停在
    -- 最后一帧不循环；Fire 系列是 EDAE2 OneShot 验证过的路径。
    self._SequenceID = sequenceID
    self._SequenceName = track.SequenceName

    -- _Duration 与 _EndTime 分离：
    --   * _Duration 是常量，New 时确定，代表"内容播完需要多久"
    --   * _EndTime 是派生值，每次 Play 重算（CurTime() + _Duration）
    -- 循环播放时若 _EndTime 只在 New 里写一次，第二轮 _Think 会立刻
    -- 触发重播，导致每帧 ResetSequence——骨骼永远停在第 0 帧。
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

-- ============================================================================
-- 公开查询
-- ============================================================================

---@param self AnimationSource
---@return Vector
function AnimationSource:GetPos()
    local pos, _ = self._Ent:GetBonePosition(self._AnchorID)
    return pos
end

-- ============================================================================
-- 循环初始化
-- ============================================================================
-- _TryInitLoop —— 每轮循环的初始化点。语义上替代了 _TryRecordStartPos。
--
-- 记录两样东西：
--   * _StartPos      —— 本轮骨骼起点世界坐标（_ApplyRootMotion 用）
--   * _BaseGroundZ / _BaseEntZ —— 本轮起点处的地面基线（_TraceGround 用）
--
-- 为什么基线要和 _StartPos 同一时刻采样：
--   _TraceGround 的 z 计算公式是
--       z = _BaseEntZ + (groundZ - _BaseGroundZ)
--   两个基线必须描述"同一瞬间"的 (地面, 实体) 快照，否则这个瞬间的
--   地形变化会被吞掉。
--
-- 为什么用基线而不是差分：
--   差分（每帧 z += g[i] - g[i-1]）等价于积分。浮点上 O(N·eps) 累积误差，
--   且依赖"上一帧 z 与上一帧 g 是同一时刻的一致状态"——任何外部改 z 都会
--   让下一帧 diff 出错。基线法每帧独立计算，无累积，对扰动免疫。
--
-- 失败语义：
--   若实体已失效返回 false，调用方 Remove。
--   若此刻射线 miss（悬空），基线留 nil，由 _TraceGround 下一帧惰性建立。
-- ----------------------------------------------------------------------------

---@param ent Entity
---@param bonePos Vector
---@return number|nil groundZ
local function traceGroundZ(ent, bonePos)
    local trace = util.TraceLine({
        start  = bonePos + Vector(0, 0, 10),
        endpos = bonePos - Vector(0, 0, 100),
        mask   = MASK_SOLID,
        filter = { ent },
    })
    if not trace.Hit then return nil end
    return trace.HitPos.z
end

---@param self AnimationSource
---@return boolean ok
function AnimationSource:_TryInitLoop()
    if not self._Ent:IsValid() then
        return false
    end

    local bonePos = self:GetPos()
    self._StartPos = bonePos

    -- 每轮重新建立基线。清 nil 是为了让下一段在悬空场景下也能正确
    -- 走"惰性建立"分支——残留的旧基线会污染新一轮的绝对位置。
    self._BaseGroundZ = nil
    self._BaseEntZ = nil

    if bonePos then
        local groundZ = traceGroundZ(self._Ent, bonePos)
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
    -- 用 Fire 系列而非 ResetSequence + ResetSequenceInfo + SetCycle(0)。
    -- 后一组 API 在 prop_dynamic 上会让动画停在最后一帧不循环；
    -- Fire 系列是 EDAE2 OneShot 验证过的播放路径。
    self._Ent:Fire("SetPlaybackRate", 1)
    self._Ent:Fire("SetAnimation", self._SequenceName, 0)

    -- 每次 Play 都是新的一轮播放周期，重算结束时刻。
    self._EndTime = CurTime() + self._Duration

    -- 为什么需要 timer.Simple(0, ...)：
    --   Fire("SetAnimation", ...) 走实体 IO 通道——请求排入 IO 队列，
    --   帧末才生效。_TryInitLoop 里的 GetBonePosition 必须等新序列生效
    --   才能拿到第 0 帧的骨骼位置。同步调用会读到旧序列的末帧位置或
    --   spawn 时的 T-pose。
    --   timer.Simple(0, ...) 的回调在下一帧开始触发——晚于帧末 IO 处理，
    --   早于任何后续业务代码。这是最早的安全时机。
    timer.Simple(0, function ()
        if not self:_TryInitLoop() then
            self:Remove()
        end
    end)
end

-- ============================================================================
-- 水平通道：根运动转移
-- ============================================================================

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
--   T0            Play() → Fire("SetAnimation", ...) 排入 IO 队列
--   T0 末         IO 生效，骨骼切到第 0 帧
--   T0 + 1 帧     _TryInitLoop 采样，BonePos = v1，Ent:GetPos() = e1
--   播放中         Ent 不动，骨骼局部偏移随动画变化，BonePos = v2
--   到达 EndTime   _Think 触发
--
-- 如果没有本函数：
--   Fire("SetAnimation") → 骨骼局部偏移回到初值
--   → BonePos = e1 + 初值 = v1
--   视觉上骨骼从 v2 瞬间跳回 v1，循环处一顿。
--
-- 有了本函数：
--   delta2D = (v2 - v1) 的水平分量
--   Ent:SetPos(e1 + delta2D)，然后 Play()
--   → 新的 BonePos 水平上与 v2 对齐，循环处不跳。
--
-- 为什么只取水平分量：
--   垂直方向由 _TraceGround 独立处理。若这里也带 z，会和地形跟随叠加，
--   造成 z 双重修正。
--
-- 注：_StartPos 存的是骨骼世界坐标，不是实体坐标，和 _Ent:GetPos() 不同坐标系。
---@param self AnimationSource
function AnimationSource:_ApplyRootMotion()
    local endPos = self:GetPos()
    local delta = endPos - self._StartPos
    local delta2D = Vector(delta.x, delta.y, 0)
    self._Ent:SetPos(self._Ent:GetPos() + delta2D)
end

-- ============================================================================
-- 垂直通道：地形跟随
-- ============================================================================

-- 每帧从骨骼位置向下打射线测地面高度，把地形高度变化应用到实体 z 上。
--
-- 参考点为什么是骨骼位置（_StartPos 的同类）而不是实体位置：
--   根运动机制下实体位置在循环内是锚点 e1——_ApplyRootMotion 前它不动。
--   用它当射线起点，等于假设"视觉对象不动"，与 draw 场景矛盾。
--   视觉上真正在哪儿由骨骼表达：BonePos = e1 + 骨骼局部偏移，每帧在变。
--   射线从骨骼位置出发，捕捉的才是视觉立足点下方的地面。
--
-- 算法（基线法，非差分）：
--   * 射线起点 = 骨骼位置 + (0,0,10)，终点 = 骨骼位置 - (0,0,100)。
--   * 命中得 groundZ。
--   * z = _BaseEntZ + (groundZ - _BaseGroundZ)。
--   * 基线在 _TryInitLoop 建立；若那一瞬射线 miss（悬空），此处惰性建立。
--
-- 为什么用基线而非差分：
--   差分等价于积分，浮点上 O(N·eps) 累积误差；且依赖"上一帧 z 与
--   上一帧 g 是同一时刻的一致状态"，任何外部改 z 都会让下一帧 diff
--   出错。基线每帧独立计算，无累积，对扰动免疫。
--
-- 为什么动画自身的垂直起伏不污染信号：
--   骨骼在局部空间上下浮动时，射线起点随之浮动，但地面高度不变，
--   groundZ 不变，公式结果不变——动画自身的垂直起伏不产生 z 修正。
--   只有地形本身变化（骨骼水平漂移到不同地面高度）才产生 z 修正。
--
-- 探测范围 110 单位：
--   覆盖平地与小坡。大幅落差（跳台、悬崖）下落时射线 miss，z 不修正，
--   等到实体接近新地面再次命中——当前设计的边界行为。需要更平滑的
--   跟随可后续加"miss 时重置基线 + 平滑过渡"。
---@param self AnimationSource
function AnimationSource:_TraceGround()
    if not self._Ent:IsValid() then return end

    local bonePos = self:GetPos()
    if not bonePos then return end

    local groundZ = traceGroundZ(self._Ent, bonePos)
    if not groundZ then return end

    -- 惰性建立：_TryInitLoop 时射线 miss（悬空），此处补建。
    -- 必须同时记录两个基线——同一瞬间的 (地面, 实体) 快照。
    if not self._BaseGroundZ then
        self._BaseGroundZ = groundZ
        self._BaseEntZ = self._Ent:GetPos().z
        return
    end

    local entPos = self._Ent:GetPos()
    local newZ = self._BaseEntZ + (groundZ - self._BaseGroundZ)
    self._Ent:SetPos(Vector(entPos.x, entPos.y, newZ))
end

-- ============================================================================
-- 主循环
-- ============================================================================

---@param self AnimationSource
function AnimationSource:_Think()
    -- 每帧地形跟随——早退前执行，保证整个播放期间连续生效。
    -- 与 _ApplyRootMotion 互不干扰：前者改 z，后者改 x/y。
    self:_TraceGround()

    local now = CurTime()
    if now < self._EndTime then return end
    if not self._Ent:IsValid() or not self._ShouldLoop then
        self:Remove()
        return
    end

    -- 循环重播：先水平根运动转移，再开新一轮。
    -- 顺序不能反——Play 里的 timer.Simple 会等下一帧才重采基线，
    -- 而 _ApplyRootMotion 必须在本帧内完成，否则下一轮 _TryInitLoop
    -- 采样的 _StartPos 会带上未转移的水平位移。
    self:_ApplyRootMotion()
    self:Play()
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self._Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
