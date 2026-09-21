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
---@field Ent Entity
---@field SequenceID number
---@field AnchorID number
---@field ShouldLoop boolean
---@field EndTime number
---@field StartPos Vector
---@field _UpdateEntity fun(self: AnimationSource, track: Track)
---@field _UpdateAnchor fun(self: AnimationSource)
---@field _UpdateSequence fun(self: AnimationSource, track: Track)
---@field GetPos fun(self: AnimationSource)
---@field Play fun(self: AnimationSource)

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_UpdateEntity(track)
    local ent = acquireEntity(track.ModelName)
    if not ent then
        return false
    end
    self.Ent = ent
    return true
end

local PELVIS = "ValveBiped.Bip01_Pelvis"

---@param self AnimationSource
---@return boolean ok
function AnimationSource:_UpdateAnchor()
    local id = self.Ent:LookupBone(PELVIS)
    if not id or type(id) ~= "number" or id < 0 then
        return false
    end
    self.AnchorID = id
    return true
end

---@param self AnimationSource
---@param track Track
---@return boolean ok
function AnimationSource:_UpdateSequence(track)
    local sequenceID, sequenceDuration = self.Ent:LookupSequence(track.SequenceName)
    if not sequenceID or type(sequenceID) ~= "number" or sequenceID == -1 then
        return false
    end
    local duration = track.Duration or sequenceDuration or math.huge
    local endTime = CurTime() + duration
    self.SequenceID = sequenceID
    self.EndTime = endTime
    self.ShouldLoop = track.CanLoop
    return true
end

---@param self AnimationSourceClass
---@param track Track
---@return AnimationSource|nil
function AnimationSource:New(track)
    local instance = Thinker.New(self) --[[@as AnimationSource]]
    if not instance:_UpdateEntity(track) or
        not instance:_UpdateAnchor() or
        not instance:_UpdateSequence(track) then
        instance:Remove()
        return nil
    end
    return instance
end

---@param self AnimationSource
---@return Vector
function AnimationSource:GetPos()
    local pos, _ = self.Ent:GetBonePosition(self.AnchorID)
    return pos
end

---@param self AnimationSource
function AnimationSource:Play()
    self.Ent:ResetSequence(self.SequenceID)
    self.Ent:ResetSequenceInfo()
    self.Ent:SetCycle(0)

    timer.Simple(0, function ()
        if not self.Ent:IsValid() then
            self:Remove()
            return
        end
        self.StartPos = self:GetPos()
    end)
end

---@param self AnimationSource
function AnimationSource:_Think()
    local now = CurTime()
    if now < self.EndTime then return end
    if not self.Ent:IsValid() or not self.ShouldLoop then
        self:Remove()
        return
    end
    local endPos = self:GetPos()
    local delta = endPos - self.StartPos
    local delta2D = Vector(delta.x, delta.y, 0)
    self.Ent:SetPos(self.Ent:GetPos() + delta2D)
    self:Play()
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self.Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
