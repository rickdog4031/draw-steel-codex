local mod = dmhub.GetModLoading()

--- Token Studio: the admin authoring tool for premium token frames -- frame rings rendered
--- with a real material (normal map, roughness/metallic, matcap sheen, HDR glow) instead
--- of a flat texture. The token-frame counterpart of the Dice Studio.
---
--- A frame is edited as a DRAFT: the same table dmhub.tokenFrames:Register takes (see
--- TokenFramesLua.cs / DMHub Token UI/TokenFrames.lua), kept per user in the
--- "tokenstudio:frames" preference -- the analogue of the Dice Studio's local files. Every
--- edit re-registers the draft with the engine, so a selected token wearing it re-lights
--- live. "Upload" pushes the draft to the core asset store (/CoreAssetsCurrent/tokenframes/{id})
--- through dmhub.tokenFrames:Upload; from then on every client registers it on asset
--- refresh and it is a frame any token can wear.
---
--- Engine members this panel needs beyond the registry (Upload, Delete, cloudFrames) are
--- probed with pcall, so the panel still opens on a build that predates them: the cloud
--- buttons then report that a rebuild is needed instead of erroring.

local CreateTokenStudioPanel

-- The root of the open Token Studio panel, so TokenStudio.RefreshInterface can re-sync its
-- widgets after the draft is changed from outside the panel (console, MCP bridge).
local g_studioPanelRoot = nil

DockablePanel.Register{
	name = "Token Studio",
	icon = "phosphor/user-focus.png",
	folder = "Development Tools",
	vscroll = true,
	minHeight = 100,
	content = function()
		return CreateTokenStudioPanel()
	end,
}

--- Global so the console / MCP bridge can drive the studio (TokenStudio.ApplyToSelection(), ...).
TokenStudio = {}

setting{
	id = "tokenstudio:frames",
	description = "Token Studio frame drafts, keyed by frame id.",
	default = {},
	storage = "preference",
}

setting{
	id = "tokenstudio:lastedited",
	description = "The frame the Token Studio last had open.",
	default = "",
	storage = "preference",
}

-- The shading parameters of TokenFramesLuaInterface.FrameDefinition, with the ranges the
-- sliders offer. `default` matches the engine default so an untouched slider changes nothing.
local g_paramFields = {
	{ name = "normalStrength", description = "Normal Strength", min = 0, max = 3, default = 1 },
	{ name = "specStrength", description = "Specular Strength", min = 0, max = 8, default = 1 },
	{ name = "fresnelPower", description = "Fresnel Power", min = 0.5, max = 8, default = 3 },
	{ name = "cameraReactivity", description = "Camera Reactivity", min = 0, max = 3, default = 1 },
	{ name = "eyeHeight", description = "Eye Height", min = 0.2, max = 5, default = 1.5 },
	{ name = "roughness", description = "Roughness (no map)", min = 0, max = 1, default = 0.3 },
	{ name = "metallic", description = "Metallic (no map)", min = 0, max = 1, default = 1 },
	{ name = "matcapStrength", description = "Matcap Strength", min = 0, max = 4, default = 0.5 },
	{ name = "ambient", description = "Ambient", min = 0, max = 1, default = 0.35 },
	{ name = "lightFollowsTimeOfDay", description = "Light Follows Time of Day", min = 0, max = 1, default = 1 },
	{ name = "sheenFromAlbedo", description = "Sheen From Albedo", min = 0, max = 1, default = 0 },
	{ name = "albedoSheenBoost", description = "Albedo Sheen Boost", min = 0, max = 4, default = 1.6 },
	{ name = "hdrGlow", description = "HDR Glow", min = 0, max = 12, default = 0 },
	{ name = "glowThreshold", description = "Glow Threshold", min = 0, max = 1, default = 0.7 },
	{ name = "specGlow", description = "Specular Glow", min = 0, max = 60, default = 0 },
	-- Needs an engine build that reads params4.w; older builds ignore it.
	{ name = "rimStrength", description = "Rim Strength", min = 0, max = 2, default = 1 },
}

local g_colorFields = {
	{ name = "sheenColor", description = "Sheen Color", default = "#ffffff" },
	{ name = "lightColor", description = "Light Color", default = "#ffffff" },
}

-- The fixed light direction (+z toward the camera; blended toward the map's sun by
-- lightFollowsTimeOfDay). z is kept off zero: the engine clamps a grazing light anyway.
local g_lightDirFields = {
	{ axis = "x", description = "Light X", min = -1, max = 1, default = 0.3 },
	{ axis = "y", description = "Light Y", min = -1, max = 1, default = 0.5 },
	{ axis = "z", description = "Light Z", min = 0.1, max = 1, default = 0.8 },
}

-- The maps. `library` is the image library the picker browses. AvatarFrame is the library
-- plain frames come from, so a premium frame's albedo is picked exactly like a plain one.
local g_textureFields = {
	{ name = "albedo", description = "Frame (Albedo)", library = "AvatarFrame", bgcolor = "white" },
	{ name = "normal", description = "Normal Map", library = "Normal" },
	{ name = "roughness", description = "Roughness (R) / Metallic (G)", library = "Textures" },
	{ name = "matcap", description = "Matcap", library = "Matcap" },
}

-------------------------------------------------------------------------------
-- Drafts
-------------------------------------------------------------------------------

local function GetDrafts()
	local t = dmhub.GetSettingValue("tokenstudio:frames")
	if type(t) ~= "table" then
		return {}
	end
	return t
end

-- Table-valued settings compare by content and hand back the stored table by reference,
-- so always write a fresh copy or nothing persists.
local function SaveDrafts(drafts)
	dmhub.SetSettingValue("tokenstudio:frames", DeepCopy(drafts))
end

local function NewDraft(name)
	local params = {}
	for _, f in ipairs(g_paramFields) do
		params[f.name] = f.default
	end
	for _, f in ipairs(g_colorFields) do
		params[f.name] = f.default
	end
	params.lightDir = {}
	for _, f in ipairs(g_lightDirFields) do
		params.lightDir[f.axis] = f.default
	end

	return {
		id = dmhub.GenerateGuid(),
		name = name,
		albedo = "",
		normal = "",
		roughness = "",
		matcap = "",
		flipNormalY = false,
		params = params,
		uploaded = false,
	}
end

-- Fill in anything a draft is missing (a cloud entry we pulled down, or a draft saved by an
-- older studio) so every widget has a value to show.
local function NormalizeDraft(draft)
	local fresh = NewDraft(draft.name or "Frame")
	draft.name = draft.name or fresh.name
	draft.params = draft.params or {}
	draft.params.lightDir = draft.params.lightDir or {}
	for _, f in ipairs(g_textureFields) do
		if type(draft[f.name]) ~= "string" then
			draft[f.name] = ""
		end
	end
	if draft.flipNormalY == nil then
		draft.flipNormalY = false
	end
	for _, f in ipairs(g_paramFields) do
		if type(draft.params[f.name]) ~= "number" then
			draft.params[f.name] = f.default
		end
	end
	for _, f in ipairs(g_colorFields) do
		local c = draft.params[f.name]
		if type(c) == "table" then
			-- Registered entries may carry {r,g,b}; the picker wants a hex string.
			draft.params[f.name] = core.Color{ r = c.r or 1, g = c.g or 1, b = c.b or 1, a = 1 }.tostring
		elseif type(c) ~= "string" then
			draft.params[f.name] = f.default
		end
	end
	for _, f in ipairs(g_lightDirFields) do
		if type(draft.params.lightDir[f.axis]) ~= "number" then
			draft.params.lightDir[f.axis] = f.default
		end
	end
	if draft.uploaded == nil then
		draft.uploaded = false
	end
	return draft
end

-- The table the engine registry takes: the draft minus the studio bookkeeping, with empty
-- map strings dropped (the engine treats a missing map as "none").
local function ToEntry(draft)
	local entry = DeepCopy(draft)
	entry.uploaded = nil
	for _, f in ipairs(g_textureFields) do
		if entry[f.name] == "" then
			entry[f.name] = nil
		end
	end
	return entry
end

-- The draft open in the studio (a working copy; the saved one lives in the setting) and
-- whether it has edits the setting does not.
local g_current = nil
local g_dirty = false

local function RegisterDraft(draft)
	if draft == nil or draft.albedo == nil or draft.albedo == "" then
		return false
	end
	local entry = ToEntry(draft)
	if rawget(_G, "TokenFrames") ~= nil then
		TokenFrames.RegisterDefinition(entry)
	else
		dmhub.tokenFrames:Register(entry)
	end
	return true
end

--- Re-register the open draft with the engine so tokens wearing it re-light. Called on
--- every edit. Returns false when the draft has no albedo yet (nothing to register).
function TokenStudio.Preview()
	return RegisterDraft(g_current)
end

--- The draft currently open in the studio, or nil.
function TokenStudio.Current()
	return g_current
end

--- Re-sync the open panel's widgets to the current draft, as picking it in the Frame
--- dropdown would. Call after mutating the draft from the console or the MCP bridge.
--- Returns false when the panel is closed.
function TokenStudio.RefreshInterface()
	if g_studioPanelRoot == nil or not g_studioPanelRoot.valid then
		return false
	end
	g_studioPanelRoot:FireEventTree("refreshStudio")
	g_studioPanelRoot:FireEventTree("refreshSync")
	return true
end

-- Sync mode: token ids the open draft is pushed to on every edit (see SyncToSelection).
-- Re-registering the draft already re-lights any token wearing its id; the push only has
-- to make sure the targets wear it, so it is a no-op once they do.
local g_syncTokenIds = {}

--- The tokens sync mode is pinned to, dropping any that no longer exist.
--- @return CharacterToken[]
function TokenStudio.SyncTargets()
	local result = {}
	local keep = {}
	for _, id in ipairs(g_syncTokenIds) do
		local token = dmhub.GetTokenById(id)
		if token ~= nil and token.valid then
			result[#result + 1] = token
			keep[#keep + 1] = id
		end
	end
	g_syncTokenIds = keep
	return result
end

--- Put the open draft on the sync targets that are not wearing it yet.
function TokenStudio.PushToSyncTargets()
	if g_current == nil or #g_syncTokenIds == 0 or rawget(_G, "TokenFrames") == nil then
		return
	end
	if not TokenStudio.Preview() then
		return
	end
	for _, token in ipairs(TokenStudio.SyncTargets()) do
		if token.portraitFrameMaterial ~= g_current.id or token.portraitFrame ~= g_current.albedo then
			TokenFrames.Apply(token, g_current.id)
		end
	end
end

--- Pin sync mode to the selected tokens: from now on every edit, and every draft switch,
--- is applied to them at once. Returns the number pinned and a message.
function TokenStudio.SyncToSelection()
	local ids = {}
	for _, token in ipairs(dmhub.selectedTokens or {}) do
		ids[#ids + 1] = token.charid
	end
	if #ids == 0 then
		return 0, "Select a token on the map first."
	end
	g_syncTokenIds = ids
	TokenStudio.PushToSyncTargets()
	return #ids, string.format("Syncing to %d token%s.", #ids, cond(#ids == 1, "", "s"))
end

--- Leave sync mode. The tokens keep whatever frame they are wearing.
function TokenStudio.ClearSync()
	g_syncTokenIds = {}
end

--- A one-line description of the sync targets, or nil when sync mode is off.
--- @return string|nil
function TokenStudio.SyncDescription()
	if #g_syncTokenIds == 0 then
		return nil
	end
	local names = {}
	for _, token in ipairs(TokenStudio.SyncTargets()) do
		names[#names + 1] = token.name or "(unnamed)"
	end
	if #names == 0 then
		g_syncTokenIds = {}
		return nil
	end
	return "Syncing to: " .. table.concat(names, ", ")
end

local function MarkDirty()
	g_dirty = true
	TokenStudio.Preview()
	TokenStudio.PushToSyncTargets()
end

--- Open a draft by id. Returns the draft, or nil if there is no such draft.
function TokenStudio.Load(id)
	local drafts = GetDrafts()
	local draft = drafts[id]
	if draft == nil then
		return nil
	end
	g_current = NormalizeDraft(DeepCopy(draft))
	g_dirty = false
	dmhub.SetSettingValue("tokenstudio:lastedited", id)
	TokenStudio.Preview()
	TokenStudio.PushToSyncTargets()
	return g_current
end

--- Save the open draft into the drafts setting.
function TokenStudio.Save()
	if g_current == nil then
		return false
	end
	local drafts = GetDrafts()
	drafts[g_current.id] = DeepCopy(g_current)
	SaveDrafts(drafts)
	g_dirty = false
	return true
end

--- Create a new, empty draft with the given name, save it, and open it.
function TokenStudio.New(name)
	local draft = NewDraft(name)
	local drafts = GetDrafts()
	drafts[draft.id] = draft
	SaveDrafts(drafts)
	return TokenStudio.Load(draft.id)
end

--- Clone the open draft (edits included) as a new draft with a new id -- so the copy
--- becomes its own cloud frame on Upload rather than overwriting the source -- and open it.
function TokenStudio.SaveAs(name)
	if g_current == nil then
		return TokenStudio.New(name)
	end
	local draft = DeepCopy(g_current)
	draft.id = dmhub.GenerateGuid()
	draft.name = name
	draft.uploaded = false
	local drafts = GetDrafts()
	drafts[draft.id] = draft
	SaveDrafts(drafts)
	return TokenStudio.Load(draft.id)
end

--- Discard the open draft's edits, reloading it from the setting.
function TokenStudio.Revert()
	if g_current == nil then
		return nil
	end
	return TokenStudio.Load(g_current.id)
end

--- Remove a draft from the studio. Does not touch the cloud (see DeleteFromCloud).
function TokenStudio.DeleteDraft(id)
	local drafts = GetDrafts()
	if drafts[id] == nil then
		return false
	end
	drafts[id] = nil
	SaveDrafts(drafts)
	if g_current ~= nil and g_current.id == id then
		g_current = nil
		g_dirty = false
	end
	return true
end

--- Drafts sorted by name, as dropdown options.
function TokenStudio.DraftOptions()
	local options = {}
	for id, draft in pairs(GetDrafts()) do
		options[#options + 1] = {
			id = id,
			text = cond(draft.uploaded, (draft.name or id) .. " (cloud)", draft.name or id),
		}
	end
	table.sort(options, function(a, b)
		return string.lower(a.text) < string.lower(b.text)
	end)
	return options
end

-------------------------------------------------------------------------------
-- Cloud
-------------------------------------------------------------------------------

local function NoUploadMessage(err)
	return "This engine build has no dmhub.tokenFrames cloud support; rebuild first. (" .. tostring(err) .. ")"
end

--- Upload the open draft to the core asset store. Returns ok, message.
function TokenStudio.Upload()
	if g_current == nil then
		return false, "No frame open."
	end
	if g_current.albedo == "" then
		return false, "Pick a frame (albedo) image first."
	end
	if not dmhub.isAdminAccount then
		return false, "Uploading needs an admin account."
	end

	local entry = ToEntry(g_current)
	local ok, result = pcall(function()
		return dmhub.tokenFrames:Upload(entry)
	end)
	if not ok then
		return false, NoUploadMessage(result)
	end
	if result == nil then
		return false, "Upload refused; see the console log."
	end

	g_current.uploaded = true
	TokenStudio.Save()
	if rawget(_G, "TokenFrames") ~= nil then
		TokenFrames.SyncFromCloud()
	end
	return true, "Uploaded. Every client registers it on its next asset refresh."
end

--- Hide the open draft's cloud record so clients stop offering it. Returns ok, message.
function TokenStudio.DeleteFromCloud()
	if g_current == nil then
		return false, "No frame open."
	end
	local ok, result = pcall(function()
		return dmhub.tokenFrames:Delete(g_current.id)
	end)
	if not ok then
		return false, NoUploadMessage(result)
	end
	if not result then
		return false, "The cloud has no frame with this id."
	end
	g_current.uploaded = false
	TokenStudio.Save()
	if rawget(_G, "TokenFrames") ~= nil then
		TokenFrames.RemoveDefinition(g_current.id)
	end
	return true, "Removed from the cloud."
end

--- The cloud catalogue as dropdown options, or nil (with a message) when the engine
--- build cannot list it.
function TokenStudio.CloudOptions()
	local ok, cloud = pcall(function()
		return dmhub.tokenFrames.cloudFrames
	end)
	if not ok or type(cloud) ~= "table" then
		return nil, NoUploadMessage(cloud)
	end
	local options = {}
	for id, entry in pairs(cloud) do
		options[#options + 1] = { id = id, text = entry.name or id }
	end
	table.sort(options, function(a, b)
		return string.lower(a.text) < string.lower(b.text)
	end)
	return options
end

--- Pull a cloud frame down as a draft (keeping its id, so Save + Upload update the same
--- cloud record) and open it.
function TokenStudio.DownloadFromCloud(id)
	local ok, cloud = pcall(function()
		return dmhub.tokenFrames.cloudFrames
	end)
	if not ok or type(cloud) ~= "table" or cloud[id] == nil then
		return nil
	end
	local draft = NormalizeDraft(DeepCopy(cloud[id]))
	draft.id = id
	draft.uploaded = true
	local drafts = GetDrafts()
	drafts[id] = draft
	SaveDrafts(drafts)
	return TokenStudio.Load(id)
end

-------------------------------------------------------------------------------
-- Tokens
-------------------------------------------------------------------------------

--- Put the open draft on every selected token (uploading their appearance). Returns the
--- number of tokens changed and a message.
function TokenStudio.ApplyToSelection()
	if g_current == nil then
		return 0, "No frame open."
	end
	if not TokenStudio.Preview() then
		return 0, "Pick a frame (albedo) image first."
	end
	if rawget(_G, "TokenFrames") == nil then
		return 0, "TokenFrames (DMHub Token UI) is not loaded."
	end
	local n = 0
	for _, token in ipairs(dmhub.selectedTokens or {}) do
		TokenFrames.Apply(token, g_current.id)
		n = n + 1
	end
	if n == 0 then
		return 0, "Select a token on the map first."
	end
	return n, string.format("Applied to %d token%s.", n, cond(n == 1, "", "s"))
end

--- Take the premium material off every selected token; the flat frame image stays.
function TokenStudio.ClearSelection()
	if rawget(_G, "TokenFrames") == nil then
		return 0, "TokenFrames (DMHub Token UI) is not loaded."
	end
	local n = 0
	for _, token in ipairs(dmhub.selectedTokens or {}) do
		TokenFrames.Apply(token, nil)
		n = n + 1
	end
	if n == 0 then
		return 0, "Select a token on the map first."
	end
	return n, string.format("Cleared %d token%s.", n, cond(n == 1, "", "s"))
end

-- Register every saved draft at load, so tokens in this game that wear a draft keep
-- rendering it across restarts on the authoring machine (cloud frames need no help: the
-- engine registers those itself).
for _, draft in pairs(GetDrafts()) do
	RegisterDraft(NormalizeDraft(DeepCopy(draft)))
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------

-- A "Label: control" row in the Dice Studio's form style.
local function FormRow(labelText, control)
	return gui.Panel{
		classes = {"formPanel"},
		gui.Label{
			classes = {"formLabel"},
			halign = "left",
			text = labelText .. ":",
		},
		control,
	}
end

local function Heading(text)
	return gui.Label{
		classes = {"headingLabel"},
		tmargin = 12,
		text = text,
	}
end

-- Widgets re-read the open draft on "refreshStudio". Programmatic value writes fire the
-- widget's change handler, so each handler ignores changes made while refreshing.
local function Refreshing(element)
	return element.data ~= nil and element.data.refreshing
end

local function GetParam(name, default)
	if g_current == nil then
		return default
	end
	local v = g_current.params[name]
	if v == nil then
		return default
	end
	return v
end

local function ParamSliderRow(f)
	return gui.Panel{
		classes = {"formPanel"},
		gui.Label{
			classes = {"formLabel"},
			halign = "left",
			text = f.description .. ":",
		},
		gui.Slider{
			style = {
				height = 26,
				width = 240,
				fontSize = 14,
			},
			sliderWidth = 180,
			labelWidth = 50,
			minValue = f.min,
			maxValue = f.max,
			value = GetParam(f.name, f.default),
			data = { refreshing = false },
			refreshStudio = function(element)
				element.data.refreshing = true
				element.value = GetParam(f.name, f.default)
				element.data.refreshing = false
			end,
			change = function(element)
				if Refreshing(element) or g_current == nil then
					return
				end
				g_current.params[f.name] = element.value
				MarkDirty()
			end,
		},
	}
end

local function LightDirSliderRow(f)
	return gui.Panel{
		classes = {"formPanel"},
		gui.Label{
			classes = {"formLabel"},
			halign = "left",
			text = f.description .. ":",
		},
		gui.Slider{
			style = {
				height = 26,
				width = 240,
				fontSize = 14,
			},
			sliderWidth = 180,
			labelWidth = 50,
			minValue = f.min,
			maxValue = f.max,
			value = (g_current ~= nil and g_current.params.lightDir[f.axis]) or f.default,
			data = { refreshing = false },
			refreshStudio = function(element)
				element.data.refreshing = true
				element.value = (g_current ~= nil and g_current.params.lightDir[f.axis]) or f.default
				element.data.refreshing = false
			end,
			change = function(element)
				if Refreshing(element) or g_current == nil then
					return
				end
				g_current.params.lightDir[f.axis] = element.value
				MarkDirty()
			end,
		},
	}
end

local function ColorRow(f)
	return gui.Panel{
		classes = {"formPanel"},
		gui.Label{
			classes = {"formLabel"},
			halign = "left",
			text = f.description .. ":",
		},
		gui.ColorPicker{
			border = 2,
			borderColor = "white",
			width = 16,
			height = 16,
			value = GetParam(f.name, f.default),
			data = { refreshing = false },
			refreshStudio = function(element)
				element.data.refreshing = true
				element.value = GetParam(f.name, f.default)
				element.data.refreshing = false
			end,
			change = function(element)
				if Refreshing(element) or g_current == nil then
					return
				end
				g_current.params[f.name] = element.value.tostring
				MarkDirty()
			end,
		},
	}
end

-- The open draft's map for a picker: nil (not "") when unset or when no draft is open.
local function CurrentTexture(name)
	if g_current == nil or g_current[name] == nil or g_current[name] == "" then
		return nil
	end
	return g_current[name]
end

local function TextureRow(f)
	return gui.Panel{
		classes = {"formPanel"},
		gui.Label{
			classes = {"formLabel"},
			halign = "left",
			text = f.description .. ":",
		},
		gui.IconEditor{
			border = 2,
			borderColor = "white",
			bgcolor = f.bgcolor,
			width = 48,
			height = 48,
			allowNone = true,
			library = f.library,
			searchHidden = true,
			categoriesHidden = true,
			liveEdit = true,
			value = CurrentTexture(f.name),
			refreshStudio = function(element)
				element.SetValue(element, CurrentTexture(f.name), false)
			end,
			change = function(element)
				if g_current == nil then
					return
				end
				g_current[f.name] = element.value or ""
				MarkDirty()
				element.root:FireEventTree("refreshStudioName")
			end,
		},
	}
end

CreateTokenStudioPanel = function()
	if not dmhub.isAdminAccount then
		return gui.Label{
			width = "100%",
			height = "auto",
			fontSize = 16,
			text = "The Token Studio is for admin accounts.",
		}
	end

	-- Reopen the frame this user last had open, else the first draft by name.
	if g_current == nil then
		local last = dmhub.GetSettingValue("tokenstudio:lastedited")
		if type(last) ~= "string" or TokenStudio.Load(last) == nil then
			local options = TokenStudio.DraftOptions()
			if options[1] ~= nil then
				TokenStudio.Load(options[1].id)
			end
		end
	end

	local resultPanel

	-- A transient status line under the cloud buttons (upload/apply results).
	local statusLabel = gui.Label{
		width = "100%",
		height = "auto",
		fontSize = 13,
		color = "#cccccc",
		text = "",
		setStatus = function(element, text, isError)
			element.text = text or ""
			element.selfStyle.color = cond(isError, "#ff8080", "#a0e0a0")
		end,
	}

	local function SetStatus(text, isError)
		statusLabel:FireEvent("setStatus", text, isError)
	end

	-- Ask what to do with unsaved edits before an action that would discard them.
	local function PromptUnsaved(onProceed, onCancel)
		if not g_dirty then
			onProceed()
			return
		end
		gui.ModalMessage{
			title = "Unsaved Changes",
			message = string.format("\"%s\" has unsaved changes.", (g_current and g_current.name) or "This frame"),
			options = {
				{
					text = "Save",
					execute = function()
						TokenStudio.Save()
						onProceed()
					end,
				},
				{
					text = "Discard",
					execute = onProceed,
				},
				{
					text = "Cancel",
					execute = onCancel or function() end,
				},
			},
		}
	end

	local frameDropdown = gui.Dropdown{
		width = 240,
		height = 30,
		fontSize = 14,
		options = TokenStudio.DraftOptions(),
		idChosen = g_current and g_current.id,
		refreshStudio = function(element)
			element.options = TokenStudio.DraftOptions()
			if g_current ~= nil then
				element.idChosen = g_current.id
			end
		end,
		change = function(element)
			---@cast element Dropdown
			local id = element.idChosen
			if g_current ~= nil and id == g_current.id then
				return
			end
			PromptUnsaved(function()
				TokenStudio.Load(id)
				resultPanel:FireEventTree("refreshStudio")
			end, function()
				if g_current ~= nil then
					element.idChosen = g_current.id
				end
			end)
		end,
	}

	-- Inline name prompt shared by New and Save As. `mode` says which.
	local namePrompt = gui.Panel{
		classes = {"collapsed"},
		width = "100%",
		height = "auto",
		flow = "horizontal",
		data = { mode = "new" },
		promptName = function(element, mode)
			element.data.mode = mode
			element:SetClass("collapsed", false)
			element:FireEventTree("promptNameFocus")
		end,
		gui.Input{
			height = 22,
			fontSize = 16,
			width = "60%",
			placeholderText = "Enter frame name...",
			text = "",
			promptNameFocus = function(element)
				element.textNoNotify = ""
				element.hasInputFocus = true
			end,
			change = function(element)
				local name = element.text
				local prompt = element.parent
				prompt:SetClass("collapsed", true)
				if name == "" then
					return
				end
				if prompt.data.mode == "saveas" then
					TokenStudio.SaveAs(name)
				else
					TokenStudio.New(name)
				end
				resultPanel:FireEventTree("refreshStudio")
			end,
		},
		gui.Button{
			text = "Cancel",
			width = "30%",
			height = 22,
			fontSize = 14,
			hmargin = 4,
			click = function(element)
				element.parent:SetClass("collapsed", true)
			end,
		},
	}

	local function SmallButton(text, width, click)
		return gui.Button{
			text = text,
			width = width,
			height = 24,
			fontSize = 15,
			hmargin = 2,
			click = click,
		}
	end

	-- Everything below the frame dropdown only makes sense with a draft open.
	local editorPanel = gui.Panel{
		width = "100%",
		height = "auto",
		flow = "vertical",
		refreshStudio = function(element)
			element:SetClass("collapsed", g_current == nil)
		end,

		FormRow("Name", gui.Input{
			height = 22,
			fontSize = 16,
			width = 240,
			text = (g_current and g_current.name) or "",
			refreshStudio = function(element)
				element.textNoNotify = (g_current and g_current.name) or ""
			end,
			change = function(element)
				if g_current == nil or element.text == "" then
					return
				end
				g_current.name = element.text
				g_dirty = true
				element.root:FireEventTree("refreshStudioName")
			end,
		}),

		FormRow("Id", gui.Label{
			width = "auto",
			height = "auto",
			fontSize = 12,
			color = "#aaaaaa",
			text = (g_current and g_current.id) or "",
			refreshStudio = function(element)
				element.text = (g_current and g_current.id) or ""
			end,
		}),

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,

			SmallButton("Save", "24%", function(element)
				TokenStudio.Save()
				SetStatus("Saved.")
				resultPanel:FireEventTree("refreshStudio")
			end),
			SmallButton("Save As...", "24%", function(element)
				namePrompt:FireEvent("promptName", "saveas")
			end),
			SmallButton("Revert", "24%", function(element)
				TokenStudio.Revert()
				SetStatus("Reverted to the last save.")
				resultPanel:FireEventTree("refreshStudio")
			end),
			SmallButton("Delete", "24%", function(element)
				if g_current == nil then
					return
				end
				gui.ModalMessage{
					title = "Delete Frame",
					message = string.format("Remove the draft \"%s\" from the studio? The cloud copy, if any, is not touched.", g_current.name),
					options = {
						{
							text = "Delete",
							execute = function()
								TokenStudio.DeleteDraft(g_current.id)
								local options = TokenStudio.DraftOptions()
								if options[1] ~= nil then
									TokenStudio.Load(options[1].id)
								end
								resultPanel:FireEventTree("refreshStudio")
							end,
						},
						{
							text = "Cancel",
							execute = function() end,
						},
					},
				}
			end),
		},

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,

			SmallButton("Upload to Cloud", "36%", function(element)
				PromptUnsaved(function()
					local ok, message = TokenStudio.Upload()
					SetStatus(message, not ok)
					resultPanel:FireEventTree("refreshStudio")
				end)
			end),
			gui.Button{
				text = "Remove from Cloud",
				width = "36%",
				height = 24,
				fontSize = 15,
				hmargin = 2,
				refreshStudio = function(element)
					element:SetClass("collapsed", g_current == nil or not g_current.uploaded)
				end,
				click = function(element)
					if g_current == nil then
						return
					end
					gui.ModalMessage{
						title = "Remove from Cloud",
						message = string.format("Hide \"%s\" from every client? Tokens wearing it fall back to the flat frame.", g_current.name),
						options = {
							{
								text = "Remove",
								execute = function()
									local ok, message = TokenStudio.DeleteFromCloud()
									SetStatus(message, not ok)
									resultPanel:FireEventTree("refreshStudio")
								end,
							},
							{
								text = "Cancel",
								execute = function() end,
							},
						},
					}
				end,
			},
		},

		Heading("Selected Token"),

		gui.Label{
			width = "100%",
			height = "auto",
			fontSize = 13,
			color = "#cccccc",
			text = "",
			thinkTime = 0.5,
			think = function(element)
				local n = #(dmhub.selectedTokens or {})
				local text = "No token selected."
				if n == 1 then
					local tok = dmhub.selectedTokens[1]
					text = string.format("Selected: %s", tok.name or "(unnamed)")
					if tok.portraitFrameMaterial ~= nil and tok.portraitFrameMaterial ~= "" then
						text = text .. string.format("  (frame material: %s)", tok.portraitFrameMaterial)
					end
				elseif n > 1 then
					text = string.format("Selected: %d tokens", n)
				end
				if element.text ~= text then
					element.text = text
				end
			end,
		},

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,

			SmallButton("Apply to Selected", "40%", function(element)
				local n, message = TokenStudio.ApplyToSelection()
				SetStatus(message, n == 0)
			end),
			SmallButton("Clear Frame on Selected", "40%", function(element)
				local n, message = TokenStudio.ClearSelection()
				SetStatus(message, n == 0)
			end),
		},

		-- Sync mode: pin the selection, then every edit lands on those tokens at once.
		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,

			SmallButton("Sync to Selected", "40%", function(element)
				local n, message = TokenStudio.SyncToSelection()
				SetStatus(message, n == 0)
				resultPanel:FireEventTree("refreshSync")
			end),
			gui.Button{
				text = "Clear Sync",
				width = "40%",
				height = 24,
				fontSize = 15,
				hmargin = 2,
				refreshSync = function(element)
					element:SetClass("collapsed", TokenStudio.SyncDescription() == nil)
				end,
				click = function(element)
					TokenStudio.ClearSync()
					SetStatus("Sync cleared.")
					resultPanel:FireEventTree("refreshSync")
				end,
			},
		},

		gui.Label{
			width = "100%",
			height = "auto",
			fontSize = 13,
			color = "#a0e0a0",
			text = "",
			thinkTime = 0.5,
			refreshSync = function(element)
				element:FireEvent("think")
			end,
			think = function(element)
				local text = TokenStudio.SyncDescription() or ""
				if element.text ~= text then
					element.text = text
				end
				element:SetClass("collapsed", text == "")
			end,
		},

		Heading("Maps"),

		TextureRow(g_textureFields[1]),
		TextureRow(g_textureFields[2]),
		TextureRow(g_textureFields[3]),
		TextureRow(g_textureFields[4]),

		gui.Panel{
			classes = {"formPanel"},
			gui.Check{
				halign = "left",
				text = "Flip Normal Y",
				value = (g_current and g_current.flipNormalY) or false,
				data = { refreshing = false },
				refreshStudio = function(element)
					element.data.refreshing = true
					element.value = (g_current and g_current.flipNormalY) or false
					element.data.refreshing = false
				end,
				change = function(element)
					if Refreshing(element) or g_current == nil then
						return
					end
					g_current.flipNormalY = element.value
					MarkDirty()
				end,
			},
		},

		gui.TreeNode{
			text = "Shading",
			width = "100%",
			expanded = true,
			contentPanel = gui.Panel{
				width = "100%",
				height = "auto",
				flow = "vertical",
				create = function(element)
					local children = {}
					for _, f in ipairs(g_paramFields) do
						children[#children + 1] = ParamSliderRow(f)
					end
					for _, f in ipairs(g_colorFields) do
						children[#children + 1] = ColorRow(f)
					end
					element.children = children
				end,
			},
		},

		gui.TreeNode{
			text = "Light Direction",
			width = "100%",
			contentPanel = gui.Panel{
				width = "100%",
				height = "auto",
				flow = "vertical",
				create = function(element)
					local children = {}
					for _, f in ipairs(g_lightDirFields) do
						children[#children + 1] = LightDirSliderRow(f)
					end
					element.children = children
				end,
			},
		},
	}

	resultPanel = gui.Panel{
		styles = {
			Styles.Form,
			{
				selectors = {"formPanel"},
				flow = "vertical",
				vmargin = 6,
				lmargin = 12,
			},
			{
				selectors = {"formLabel"},
				minWidth = 0,
				width = "auto",
				halign = "left",
				hmargin = 2,
				fontSize = 14,
			},
			{
				selectors = {"headingLabel"},
				bold = true,
				fontSize = 18,
				width = "auto",
				height = "auto",
			},
		},
		width = "100%",
		height = "auto",
		flow = "vertical",

		destroy = function(element)
			if g_studioPanelRoot == element then
				g_studioPanelRoot = nil
			end
		end,

		-- The dropdown text carries the name, so a rename refreshes just the dropdown.
		refreshStudioName = function(element)
			frameDropdown:FireEvent("refreshStudio")
		end,

		gui.Label{
			classes = {"panelTitle"},
			fontSize = 18,
			width = "auto",
			height = "auto",
			text = "Token Studio",
		},

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,

			gui.Label{
				classes = {"formLabel"},
				valign = "center",
				text = "Frame:",
			},
			frameDropdown,
			SmallButton("New...", 70, function(element)
				PromptUnsaved(function()
					namePrompt:FireEvent("promptName", "new")
				end)
			end),
		},

		namePrompt,

		gui.Button{
			text = "Download from Cloud...",
			width = "62%",
			height = 24,
			fontSize = 15,
			vmargin = 4,
			click = function(element)
				local options, err = TokenStudio.CloudOptions()
				if options == nil then
					SetStatus(err, true)
					return
				end
				if #options == 0 then
					SetStatus("No uploaded frames were found.", true)
					return
				end

				local chosenId = options[1].id

				gui.ShowModal(gui.Panel{
					classes = {"framedPanel"},
					width = 460,
					height = "auto",
					halign = "center",
					valign = "center",
					flow = "vertical",
					styles = ThemeEngine.GetStyles(),

					gui.Panel{
						halign = "center",
						valign = "top",
						vmargin = 20,
						flow = "vertical",
						width = 400,
						height = "auto",

						gui.Label{
							classes = {"modalTitle"},
							text = "Download Token Frame",
							halign = "center",
							width = "auto",
							height = "auto",
						},

						gui.Panel{
							flow = "horizontal",
							halign = "center",
							width = "auto",
							height = 40,
							valign = "center",
							vmargin = 12,

							gui.Label{
								text = "Uploaded:",
								width = "auto",
								height = "auto",
								color = "white",
								fontSize = 18,
								valign = "center",
								hmargin = 8,
							},

							gui.Dropdown{
								width = 260,
								height = 30,
								fontSize = 14,
								valign = "center",
								options = options,
								idChosen = chosenId,
								change = function(element)
									---@cast element Dropdown
									chosenId = element.idChosen
								end,
							},
						},
					},

					gui.Panel{
						width = 400,
						height = 48,
						halign = "center",
						valign = "bottom",

						gui.Button{
							classes = {"sizeM"},
							halign = "left",
							text = "Download",
							click = function(element)
								gui.CloseModal()
								PromptUnsaved(function()
									if TokenStudio.DownloadFromCloud(chosenId) == nil then
										SetStatus("Could not download that frame.", true)
									else
										SetStatus("Downloaded.")
									end
									resultPanel:FireEventTree("refreshStudio")
								end)
							end,
						},

						gui.Button{
							classes = {"sizeM"},
							halign = "right",
							text = "Cancel",
							escapeActivates = true,
							click = function(element)
								gui.CloseModal()
							end,
						},
					},
				})
			end,
		},

		statusLabel,

		editorPanel,
	}

	g_studioPanelRoot = resultPanel
	resultPanel:FireEventTree("refreshStudio")
	resultPanel:FireEventTree("refreshSync")
	return resultPanel
end
