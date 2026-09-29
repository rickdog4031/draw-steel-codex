---@meta

--- @class EffectHandleLua
--- @field alive boolean (read-only) False once the effect has been stopped (by Stop(), by the scripted animation that spawned it ending, or a looping ttl) or its instance has been destroyed (e.g. with its token or on a map change). True while it plays or is still loading.
EffectHandleLua = {}

--- Stop emission immediately; live particles fade out naturally.
function EffectHandleLua:Stop() end

--- Move the effect to a new location.
--- @param pos Loc
function EffectHandleLua:Position(pos) end

--- Resize the effect.
--- @param scale? number
function EffectHandleLua:Scale(scale) end

--- Rotate the effect, in degrees. Sets the effect's local rotation about the Z axis (an in-plane spin on the top-down map -- useful for aiming a directional effect at a target). Replaces any prior rotation rather than accumulating.
--- @param degrees? number
function EffectHandleLua:Rotate(degrees) end
