TOOL.Name = "test_animation_source"
TOOL.Category = "Debug"

local AnimationSource = include("cda/playback/animation_source.lua")

-- 使用 crawl.face_up.male 的第一条动画。
-- 模型别名 "brutal" → "models/brutal_deaths/model_anim_modify.mdl"。
-- CanLoop = true 用来验证 _ApplyRootMotion 的循环回跳补偿。
local TRACK = {
    ModelName    = "models/brutal_deaths/model_anim_modify.mdl",
    SequenceName = "crawling1",
    CanLoop      = true,
}

---@type AnimationSource|nil
local current = nil

local function stopCurrent()
    if current then
        current:Remove()
        current = nil
    end
end

-- 左键：在点击位置播放一次爬行动画。
-- 每次点击先清理上一个实例——避免多个 prop_dynamic 叠在一起。
function TOOL:LeftClick(tr)
    stopCurrent()

    local source = AnimationSource:New(TRACK)
    if not source then
        print("[test_animation_source] New failed",
            " model=", TRACK.ModelName,
            " anim=", TRACK.SequenceName)
        return false
    end

    -- 放到点击位置。
    -- AnimationSource 本身不接收位置参数，New 之后 Play 之前手动设置。
    -- 工具枪直接访问私有字段 _Ent 是本工具的破例——它就是要验证实现，
    -- 不遵循生产代码的封装约定。
    if source._Ent:IsValid() then
        source._Ent:SetPos(tr.HitPos)
        source._Ent:SetBodygroup(source._Ent:FindBodygroupByName("barney"), 1)
    end

    source:Play()
    current = source

    print("[test_animation_source] playing",
        " anim=", TRACK.SequenceName,
        " loop=", TRACK.CanLoop,
        " pos=", tostring(tr.HitPos))

    return true
end

-- 右键：停止并移除当前动画。
function TOOL:RightClick(tr)
    if current then
        stopCurrent()
        print("[test_animation_source] stopped")
        return true
    end
    return false
end

-- Reload（换弹键 R）：把玩家传送到动画实体当前位置。
--
-- 用途：debug 用。不停动画——玩家瞬移过去后动画继续播，
-- 可直接观察：
--   * 骨骼是否还在动（判断动画是否真的在播）
--   * 骨骼与地形是否贴合（判断 _TraceGround 是否正确）
--   * 循环处骨骼是否回跳（判断 _ApplyRootMotion 是否正确）
--
-- 若发现传送后动画其实还在播，只是实体位置错了，说明问题在 SetPos 算法
-- 而非播放路径。
--
-- 位置取 _Ent:GetPos()——实体原点，不是骨骼位置。
-- 骨骼位置每帧在变，取哪个时刻都会飘；实体原点是根运动的锚点，
-- 更适合"传送到动画所在处"这个语义。
function TOOL:Reload(tr)
    if not current then
        print("[test_animation_source] no active animation to teleport to")
        return false
    end

    if not IsValid(current._Ent) then
        print("[test_animation_source] current entity invalid")
        stopCurrent()
        return false
    end

    local pos = current._Ent:GetPos()
    local ply = self:GetOwner()

    if not IsValid(ply) then return false end

    ply:SetPos(pos)

    print("[test_animation_source] teleported to",
        tostring(pos),
        " (animation continues)")

    return true
end
