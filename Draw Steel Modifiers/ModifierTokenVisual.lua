local mod = dmhub.GetModLoading()

--Token Visual Effect modifier: while a creature has this modifier active (from
--an ongoing effect like Burning, a condition, an aura, an item...), its token
--shows a looping visual chosen from a fixed list (TokenVisualEffects), e.g.
--flames for "On Fire".
--
--Nothing is networked: the modifier is ordinary creature state, and every
--client runs the driver at the bottom of this file, which reconciles the
--visuals on the current map's tokens against their active modifiers twice a
--second. A token the local user cannot see shows nothing.

--- @class TokenVisualEffectInfo
--- @field id string Stable id stored on modifiers.
--- @field name string Shown in the modifier editor.
--- @field particleEffect string ParticleEffects recipe placed on the token.

TokenVisualEffects = {
    --- @type table<string, TokenVisualEffectInfo>
    byId = {},
    --- @type TokenVisualEffectInfo[]
    ordered = {},
}

--- Adds a choice to the Token Visual Effect modifier's list. Re-registering an
--- id replaces it.
--- @param info TokenVisualEffectInfo
function TokenVisualEffects.Register(info)
    if TokenVisualEffects.byId[info.id] == nil then
        TokenVisualEffects.ordered[#TokenVisualEffects.ordered+1] = info
    else
        for i,existing in ipairs(TokenVisualEffects.ordered) do
            if existing.id == info.id then
                TokenVisualEffects.ordered[i] = info
            end
        end
    end
    TokenVisualEffects.byId[info.id] = info
end

TokenVisualEffects.Register{
    id = "onfire",
    name = "On Fire",
    particleEffect = "burning-creature",
}

TokenVisualEffects.Register{
    id = "smoldering",
    name = "Smoldering",
    particleEffect = "smoldering-creature",
}

CharacterModifier.RegisterType('tokenvisual', "Token Visual Effect")

CharacterModifier.TypeInfo.tokenvisual = {
    init = function(modifier)
        modifier.visualEffect = "onfire"
    end,

    createEditor = function(modifier, element, options)
        local options = {}
        for _,info in ipairs(TokenVisualEffects.ordered) do
            options[#options+1] = {
                id = info.id,
                text = info.name,
            }
        end

        element.children = {
            gui.Panel{
                classes = {"formPanel"},
                gui.Label{
                    classes = {"formLabel"},
                    text = "Visual",
                },
                gui.Dropdown{
                    classes = {"formDropdown"},
                    options = options,
                    idChosen = modifier:try_get("visualEffect", "onfire"),
                    change = function(element)
                        ---@cast element Dropdown
                        modifier.visualEffect = element.idChosen
                    end,
                },
            },
        }
    end,
}

--- The visual ids (TokenVisualEffects keys) the creature's active modifiers
--- ask for, as a set.
--- @return table<string, boolean>
function creature:GetTokenVisualEffects()
    local result = {}
    for _,entry in ipairs(self:GetActiveModifiers()) do
        local modifier = entry.mod
        if modifier.behavior == "tokenvisual" then
            local id = modifier:try_get("visualEffect", "onfire")
            if TokenVisualEffects.byId[id] ~= nil then
                result[id] = true
            end
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- Driver: reconciles the spawned visuals with the tokens' modifiers.
--------------------------------------------------------------------------------

--charid -> { mapid = string, visuals = { visualid -> EffectHandleLua[] } }
local g_tokenVisuals = {}

local function StopHandles(handles)
    for _,handle in ipairs(handles) do
        handle:Stop()
    end
end

local function StopToken(charid)
    local state = g_tokenVisuals[charid]
    if state == nil then
        return
    end
    for _,handles in pairs(state.visuals) do
        StopHandles(handles)
    end
    g_tokenVisuals[charid] = nil
end

local function StopAllTokenVisuals()
    local charids = {}
    for charid,_ in pairs(g_tokenVisuals) do
        charids[#charids+1] = charid
    end
    for _,charid in ipairs(charids) do
        StopToken(charid)
    end
end

local function SpawnVisual(token, info)
    --bigger creatures get bigger flames: scale with the token's width in tiles.
    local footprint = math.sqrt(math.max(1, #(token.locsOccupying or {})))
    local group = ParticleEffects.Create(info.particleEffect, { followToken = token.charid }, footprint)
    if group == nil then
        return {}
    end
    return { group }
end

local function AnyHandleDead(handles)
    for _,handle in ipairs(handles) do
        if not handle.alive then
            return true
        end
    end
    return false
end

local function Reconcile()
    local mapid = game.currentMapId
    local seen = {}

    for _,token in ipairs(dmhub.allTokens) do
        local charid = token.charid
        if token.valid and token.properties ~= nil and charid ~= nil then
            seen[charid] = true
            local wanted = {}
            if token.canSee then
                local ok, result = pcall(function() return token.properties:GetTokenVisualEffects() end)
                if ok then
                    wanted = result
                end
            end

            local state = g_tokenVisuals[charid]
            if state ~= nil and state.mapid ~= mapid then
                StopToken(charid)
                state = nil
            end

            if next(wanted) ~= nil or state ~= nil then
                if state == nil then
                    state = { mapid = mapid, visuals = {} }
                    g_tokenVisuals[charid] = state
                end

                for visualid,handles in pairs(state.visuals) do
                    if not wanted[visualid] then
                        StopHandles(handles)
                        state.visuals[visualid] = nil
                    end
                end

                for visualid,_ in pairs(wanted) do
                    local handles = state.visuals[visualid]
                    --respawn a visual something else killed (a scripted
                    --animation ending stops what was spawned during it).
                    if handles ~= nil and AnyHandleDead(handles) then
                        StopHandles(handles)
                        handles = nil
                    end
                    if handles == nil then
                        state.visuals[visualid] = SpawnVisual(token, TokenVisualEffects.byId[visualid])
                    end
                end

                if next(state.visuals) == nil then
                    g_tokenVisuals[charid] = nil
                end
            end
        end
    end

    --tokens that left the map (deleted, moved to another map, map changed).
    local gone = {}
    for charid,_ in pairs(g_tokenVisuals) do
        if not seen[charid] then
            gone[#gone+1] = charid
        end
    end
    for _,charid in ipairs(gone) do
        StopToken(charid)
    end
end

local g_lastError = nil

local function Tick()
    if mod.unloaded then
        StopAllTokenVisuals()
        return
    end

    --report each distinct failure once rather than twice a second.
    local ok, err = pcall(Reconcile)
    if not ok and tostring(err) ~= g_lastError then
        g_lastError = tostring(err)
        print("TokenVisualEffects:: reconcile failed:", err)
    end

    dmhub.Schedule(0.5, Tick)
end

dmhub.Schedule(0.5, Tick)

mod.unloadHandlers[#mod.unloadHandlers+1] = function()
    StopAllTokenVisuals()
end
