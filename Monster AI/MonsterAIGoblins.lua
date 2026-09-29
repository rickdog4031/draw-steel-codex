local mod = dmhub.GetModLoading()

MonsterAI:RegisterTactic{
    id = "Goblin Sniper: Hold Position",
    monsters = {"Goblin Sniper"},
    description = "Snipers shoot without moving whenever possible, spreading fire among targets reachable from their current positions.",
    score = function(self, token, tokenLoc, enemy, ability)
        if token.properties:try_get("monster_type", "") ~= "Goblin Sniper"
            or ability.name ~= "Bow" then
            return
        end

        -- Target evaluation temporarily relocates the token. The zero-cost
        -- squad path still identifies its actual position before that probe.
        for _,member in ipairs(self.squadMembers) do
            if member.token.charid == token.charid then
                for _,path in pairs(member.paths or {}) do
                    if path.cost == 0 and path.loc.str == tokenLoc.str then
                        -- Outweigh movement bonuses and the 10000 repeat-target
                        -- penalty; stationary targets still use normal squad rules.
                        return 100000
                    end
                end
                return
            end
        end
    end,
}

--------------------------------------------------------------------------------
-- Start-of-turn Goblin Malice abilities.
--------------------------------------------------------------------------------

local maliceAbilityPause = 0.9
local speechPause = 0.45
local goblinModeEffectId = "5646898c-0c0e-4973-823e-13172eaaaba2"
local goblinModeSpeedBonus = 2

-- Tiny Stabs is worth 5 Malice from this many stabs, and a must-do from the
-- upper count on.
local tinyStabsMinimumStabs = 3
local tinyStabsMustDoStabs = 5

-- The caster shouts one of these as the Malice ability goes off.
local goblinMaliceSpeech = {
    ["Swamp Stink"] = {
        "Smell that? That's winning!",
        "Hold your breath, tall-folk!",
    },
    ["Goblin Mode"] = {
        "GOBLIN MODE!",
        "Faster, you lot!",
    },
}

local function Speak(ai, token, abilityName)
    local lines = goblinMaliceSpeech[abilityName]
    if lines ~= nil then
        ai:Speech(token, lines)
        ai.Sleep(speechPause)
    end
end

-- Swamp Stink is used at most once per encounter. Keyed by initiative queue
-- guid; local memory only, so like the framework's own Malice history it
-- forgets on a Lua reload and does not see casts the Director made by hand.
local g_swampStinkUsedByEncounter = {}

local function LiveCreature(token)
    return token ~= nil and token.valid and not token.isObject
        and token.properties ~= nil and not token.properties:IsDead()
end

local function HasOngoingEffect(token, effectid)
    local effects = nil
    pcall(function()
        effects = token.properties:ActiveOngoingEffects(true)
    end)
    for _,effect in ipairs(effects or {}) do
        if effect.ongoingEffectid == effectid then
            return true
        end
    end
    return false
end

local function HasAuraFromAbility(abilityid)
    for _,token in ipairs(dmhub.allTokens) do
        if token.valid and token.properties ~= nil then
            for _,aura in ipairs(token.properties:try_get("auras", {})) do
                if aura:try_get("sourceAbilityId") == abilityid then
                    return true
                end
            end
        end
    end
    return false
end

local function HasGoblinKeyword(token)
    local keywords = nil
    pcall(function()
        keywords = token.properties:Keywords()
    end)
    if type(keywords) ~= "table" then
        return false
    end
    for name,value in pairs(keywords) do
        if value and string.lower(tostring(name)) == "goblin" then
            return true
        end
    end
    return false
end

-- Casts a targetType "map" group ability. With no target list it hits every
-- creature the ability's filter accepts; pass targetTokens to narrow that.
local function ExecuteMapAbility(ai, caster, ability, targetTokens)
    local area = dmhub.CalculateShape{
        shape = "map",
        token = caster,
    }
    local symbols = {targetArea = area}
    local targets = {}
    if targetTokens ~= nil then
        for _,target in ipairs(targetTokens) do
            if LiveCreature(target) then
                targets[#targets+1] = {token = target}
            end
        end
    else
        for _,target in pairs(dmhub.tokenInfo.TokensInShape(area)) do
            if target.valid and ability:TargetPassesFilter(caster, target, symbols) then
                targets[#targets+1] = {token = target}
            end
        end
    end

    ai:ExecuteAbility(caster, DeepCopy(ability), targets, {
        sleep = maliceAbilityPause,
        symbols = symbols,
        targetArea = area,
    })
end

-- The strikes this creature could use on its turn, each with its range and the
-- enemies it may legally target.
local function StrikeOptions(ai, actor)
    local result = {}
    for _,ability in ipairs(actor.properties:GetActivatedAbilities()) do
        if ability:HasKeyword("Strike") and ability.categorization ~= "Triggered Action"
            and ability.categorization ~= "Malice" and ability:CanAfford(actor) then
            local enemies = {}
            for _,enemy in ipairs(ai.enemyTokens) do
                if LiveCreature(enemy) and ability:TargetPassesFilter(actor, enemy, {}) then
                    enemies[#enemies+1] = enemy
                end
            end
            if #enemies > 0 then
                result[#result+1] = {
                    range = ability:GetRange(actor.properties),
                    enemies = enemies,
                }
            end
        end
    end
    return result
end

-- True when a location in paths (other than those in skip) lets one of the
-- strikes reach an enemy it can see. Charges are just movement plus a strike,
-- so ordinary pathing already covers them.
local function CanStrikeFromPaths(ai, actor, strikes, paths, skip)
    local pierceWalls = actor.properties:GetPierceWalls()
    for key,info in pairs(paths) do
        if skip == nil or skip[key] == nil then
            local found = false
            ai:ExecuteWithTheoreticalMovementLoc(actor, info.loc, function()
                for _,strike in ipairs(strikes) do
                    for _,enemy in ipairs(strike.enemies) do
                        if MonsterAI.TargetDistance(actor, enemy) <= strike.range
                            and actor:GetLineOfSight(enemy, pierceWalls) > 0 then
                            found = true
                            return
                        end
                    end
                end
            end)
            if found then
                return true
            end
        end
    end
    return false
end

-- True when this acting creature cannot strike an enemy this turn with its
-- current speed but could with Goblin Mode's +2.
local function NeedsGoblinModeToReach(ai, goblinMode, caster, actor)
    local mover = ai:GetMovementToken(actor)
    if not LiveCreature(mover) or not goblinMode:TargetPassesFilter(caster, mover, {})
        or HasOngoingEffect(mover, goblinModeEffectId) then
        return false
    end

    local speed = mover.properties:CurrentMovementSpeed() or 0
    if speed <= 0 then
        return false
    end

    local strikes = StrikeOptions(ai, actor)
    if #strikes == 0 then
        return false
    end

    local basePaths = ai:CalculateMovementPaths(actor, speed*10)
    if CanStrikeFromPaths(ai, actor, strikes, basePaths) then
        return false
    end

    local boostedPaths = ai:CalculateMovementPaths(actor, (speed + goblinModeSpeedBonus)*10)
    return CanStrikeFromPaths(ai, actor, strikes, boostedPaths, basePaths)
end

MonsterAI:RegisterMaliceAbility{
    id = "Goblin Malice: Swamp Stink",
    monsterGroups = {"Goblin"},
    abilities = {"Swamp Stink"},
    description = "Spend 7 Malice on Swamp Stink the first time the goblins can afford it in an encounter.",
    score = function(self, ai, token, ability, context)
        local queue = context.initiativeQueue
        if queue ~= nil and g_swampStinkUsedByEncounter[queue.guid] then
            return nil, "Swamp Stink was already used this encounter"
        end
        if HasAuraFromAbility(ability:try_get("guid")) then
            return nil, "Swamp Stink mist is already on the map"
        end

        local enemies = 0
        for _,enemy in ipairs(context.enemyTokens or {}) do
            if LiveCreature(enemy) and ability:TargetPassesFilter(token, enemy, {}) then
                enemies = enemies + 1
            end
        end
        if enemies == 0 then
            return nil, "no non-goblin enemies to affect"
        end

        -- Only one Malice ability is used per turn. This outranks Goblin Mode,
        -- but yields to a must-do Tiny Stabs, whose adjacency may not last,
        -- while Swamp Stink can wait a turn.
        return {score = 0.98, enemies = enemies}
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        Speak(ai, token, "Swamp Stink")
        ExecuteMapAbility(ai, token, ability)
        local queue = context.initiativeQueue
        if queue ~= nil then
            g_swampStinkUsedByEncounter[queue.guid] = true
        end
    end,
}

MonsterAI:RegisterMaliceAbility{
    id = "Goblin Malice: Goblin Mode",
    monsterGroups = {"Goblin"},
    abilities = {"Goblin Mode"},
    description = "Spend 3 Malice on Goblin Mode when an acting goblin can only reach an enemy to strike with the +2 speed.",
    score = function(self, ai, token, ability, context)
        local needing = 0
        for _,actor in ipairs(context.actingTokens or {}) do
            if LiveCreature(actor) and NeedsGoblinModeToReach(ai, ability, token, actor) then
                needing = needing + 1
            end
        end

        if needing == 0 then
            return nil, "no acting goblin needs +2 speed to reach an enemy"
        end

        return {
            score = math.min(0.95, 0.75 + needing*0.05),
            needing = needing,
        }
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        Speak(ai, token, "Goblin Mode")
        ExecuteMapAbility(ai, token, ability)
    end,
}

MonsterAI:RegisterMaliceAbility{
    id = "Goblin Malice: Tiny Stabs",
    monsterGroups = {"Goblin"},
    abilities = {"Tiny Stabs"},
    description = "Spend 5 Malice on Tiny Stabs when goblins adjacent to enemies add up to at least 3 stabs; 5 or more is a must-do.",
    score = function(self, ai, token, ability, context)
        -- Each enemy takes 1 damage per goblin adjacent to it, so one goblin
        -- next to two enemies is two stabs.
        local goblins = {}
        for _,ally in ipairs(context.allyTokens or {}) do
            if LiveCreature(ally) and HasGoblinKeyword(ally) then
                goblins[#goblins+1] = ally
            end
        end

        local stabs = 0
        local targets = {}
        for _,enemy in ipairs(context.enemyTokens or {}) do
            if LiveCreature(enemy) then
                local enemyStabs = 0
                for _,goblin in ipairs(goblins) do
                    if MonsterAI.TargetDistance(goblin, enemy) <= 1 then
                        enemyStabs = enemyStabs + 1
                    end
                end
                if enemyStabs > 0 then
                    stabs = stabs + enemyStabs
                    targets[#targets+1] = enemy
                end
            end
        end

        if stabs < tinyStabsMinimumStabs then
            return nil, string.format("only %d stabs; needs %d", stabs, tinyStabsMinimumStabs)
        end

        -- 3 stabs just clears the 0.65 threshold; the must-do count scores 1.
        local steps = tinyStabsMustDoStabs - tinyStabsMinimumStabs
        local progress = math.min(1, (stabs - tinyStabsMinimumStabs)/steps)
        return {
            score = 0.7 + progress*0.3,
            stabs = stabs,
            targets = targets,
        }
    end,
    execute = function(self, ai, token, scoringInfo, ability, context)
        -- Only enemies who will actually be stabbed, so the log is not full
        -- of zero-damage rolls against creatures with no goblin beside them.
        ExecuteMapAbility(ai, token, ability, scoringInfo.targets)
    end,
}
