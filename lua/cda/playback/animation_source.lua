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

    local entity = ents.Create("prop_dynamic")
    if not IsValid(entity) then return nil end

    entity:SetModel(modelName)
    entity:Spawn()
    return entity
end

---@param entity Entity
local function releaseEntity(entity)
    if IsValid(entity) then
        entity:Remove()
    end
end

local Thinker = include("cda/core/thinker.lua")

---@class AnimationSource:Thinker
---@field Ent Entity
---@field SequenceID number
---@field Duration number
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

    instance.Ent = ent
    instance.SequenceID = sequenceID
    instance.Duration = track.Duration or sequenceDuration or math.huge

    return instance
end

---@param self AnimationSource
function AnimationSource:Play()
    self.Ent:ResetSequence(self.SequenceID)
    self.Ent:ResetSequenceInfo()
    self.Ent:SetCycle(0)
end

---@param self AnimationSource
function AnimationSource:_OnRemove()
    releaseEntity(self.Ent)
end

package.loaded[KEY] = AnimationSource
return AnimationSource
