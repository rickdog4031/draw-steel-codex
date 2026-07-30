local mod = dmhub.GetModLoading()

---@class ActivatedAbilityRevertLocBehavior : ActivatedAbilityBehavior
ActivatedAbilityRevertLocBehavior = RegisterGameType("ActivatedAbilityRevertLocBehavior", "ActivatedAbilityBehavior")

ActivatedAbility.RegisterType
{
	id = 'revertloc',
	text = 'Revert Location',
	createBehavior = function()
		return ActivatedAbilityRevertLocBehavior.new{
            distance = 1,
		}
	end
}

ActivatedAbilityRevertLocBehavior.summary = 'Revert Location'

-- Optional GoblinScript formula resolving to the creature the mover is halted
-- relative to. When empty (default) the caster is used, preserving the original
-- behavior. When set (e.g. AurasCaster("Lockdown")) the mover is instead snapped
-- back to the first step of its path within `distance` of that creature -- used
-- for "your shift ends when you come adjacent to me" traits, where the halting
-- creature is NOT the caster of the triggered ability (the mover is).
ActivatedAbilityRevertLocBehavior.referenceFormula = ""

function ActivatedAbilityRevertLocBehavior:SummarizeBehavior(ability, creatureLookup)
	return string.format("Revert Location for %s", ability.name)
end

-- Resolve the reference token the mover is halted relative to. Returns the
-- caster token when no referenceFormula is set. Returns nil (do nothing) when a
-- referenceFormula is set but cannot be resolved to a live token.
function ActivatedAbilityRevertLocBehavior:GetReferenceToken(casterToken, options)
    local formula = self:try_get("referenceFormula", "")
    if formula == "" then
        return casterToken
    end

    if casterToken == nil or casterToken.properties == nil then
        return nil
    end

    local resolved = nil
    pcall(function()
        resolved = dmhub.EvalGoblinScriptToObject(formula, casterToken.properties:LookupSymbol(), "Revert Location reference")
    end)

    local refToken = nil
    if type(resolved) == "table" then
        local tid = dmhub.LookupTokenId(resolved)
        if tid ~= nil and tid ~= "" then
            refToken = dmhub.GetTokenById(tid)
        end
    elseif type(resolved) == "string" and resolved ~= "" then
        refToken = dmhub.GetTokenById(resolved)
    end

    if refToken ~= nil and refToken.valid then
        return refToken
    end

    return nil
end

function ActivatedAbilityRevertLocBehavior:Cast(ability, casterToken, targets, options)
	if #targets == 0 then
		return
	end

    local referenceToken = self:GetReferenceToken(casterToken, options)
    if referenceToken == nil then
        return
    end

    for _,target in ipairs(targets) do
        if target.token ~= nil then
            local path = options.symbols["path"]
            print("PATH::", path ~= nil and #path.path.steps)

            if path ~= nil then
                for _,step in ipairs(path.path.steps) do
                    if referenceToken:Distance(step) <= self.distance then
                        print("PATH:: RELOCATE:", step.x, step.y, step)
                        local currentLoc = target.token.loc
                        if currentLoc.x == step.x and currentLoc.y == step.y then
                            print("PATH:: SAME LOCATION, SKIP")
                            break
                        end
                        target.token:ChangeLocation(step)
                        break
                    end
                end
            end

        end
    end
end

function ActivatedAbilityRevertLocBehavior:EditorItems(parentPanel)
	local result = {}
	self:ApplyToEditor(parentPanel, result)
	self:FilterEditor(parentPanel, result)

    result[#result+1] = gui.Panel{
        classes = {"formPanel"},
        gui.Label{
            classes = {"formLabel"},
            text = "Distance:",
        },
        gui.Input{
            classes = {"formInput"},
            text = string.format("%d", tonumber(self.distance)),
            change = function(element)
                local v = tonumber(element.text)
                if v ~= nil and v >= 0 then
                    self.distance = round(v)
                else
                    element.text = string.format("%d", round(self.distance))
                end
            end,
            width = "100%",
            height = "auto",
            fontSize = 14,
            minFontSize = 6,
        }
    }

    result[#result+1] = gui.Panel{
        classes = {"formPanel"},
        gui.Label{
            classes = {"formLabel"},
            text = "Halt Near:",
        },
        gui.GoblinScriptInput{
            value = self:try_get("referenceFormula", ""),
            change = function(element)
                local v = trim(element.value)
                if v == "" then
                    self.referenceFormula = nil
                else
                    self.referenceFormula = v
                end
            end,
            documentation = {
                help = "Optional. A GoblinScript expression resolving to the creature the mover is halted relative to. Leave empty to use the caster. Example: AurasCaster(\"Lockdown\") halts the mover at the first step of its path adjacent to the aura's owner.",
                output = "creature",
                examples = {
                    {
                        script = "AurasCaster(\"Lockdown\")",
                        text = "Halt the mover at the first step of its path within Distance of the Lockdown aura's owner.",
                    },
                },
            },
        },
    }

    return result
end