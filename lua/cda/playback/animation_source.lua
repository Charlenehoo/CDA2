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
---@field Play fun(self: AnimationSource)

---@class AnimationSourceClass:ThinkerClass
---@field New fun(self: AnimationSourceClass, track: Track): AnimationSource
local AnimationSource = setmetatable({}, { __index = Thinker })
AnimationSource.__index = AnimationSource

---@param self AnimationSourceClass
---@param track Track
---@return AnimationSource|nil
function AnimationSource:New(track)
    local instance = Thinker.New(self) --[[@as AnimationSource]]
    local ent = acquireEntity(track.ModelName)
    if not ent then
        instance:Remove()
        return nil
    end

    local sequenceID, sequenceDuration = ent:LookupSequence(track.SequenceName)
    if not sequenceID or type(sequenceID) ~= "number" or sequenceID == -1 then
        instance:Remove()
        return nil
    end

    local anchorID = getAnchorID(ent)
    if not anchorID or type(anchorID) ~= "number" or anchorID < 0 then
        instance:Remove()
        return nil
    end

    local duration = track.Duration or sequenceDuration or math.huge
    local endTime = CurTime() + duration

    instance.Ent = ent
    instance.SequenceID = sequenceID
    instance.AnchorID = anchorID
    instance.ShouldLoop = track.CanLoop
    instance.EndTime = endTime

    return instance
end

local PELVIS = "ValveBiped.Bip01_Pelvis"

---@param ent AnimationSource
---@return number|nil id
local function getAnchorID(ent)
    local ent = instance.Ent
    return ent:LookupBone(PELVIS)
end

---@param self AnimationSource
---@return Vector 
function AnimationSource:GetAnchorPos()
    if not self.AnchorID then
        self.AnchorID = ent:LookupBone(PELVIS)
    end
end

---@param self AnimationSource
function AnimationSource:Play()
    self.Ent:ResetSequence(self.SequenceID)
    self.Ent:ResetSequenceInfo()
    self.Ent:SetCycle(0)

    timer.Simple(0, function ()
        local startPos = self.Ent:
    end)
end

---@param self AnimationSource
function AnimationSource:_Think()
    local now = CurTime()
    if now < self.EndTime then return end

    if self.ShouldLoop then
    else
        self:Remove()
    end
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self.Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
