TOOL.Name = "test_animation_source"
TOOL.Category = "Debug"

local AnimationSource = include("cda/playback/animation_source.lua")

local TRACK_BASE = {
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

-- 上层编排：loop = Remove 旧的 + 从 nextPos New 新的。
--
-- nextPos 由 AnimationSource 直接给出——上层不需要保留初始 pos，
-- 也不需要做加法。这是"输出 pos 而非 delta"的直接收益。
local function startLoop(pos)
    local track = {
        ModelName    = TRACK_BASE.ModelName,
        SequenceName = TRACK_BASE.SequenceName,
        CanLoop      = TRACK_BASE.CanLoop,
        Pos          = pos,
    }

    local source = AnimationSource:New(track)
    if not source then
        print("[test_animation_source] New failed",
            " model=", track.ModelName,
            " anim=", track.SequenceName)
        return
    end

    source._Ent:SetBodygroup(source._Ent:FindBodygroupByName("barney"), 1)
    current = source

    source:Play(function (nextPos)
        source:Remove()
        if current == source then
            current = nil
        end

        if track.CanLoop then
            startLoop(nextPos)
        end
    end)

    print("[test_animation_source] playing",
        " anim=", track.SequenceName,
        " loop=", track.CanLoop,
        " pos=", tostring(pos))
end

-- 左键：在点击位置开始播放。
function TOOL:LeftClick(tr)
    stopCurrent()
    startLoop(tr.HitPos)
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
-- 用途：debug 用。不停动画——玩家瞬移过去后动画继续播，可直接观察
-- 骨骼与地形的贴合、循环接缝是否跳跃。
--
-- 位置取 _Ent:GetPos()（实体原点），不是 GetRootBonePos()——后者每帧在变。
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
