TOOL.Name = "test_animation_source"
TOOL.Category = "Debug"

local npcOfChoice = nil

function TOOL:LeftClick(tr)
    if not npcOfChoice then
        print("no npcOfChoice")
        return false
    end

    local clickEnt = tr.Entity
    if not IsValid(clickEnt) then
        print("no ragdoll")
        return false
    end
    if not clickEnt:IsRagdoll() then
        return false
    end

    npcOfChoice:SetTarget(clickEnt)
    npcOfChoice:SetSchedule(SCHED_TARGET_CHASE)
end

function TOOL:RightClick(tr)
    local clickEnt = tr.Entity
    if not IsValid(clickEnt) then
        return false
    end
    if not clickEnt:IsNPC() then
        return false
    end

    npcOfChoice = clickEnt
    return true
end
