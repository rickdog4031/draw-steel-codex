local mod = dmhub.GetModLoading()

CharacterResource.heroicResourceId = "2d3d5511-4b80-46d1-a8c6-4705b9aa45ca"
CharacterResource.epicResourceId = "e7b04a7e-61fc-4e17-b999-d95d7e751abb"
CharacterResource.maliceResourceId = "101bab52-7f7c-4bab-92c2-9f8e0cfb7ec8"
CharacterResource.surgeResourceId = "8b0ae5fe-0eb3-45fa-9e6d-b9de68f5cc6d"
CharacterResource.triggerResourceId = "b9bc06dd-80f1-4f33-bc55-25c114e3300c"
CharacterResource.freeTriggeredActionResourceId = "5e551b7d-17fb-4099-a303-bafb3c146f98"
CharacterResource.actionResourceId = "d19658a2-4d7b-4504-af9e-1a5410fb17fd"
CharacterResource.maneuverResourceId = "a513b9a6-f311-4b0f-88b8-4e9c7bf92d0b"
CharacterResource.heroTokenId = "2166c5fe-260e-4691-9743-06cf097a59f3"
CharacterResource.villainActionId = "67f15a17-523c-4a30-8f1a-a27e4f122605"
CharacterResource.recoveryResourceId = "5bd90f9b-46be-4cf2-8ca6-a96430d62949"
CharacterResource.freeManeuverResourceId = "d81ce1e9-96a3-4705-9180-1c80f72a86cf"
CharacterResource.respiteActivityId = "5758da29-8660-47d3-805b-7c6038f476a1"
CharacterResource.rampageId = "9f418676-96be-402b-92da-0f50294146b3"

--Whether this ability is a Draw Steel triggered action or free triggered action,
--as declared by its "Action" field in the ability editor. Only these two are
--suppressed by "Cannot Use Triggered Abilities" (the Dazed / Surprised rule).
--A TriggeredAbility whose action is "No Action" is not an action the creature
--takes: automatic effects, and prompt plumbing such as the "Spend Recovery"
--trigger that Healing Grace and similar abilities fire on their targets.
--- @return boolean
function ActivatedAbility:IsTriggeredAction()
    local resource = self:ActionResource()
    return resource == CharacterResource.triggerResourceId or resource == CharacterResource.freeTriggeredActionResourceId
end

monster.resourceid = CharacterResource.maliceResourceId
character.resourceid = CharacterResource.heroicResourceId

monster.resourceRefresh = "global"
creature.resourceRefresh = "unbounded"

function creature:GetHeroicOrMaliceResourcesAvailableToSpend()
    return self:GetHeroicOrMaliceResourcesAvailable()
end

function character:GetHeroicOrMaliceResourcesAvailableToSpend()
    return self:GetHeroicOrMaliceResourcesAvailable() + self:CalculateNamedCustomAttribute("Negative Heroic Resource") + self:ExtraHeroicResource()
end

function creature:GetHeroicOrMaliceResourcesAvailable()
    return self:GetHeroicOrMaliceResources()
end

function creature:GetHeroicOrMaliceResources()
    local resources = self:GetResources()
    return resources[self.resourceid] or 0
end

function character:GetHeroicOrMaliceResources()
    local resources = self:try_get("resources")
    if resources ~= nil then
        local heroicResource = resources[CharacterResource.heroicResourceId]
        if heroicResource ~= nil then
            local q = dmhub.initiativeQueue
            if q == nil or q.hidden or q.guid ~= heroicResource.combatid then
                return 0
            end

            return heroicResource.unbounded or 0
        end
    end

    return 0
end

function creature:ResourceName()
    local t = dmhub.GetTable(CharacterResource.tableName)
    return t[self.resourceid].name
end

function CharacterResource.GetMalice()
    return CharacterResource.GetGlobalResource(CharacterResource.maliceResourceId)
end

function CharacterResource.SetMalice(amount, message)
    print("SetMalice::", amount)
    CharacterResource.SetGlobalResource(CharacterResource.maliceResourceId, amount, message)
end

function CharacterResource.CanSpendMalice(cost)
    cost = tonumber(cost) or 0
    return cost <= 0 or CharacterResource.GetMalice() >= cost
end

function CharacterResource.SpendMalice(cost, message)
    cost = tonumber(cost) or 0
    if cost <= 0 then
        return true
    end

    if not CharacterResource.CanSpendMalice(cost) then
        return false
    end

    CharacterResource.SetMalice(CharacterResource.GetMalice() - cost, message)
    return true
end

function CharacterResource.GetVillainActions()
    return CharacterResource.GetGlobalResource(CharacterResource.villainActionId)
end

function CharacterResource.SetVillainActions(amount, note)
    CharacterResource.SetGlobalResource(CharacterResource.villainActionId, amount, note)
end

-- =====================================================================
-- VillainActionState: per-encounter tracking of which villain actions
-- have been consumed. Lives in a shared document so all clients see
-- the same state in real time. Reset on encounter start (hooked from
-- InitiativeQueue.Create in MCDMInitiativeQueue.lua).
--
-- Keys:
--   tokenid          - the charid of the Leader/Solo that owns the VA
--   villainActionKey - the ability's `villainAction` field value
--                      ("Villain Action 1" | "Villain Action 2" | ...)
-- =====================================================================
VillainActionState = {}
VillainActionState.docId = "dsVillainActions"

mod:RegisterDocumentForCheckpointBackups(VillainActionState.docId)

function VillainActionState.GetDocPath()
    return mod:GetDocumentPath(VillainActionState.docId)
end

function VillainActionState.HasUsed(tokenid, villainActionKey)
    if tokenid == nil or villainActionKey == nil then return false end
    local doc = mod:GetDocumentSnapshot(VillainActionState.docId)
    local used = doc.data.used
    if used == nil then return false end
    local entry = used[tokenid]
    if entry == nil then return false end
    return entry[villainActionKey] == true
end

function VillainActionState.MarkUsed(tokenid, villainActionKey)
    if tokenid == nil or villainActionKey == nil then return end
    local doc = mod:GetDocumentSnapshot(VillainActionState.docId)
    doc:BeginChange()
    if doc.data.used == nil then doc.data.used = {} end
    if doc.data.used[tokenid] == nil then doc.data.used[tokenid] = {} end
    doc.data.used[tokenid][villainActionKey] = true
    doc:CompleteChange("Villain Action used: " .. villainActionKey)
end

function VillainActionState.ClearUsed(tokenid, villainActionKey)
    if tokenid == nil or villainActionKey == nil then return end
    local doc = mod:GetDocumentSnapshot(VillainActionState.docId)
    if doc.data.used == nil or doc.data.used[tokenid] == nil then return end
    doc:BeginChange()
    doc.data.used[tokenid][villainActionKey] = nil
    doc:CompleteChange("Villain Action reset: " .. villainActionKey, {undoable = false})
end

function VillainActionState.ClearForToken(tokenid)
    if tokenid == nil then return end
    local doc = mod:GetDocumentSnapshot(VillainActionState.docId)
    if doc.data.used == nil or doc.data.used[tokenid] == nil then return end
    doc:BeginChange()
    doc.data.used[tokenid] = nil
    doc:CompleteChange("Villain Action state cleared for token", {undoable = false})
end

function VillainActionState.ResetAll()
    local doc = mod:GetDocumentSnapshot(VillainActionState.docId)
    if doc.data.used == nil then return end
    doc:BeginChange()
    doc.data.used = {}
    doc:CompleteChange("Villain Action state reset (new encounter)", {undoable = false})
end

function creature:GetHeroTokens()
    return 0
end

function character:GetHeroTokens()
    return CharacterResource.GetGlobalResource(CharacterResource.heroTokenId)
end

function creature:SetHeroTokens(amount, message)
    CharacterResource.SetGlobalResource(CharacterResource.heroTokenId, amount, message)
end

--- @return {color: string, when: string, who: string, value: number, note: string}
function creature:GetHeroTokenHistory()
    return CharacterResource.GetGlobalResourceHistory(CharacterResource.heroTokenId)
end

--Whether a creature has the named complication. pcall: Complications() is a
--hero-side method and a creature-typed monster may not carry it.
--- @param c creature|nil
--- @param name string
--- @return boolean
local function HasComplication(c, name)
    if c == nil then
        return false
    end
    local found = false
    pcall(function()
        for _, complication in ipairs(c:Complications()) do
            if complication.name == name then
                found = true
            end
        end
    end)
    return found
end

--Spend 1 Hero Token on a test re-roll or a saving throw. Lucky complication:
--"roll a d10. On a 6 or higher, you gain the benefit but don't spend the hero
--token." The token is taken now so the benefit never waits on the d10, and
--handed back if the d10 comes up 6+.
--Re-reads the pool rather than trusting an earlier check, so a token spent
--elsewhere in the meantime cannot take the pool negative.
--- @param c creature|nil the hero spending the token
--- @param note string the pool history entry
--- @return boolean paid
function CharacterResource.SpendHeroTokenForRoll(c, note)
    local tokens = CharacterResource.GetGlobalResource(CharacterResource.heroTokenId)
    if tokens < 1 then
        return false
    end
    CharacterResource.SetGlobalResource(CharacterResource.heroTokenId, tokens - 1, note)

    if HasComplication(c, "Lucky") then
        ---@cast c creature
        dmhub.Roll{
            roll = "1d10",
            description = "Lucky",
            tokenid = dmhub.LookupTokenId(c),
            creature = c,
            complete = function(rollInfo)
                if (rollInfo.total or 0) < 6 then
                    return
                end
                local now = CharacterResource.GetGlobalResource(CharacterResource.heroTokenId)
                CharacterResource.SetGlobalResource(CharacterResource.heroTokenId, now + 1, "Lucky: Hero Token not spent")
                local send = rawget(_G, "SendTitledChatMessage")
                if send ~= nil then
                    send(string.format("%s's luck holds: the Hero Token is not spent.", c:try_get("name") or "The hero"), "Lucky", "#e0b84c")
                end
            end,
        }
    end

    return true
end

--Whether the test behind a finished roll was re-rolled with a Hero Token.
--HeroTokenTestRerollRule marks the roll's properties when it pays. Lucky's
--drawback reads this through the rollpower trigger's Hero Token Reroll symbol.
--- @param rollInfo any
--- @return boolean
function CharacterResource.RollUsedHeroTokenReroll(rollInfo)
    local used = false
    pcall(function()
        used = rollInfo.properties:try_get("heroTokenReroll", false) == true
    end)
    return used
end

--A hero may spend 1 Hero Token to re-roll a test, and must use the new roll --
--so one re-roll per test. Expressed as a roll-dialog re-roll rule (see the
--"Re-roll rules" block in DSRollDialog.lua): it replaces the dialog's free
--Re-roll button with a Hero Token one for the duration of that roll.
--RollDialog.GetDefaultRerollRule hands this to every test a hero makes; a roll
--can also ask for it by name via its own `rerollRule` option.
--- @return table
function CharacterResource.HeroTokenTestRerollRule()
    return {
        text = "Re-roll",
        icon = "drawsteel/hero-token.png",
        tooltip = "1 Hero Token: Re-roll. You must use the new roll.",
        maxRerolls = 1,
        spentTooltip = "You have already re-rolled this test. You must use the new roll.",

        CanReroll = function(state)
            if CharacterResource.GetGlobalResource(CharacterResource.heroTokenId) < 1 then
                return false, "You have no Hero Tokens to spend."
            end
            return true
        end,

        --Also marks the roll as Hero-Token re-rolled for Lucky's drawback. The
        --roll's chat message keeps the properties uploaded with the first roll
        --and a re-roll does not refresh them, so upload the mark explicitly.
        Pay = function(state)
            if not CharacterResource.SpendHeroTokenForRoll(state.creature, "Re-rolled a test") then
                return false
            end
            local props = state.options ~= nil and state.options.rollProperties or nil
            if props ~= nil then
                props.heroTokenReroll = true
                if state.rollInfo ~= nil then
                    pcall(function() state.rollInfo:UploadProperties(props) end)
                end
            end
            return true
        end,
    }
end

--A hero may spend 1 Hero Token to succeed on a saving throw they failed. A
--re-roll rule (see "Re-roll rules" in DSRollDialog.lua) that takes over the
--roll dialog's Re-roll button only while the save on screen is a failure.
--  args.IsFailed(state) -> boolean  whether the save as rolled has failed.
--  args.Succeed(state)              called once the token is paid; makes the
--                                   save succeed and accepts the result.
--- @param args {IsFailed: (fun(state: table): boolean), Succeed: (fun(state: table))}
--- @return table
function CharacterResource.HeroTokenSaveSucceedRule(args)
    return {
        text = "Succeed Instead",
        fontSize = 16,
        icon = "drawsteel/hero-token.png",
        tooltip = "1 Hero Token: Succeed on this saving throw instead.",

        Applies = function(state)
            return args.IsFailed(state) and CharacterResource.GetGlobalResource(CharacterResource.heroTokenId) >= 1
        end,

        CanReroll = function(state)
            if CharacterResource.GetGlobalResource(CharacterResource.heroTokenId) < 1 then
                return false, "You have no Hero Tokens to spend."
            end
            return true
        end,

        Pay = function(state)
            return CharacterResource.SpendHeroTokenForRoll(state.creature, "Succeeded on a saving throw")
        end,

        Perform = function(state)
            args.Succeed(state)
        end,
    }
end

function creature:GetEpicResources()
    local resources = self:try_get("resources")
    if resources ~= nil then
        local epicResource = resources[CharacterResource.epicResourceId]
        if epicResource ~= nil then
            return epicResource.unbounded or 0
        end
    end
    return 0
end
