local mod = dmhub.GetModLoading()

--- Image Repository: the in-app side of the developer image repository (design and API:
--- internal-dashboards/DEV_IMAGES.md; the web UI is the Images dashboard). Admin accounts only.
---
--- Browse folders and entries, see each image's display / PSD / popout files, attach files
--- (file dialog or drop a file on a slot), request popout tokens, link the current map to a
--- map image and jump to linked maps, and put a popout token on the selected token.
---
--- The bytes go through the engine bridge dmhub.devImages (DevImagesLua.cs): Request speaks
--- the JSON API with the signed-in account's token, Image downloads thumbnails, UploadFile /
--- SaveAs / Fetch move files. Bulk upload and PSD rendering live on the web page.
---
--- The panel keeps one shared copy of the repository: GET /changes?since=<rev> (the first call
--- returns everything) every POLL_SECONDS while a panel is open, and after every change it
--- makes. Rows whose deletedAt / endedAt / removedAt is set have left the live set.

-- The engine bridge (DevImagesLua.cs). Its LuaLS stub appears once the engine is rebuilt
-- and generate_lua_docs is run.
local DevImagesBridge = dmhub.devImages

local POLL_SECONDS = 20
local CARD_WIDTH = 128
local THUMB_HEIGHT = 96
local PREVIEW_SIZE = 220

local TYPE_OPTIONS = {
	{ id = "", text = "Any type" },
	{ id = "map", text = "Map" },
	{ id = "creature", text = "Creature" },
	{ id = "story", text = "Story" },
}

local SET_TYPE_OPTIONS = {
	{ id = "", text = "No type" },
	{ id = "map", text = "Map" },
	{ id = "creature", text = "Creature" },
	{ id = "story", text = "Story" },
}

local STATUS_OPTIONS = {
	{ id = "", text = "Any status" },
	{ id = "needs", text = "Needs processing" },
	{ id = "requested", text = "Popout requested" },
	{ id = "done", text = "Processed" },
}

local ROLES = {
	{ role = "display", label = "Display image", extensions = { "png", "jpg", "jpeg", "webp", "gif" } },
	{ role = "source", label = "Source PSD", extensions = { "psd", "psb" } },
	{ role = "popout", label = "Popout token", extensions = { "png", "webp" }, creatureOnly = true },
}

local STATUS_TEXT = {
	["needs-map"] = { text = "Needs map", color = "#e0a83e" },
	["needs-popout"] = { text = "Needs popout", color = "#e0a83e" },
	["popout-requested"] = { text = "Popout requested", color = "#5aa2f0" },
	done = { text = "Processed", color = "#35c483" },
	empty = { text = "No images", color = "#97a1b0" },
}

-------------------------------------------------------------------------------
-- The shared client copy of the repository
-------------------------------------------------------------------------------

local KINDS = { "folders", "entries", "images", "files", "mapLinks" }

local g_repo = {
	rev = 0,
	version = 0, -- bumped on every change, so open panels know to redraw
	loaded = false,
	error = nil,
	folders = {},
	entries = {},
	images = {},
	files = {},
	mapLinks = {},
}

local g_derived = nil
local g_syncing = false
local g_lastSync = -1000

-- Popouts imported into this game this session, so a second "use" does not upload a duplicate.
local g_importedPopouts = {}

local function IsGone(kind, row)
	if kind == "files" then
		return row.endedAt ~= nil
	elseif kind == "mapLinks" then
		return row.removedAt ~= nil
	end
	return row.deletedAt ~= nil
end

local function ApplyPayload(payload)
	local changed = payload.full == true or not g_repo.loaded
	for _, kind in ipairs(KINDS) do
		local map = payload.full and {} or g_repo[kind]
		for _, row in ipairs(payload[kind] or {}) do
			changed = true
			if IsGone(kind, row) then
				map[row.id] = nil
			else
				map[row.id] = row
			end
		end
		g_repo[kind] = map
	end
	g_repo.rev = payload.rev or g_repo.rev
	local hadError = g_repo.error ~= nil
	g_repo.loaded = true
	g_repo.error = nil
	-- A quiet poll changes nothing, so open panels are not redrawn (which would reset them).
	if changed or hadError then
		g_repo.version = g_repo.version + 1
		g_derived = nil
	end
end

local function Sync()
	if g_syncing then
		return
	end
	g_syncing = true
	g_lastSync = dmhub.Time()
	DevImagesBridge:Request{
		path = "/changes?since=" .. tostring(g_repo.rev),
		complete = function(r)
			g_syncing = false
			if mod.unloaded then
				return
			end
			if r.httpStatus == 200 then
				ApplyPayload(r)
			else
				g_repo.error = r.error or ("HTTP " .. tostring(r.httpStatus))
				if r.httpStatus == 401 or r.httpStatus == 403 then
					g_repo.error = "The repository refused this account (admins only): " .. g_repo.error
				end
				g_repo.version = g_repo.version + 1
			end
		end,
	}
end

local function NameSort(a, b)
	return string.lower(a.name or "") < string.lower(b.name or "")
end

--- Indexes the views need, rebuilt when the data changes.
local function Derived()
	if g_derived ~= nil and g_derived.version == g_repo.version then
		return g_derived
	end
	local d = {
		version = g_repo.version,
		foldersByParent = {},
		entriesByFolder = {},
		imagesByEntry = {},
		filesByImage = {},
		linksByImage = {},
	}
	local function push(t, key, value)
		local list = t[key]
		if list == nil then
			list = {}
			t[key] = list
		end
		list[#list + 1] = value
	end
	for _, f in pairs(g_repo.folders) do
		push(d.foldersByParent, f.parentId or "", f)
	end
	for _, e in pairs(g_repo.entries) do
		push(d.entriesByFolder, e.folderId or "", e)
	end
	for _, i in pairs(g_repo.images) do
		if g_repo.entries[i.entryId] ~= nil then
			push(d.imagesByEntry, i.entryId, i)
		end
	end
	for _, f in pairs(g_repo.files) do
		local byRole = d.filesByImage[f.imageId]
		if byRole == nil then
			byRole = {}
			d.filesByImage[f.imageId] = byRole
		end
		byRole[f.role] = f
	end
	for _, l in pairs(g_repo.mapLinks) do
		push(d.linksByImage, l.imageId, l)
	end
	for _, list in pairs(d.foldersByParent) do
		table.sort(list, NameSort)
	end
	for _, list in pairs(d.entriesByFolder) do
		table.sort(list, NameSort)
	end
	for _, list in pairs(d.imagesByEntry) do
		table.sort(list, function(a, b)
			if a.sortOrder ~= b.sortOrder then
				return a.sortOrder < b.sortOrder
			end
			return (a.createdAt or 0) < (b.createdAt or 0)
		end)
	end
	g_derived = d
	return d
end

--- Where an entry stands: maps want every image linked to a built map, creatures want
--- every image to have a popout (or at least a request for one). Returns state, missing.
local function EntryStatus(entry, d)
	local imgs = d.imagesByEntry[entry.id] or {}
	if #imgs == 0 then
		return "empty", 0
	end
	if entry.type == "map" then
		local missing = 0
		for _, i in ipairs(imgs) do
			if d.linksByImage[i.id] == nil then
				missing = missing + 1
			end
		end
		return cond(missing > 0, "needs-map", "done"), missing
	end
	if entry.type == "creature" then
		local lacking, unrequested = 0, 0
		for _, i in ipairs(imgs) do
			if (d.filesByImage[i.id] or {}).popout == nil then
				lacking = lacking + 1
				if i.popoutRequestedAt == nil then
					unrequested = unrequested + 1
				end
			end
		end
		if lacking == 0 then
			return "done", 0
		end
		return cond(unrequested > 0, "needs-popout", "popout-requested"), lacking
	end
	return "none", 0
end

--- The best small picture of an entry: the cover image's display thumbnail, else a popout
--- or PSD rendition. Returns a blob hash or nil.
local function CoverThumb(entry, d)
	local imgs = d.imagesByEntry[entry.id] or {}
	local ordered = {}
	for _, i in ipairs(imgs) do
		if i.id == entry.coverImageId then
			table.insert(ordered, 1, i)
		else
			ordered[#ordered + 1] = i
		end
	end
	for _, img in ipairs(ordered) do
		local files = d.filesByImage[img.id] or {}
		for _, role in ipairs({ "display", "popout", "source" }) do
			local f = files[role]
			if f ~= nil and f.thumbHash ~= nil then
				return f.thumbHash
			end
		end
	end
	return nil
end

local function FolderPath(folderId)
	local chain = {}
	local seen = {}
	local id = folderId
	while id ~= nil and seen[id] == nil do
		seen[id] = true
		local f = g_repo.folders[id]
		if f == nil then
			break
		end
		table.insert(chain, 1, f)
		id = f.parentId
	end
	return chain
end

local function FormatBytes(n)
	n = n or 0
	if n >= 1073741824 then
		return string.format("%.1f GB", n / 1073741824)
	elseif n >= 1048576 then
		return string.format("%.1f MB", n / 1048576)
	elseif n >= 1024 then
		return string.format("%.0f KB", n / 1024)
	end
	return string.format("%d B", n)
end

local function ExtensionOf(path)
	return string.lower(string.match(path or "", "%.([^%.\\/]+)$") or "")
end

local function HasExtension(spec, path)
	local ext = ExtensionOf(path)
	for _, e in ipairs(spec.extensions) do
		if e == ext then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Talking to the API
-------------------------------------------------------------------------------

--- Calls the API and re-syncs after a successful write. done(ok, result).
local function Api(method, path, body, done)
	DevImagesBridge:Request{
		method = method,
		path = path,
		body = body,
		complete = function(r)
			if mod.unloaded then
				return
			end
			local ok = r.httpStatus ~= nil and r.httpStatus >= 200 and r.httpStatus < 300
			if ok and method ~= "GET" then
				Sync()
			end
			if done ~= nil then
				done(ok, r)
			end
		end,
	}
end

--- Puts a popout token on the selected tokens: imports the image into this game's
--- popout-avatar library (once per session per image), then sets each selected token's
--- portrait to it. With nothing selected it just imports.
local function UsePopout(file, entryName, report)
	local key = tostring(dmhub.gameid) .. ":" .. file.hash
	local function apply(assetid)
		local tokens = dmhub.selectedTokens or {}
		for _, token in ipairs(tokens) do
			local snapshot = token:PrepareUploadAppearance()
			token.portrait = assetid
			token:UploadAppearance(snapshot)
			token:RefreshAppearanceLocally()
		end
		if #tokens == 0 then
			report("Added to this game's popout library. Select a token and use it again to apply it.")
		else
			report(string.format("Popout applied to %d token%s.", #tokens, cond(#tokens == 1, "", "s")))
		end
	end

	if g_importedPopouts[key] ~= nil then
		apply(g_importedPopouts[key])
		return
	end

	report("Downloading the popout...")
	DevImagesBridge:Fetch{
		hash = file.hash,
		filename = file.filename,
		complete = function(path, err)
			if mod.unloaded then
				return
			end
			if path == nil then
				report("Could not download the popout: " .. tostring(err), true)
				return
			end
			report("Importing into this game...")
			local assetid
			assetid = assets:UploadImageAsset{
				path = path,
				imageType = "AvatarPopout",
				description = entryName,
				error = function(text)
					report("Could not import the popout: " .. tostring(text), true)
				end,
				upload = function(imageid)
					dmhub.AddAndUploadImageToLibrary("popoutavatars", imageid)
				end,
			}
			-- The asset is usable once it appears in the images table (the same wait the
			-- stock image picker does).
			local tries = 0
			local function wait()
				if mod.unloaded then
					return
				end
				if assetid ~= nil and assets.imagesTable[assetid] ~= nil then
					g_importedPopouts[key] = assetid
					apply(assetid)
					return
				end
				tries = tries + 1
				if tries > 300 then
					report("Timed out waiting for the imported popout.", true)
					return
				end
				dmhub.Schedule(0.1, wait)
			end
			wait()
		end,
	}
end

--- Opens a linked map: switches map in this game, or enters the other game first.
local function OpenMap(link, report)
	if link.gameId == dmhub.gameid then
		local map = game.GetMap(link.mapId)
		if map == nil then
			report("That map no longer exists in this game.", true)
			return
		end
		game.ChangeMap(map)
		return
	end
	local mapId = link.mapId
	lobby:EnterGame(link.gameId, function()
		local map = game.GetMap(mapId)
		if map ~= nil then
			game.ChangeMap(map)
		end
	end)
end

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------

local CreatePanel

DockablePanel.Register{
	name = "Image Repository",
	icon = "phosphor/image.png",
	folder = "Development Tools",
	vscroll = true,
	minHeight = 200,
	content = function()
		return CreatePanel()
	end,
}

--- A picture from the repository in a fixed box, aspect kept. `hash` may be nil.
local function Thumb(hash, width, height, placeholder)
	local img
	local imageId = nil
	if hash ~= nil then
		imageId = DevImagesBridge:Image(hash, function(id)
			if img ~= nil and img.valid then
				img.bgimage = id
				img:SetClass("collapsed", false)
			end
		end)
	end
	img = gui.Panel{
		classes = { cond(imageId == nil, "collapsed", nil) },
		width = "auto",
		height = "auto",
		autosizeimage = true,
		maxWidth = width,
		maxHeight = height,
		halign = "center",
		valign = "center",
		bgimage = imageId,
		bgcolor = "white",
	}
	local children = { img }
	if hash == nil then
		children[#children + 1] = gui.Label{
			width = "auto",
			height = "auto",
			halign = "center",
			valign = "center",
			fontSize = 12,
			color = "#97a1b0",
			text = placeholder or "No image",
		}
	end
	return gui.Panel{
		width = width,
		height = height,
		halign = "center",
		bgimage = true,
		bgcolor = "#00000044",
		children = children,
	}
end

local function Badge(state)
	local s = STATUS_TEXT[state]
	if s == nil then
		return nil
	end
	return gui.Label{
		width = "auto",
		height = "auto",
		fontSize = 11,
		bold = true,
		color = s.color,
		text = s.text,
	}
end

CreatePanel = function()
	local root
	local content
	local messageLabel
	local crumbLabel
	local backButton
	local requestsButton

	-- View state lives on the root, per the "no state in closures" rule.
	local function State()
		return root.data.state
	end

	local Render

	local function Report(text, isError)
		if messageLabel ~= nil and messageLabel.valid then
			messageLabel.text = text or ""
			messageLabel.selfStyle.color = cond(isError, "#ef6a5a", "#97a1b0")
		end
	end

	local function Navigate(changes)
		local s = State()
		s.history[#s.history + 1] = { view = s.view, folderId = s.folderId, entryId = s.entryId }
		for k, v in pairs(changes) do
			s[k] = v
		end
		if changes.view ~= "entry" then
			s.entryId = nil
		end
		Report("")
		Render()
	end

	local function GoBack()
		local s = State()
		local prev = table.remove(s.history)
		if prev == nil then
			prev = { view = "folder", folderId = nil }
		end
		s.view = prev.view
		s.folderId = prev.folderId
		s.entryId = prev.entryId
		Report("")
		Render()
	end

	-- A card that opens an entry.
	local function EntryCard(entry, d, subtitle)
		local state = EntryStatus(entry, d)
		local hasPsd = false
		for _, img in ipairs(d.imagesByEntry[entry.id] or {}) do
			if (d.filesByImage[img.id] or {}).source ~= nil then
				hasPsd = true
			end
		end
		local body = {
			Thumb(CoverThumb(entry, d), CARD_WIDTH - 8, THUMB_HEIGHT, cond(hasPsd, "PSD", "No image")),
			gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 13,
				bold = true,
				textWrap = false,
				text = entry.name,
			},
		}
		if subtitle ~= nil then
			body[#body + 1] = gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 10,
				color = "#97a1b0",
				textWrap = false,
				text = subtitle,
			}
		end
		local meta = {
			gui.Label{
				width = "auto",
				height = "auto",
				fontSize = 11,
				color = "#97a1b0",
				rmargin = 6,
				text = string.upper(entry.type or ""),
			},
		}
		meta[#meta + 1] = Badge(state)
		body[#body + 1] = gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			children = meta,
		}
		return gui.Panel{
			classes = { "diCard" },
			width = CARD_WIDTH,
			height = "auto",
			flow = "vertical",
			hmargin = 4,
			vmargin = 4,
			bgimage = true,
			borderWidth = 1,
			cornerRadius = 4,
			pad = 4,
			borderBox = true,
			click = function()
				Navigate{ view = "entry", entryId = entry.id }
			end,
			children = body,
		}
	end

	local function Matches(entry, s, d)
		if s.type ~= "" and entry.type ~= s.type then
			return false
		end
		if s.status ~= "" then
			local st = EntryStatus(entry, d)
			if s.status == "needs" and st ~= "needs-map" and st ~= "needs-popout" then
				return false
			end
			if s.status == "done" and st ~= "done" then
				return false
			end
			if s.status == "requested" then
				local any = false
				for _, img in ipairs(d.imagesByEntry[entry.id] or {}) do
					if img.popoutRequestedAt ~= nil then
						any = true
					end
				end
				if not any then
					return false
				end
			end
		end
		if s.search ~= "" then
			local hay = string.lower((entry.name or "") .. "\n" .. (entry.notes or "") .. "\n" .. table.concat(entry.tags or {}, "\n"))
			for word in string.gmatch(string.lower(s.search), "%S+") do
				if string.find(hay, word, 1, true) == nil then
					return false
				end
			end
		end
		return true
	end

	local function FolderView(s, d)
		local children = {}
		local everywhere = s.search ~= "" or s.status == "needs" or s.status == "requested"
		if not everywhere then
			for _, f in ipairs(d.foldersByParent[s.folderId or ""] or {}) do
				local count = #(d.entriesByFolder[f.id] or {}) + #(d.foldersByParent[f.id] or {})
				children[#children + 1] = gui.Label{
					classes = { "diRow" },
					width = "100%",
					height = "auto",
					fontSize = 15,
					vpad = 3,
					hpad = 4,
					borderBox = true,
					bgimage = true,
					text = string.format("> %s   <color=#97a1b0>%d</color>", f.name, count),
					click = function()
						Navigate{ view = "folder", folderId = f.id }
					end,
				}
			end
		end

		local pool = {}
		if everywhere then
			for _, e in pairs(g_repo.entries) do
				pool[#pool + 1] = e
			end
			table.sort(pool, NameSort)
		else
			pool = d.entriesByFolder[s.folderId or ""] or {}
		end

		local cards = {}
		for _, e in ipairs(pool) do
			if Matches(e, s, d) then
				local subtitle = nil
				if everywhere then
					local names = {}
					for _, f in ipairs(FolderPath(e.folderId)) do
						names[#names + 1] = f.name
					end
					subtitle = cond(#names > 0, table.concat(names, " / "), "Top level")
				end
				cards[#cards + 1] = EntryCard(e, d, subtitle)
			end
		end

		if #cards > 0 then
			children[#children + 1] = gui.Panel{
				width = "100%",
				height = "auto",
				flow = "horizontal",
				wrap = true,
				children = cards,
			}
		elseif #children == 0 then
			children[#children + 1] = gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 13,
				color = "#97a1b0",
				vmargin = 12,
				textAlignment = "center",
				text = cond(everywhere or s.type ~= "", "Nothing matches.", "This folder is empty. Upload in bulk on the web page (Web button)."),
			}
		end
		return children
	end

	local function RequestsView(d)
		local rows = {}
		for _, img in pairs(g_repo.images) do
			if img.popoutRequestedAt ~= nil and g_repo.entries[img.entryId] ~= nil then
				rows[#rows + 1] = img
			end
		end
		table.sort(rows, function(a, b)
			return a.popoutRequestedAt < b.popoutRequestedAt
		end)
		local cards = {}
		for _, img in ipairs(rows) do
			local entry = g_repo.entries[img.entryId]
			local subtitle = string.format("%s%s", cond(img.label ~= "", img.label .. " - ", ""), img.popoutRequestedBy or "")
			cards[#cards + 1] = EntryCard(entry, d, subtitle)
		end
		if #cards == 0 then
			return {
				gui.Label{
					width = "100%",
					height = "auto",
					fontSize = 13,
					color = "#97a1b0",
					vmargin = 12,
					textAlignment = "center",
					text = "No open popout requests.",
				},
			}
		end
		return {
			gui.Panel{
				width = "100%",
				height = "auto",
				flow = "horizontal",
				wrap = true,
				children = cards,
			},
		}
	end

	-- Upload `path` into an image's slot for `spec.role`.
	local function UploadToSlot(image, spec, path, statusLabel)
		if not HasExtension(spec, path) then
			Report(string.format("%s takes %s files.", spec.label, table.concat(spec.extensions, "/")), true)
			return
		end
		statusLabel.text = "Starting..."
		DevImagesBridge:UploadFile{
			path = path,
			progress = function(fraction, phase)
				local text = string.format("%s %s: %d%%", cond(phase == "hashing", "Checking", "Uploading"), spec.label, math.floor(fraction * 100))
				Report(text)
				if statusLabel.valid then
					statusLabel.text = text
				end
			end,
			complete = function(file, err)
				if mod.unloaded then
					return
				end
				if file == nil then
					Report("Upload failed: " .. tostring(err), true)
					if statusLabel.valid then
						statusLabel.text = ""
					end
					return
				end
				Api("PUT", "/images/" .. image.id .. "/files/" .. spec.role, file, function(ok, r)
					if statusLabel.valid then
						statusLabel.text = ""
					end
					if ok then
						Report(string.format("%s updated.", spec.label))
					else
						Report("Could not attach the file: " .. tostring(r.error), true)
					end
				end)
			end,
		}
	end

	local function SmallButton(text, click)
		return gui.Button{
			text = text,
			width = math.max(56, #text * 7 + 20),
			height = 22,
			fontSize = 12,
			lmargin = 4,
			vmargin = 1,
			click = click,
		}
	end

	local function SlotRow(entry, image, spec, file)
		local statusLabel = gui.Label{
			width = "auto",
			height = "auto",
			fontSize = 11,
			color = "#97a1b0",
			lmargin = 6,
			text = "",
		}
		local buttons = {}
		if file ~= nil then
			buttons[#buttons + 1] = SmallButton("Save As", function()
				DevImagesBridge:SaveAs{
					hash = file.hash,
					filename = file.filename,
					complete = function(path, err)
						if path ~= nil then
							Report("Saved to " .. path)
						elseif err ~= "cancelled" then
							Report("Download failed: " .. tostring(err), true)
						end
					end,
				}
			end)
		end
		buttons[#buttons + 1] = SmallButton(cond(file ~= nil, "Replace", "Upload"), function()
			dmhub.OpenFileDialog{
				id = "DevImagesUpload",
				extensions = spec.extensions,
				prompt = "Choose the " .. string.lower(spec.label),
				open = function(path)
					UploadToSlot(image, spec, path, statusLabel)
				end,
			}
		end)
		if spec.role == "popout" then
			if file ~= nil then
				buttons[#buttons + 1] = SmallButton("Use on selected token", function()
					UsePopout(file, entry.name, Report)
				end)
			elseif image.popoutRequestedAt ~= nil then
				buttons[#buttons + 1] = SmallButton("Cancel request", function()
					Api("DELETE", "/images/" .. image.id .. "/popout-request", nil, function(ok, r)
						Report(cond(ok, "Request cancelled.", "Could not cancel: " .. tostring(r.error)), not ok)
					end)
				end)
			else
				buttons[#buttons + 1] = SmallButton("Request popout token", function()
					Api("POST", "/images/" .. image.id .. "/popout-request", nil, function(ok, r)
						Report(cond(ok, "Popout token requested.", "Could not request: " .. tostring(r.error)), not ok)
					end)
				end)
			end
		end
		buttons[#buttons + 1] = statusLabel

		local detail
		if file ~= nil then
			detail = string.format("%s   <color=#97a1b0>%s%s</color>", file.filename, FormatBytes(file.size),
				cond(file.width ~= nil, string.format("  %dx%d", file.width or 0, file.height or 0), ""))
			if spec.role == "display" and file.derivedFrom ~= nil then
				detail = detail .. "  <color=#97a1b0>(rendered from the PSD)</color>"
			end
		elseif spec.role == "popout" and image.popoutRequestedAt ~= nil then
			detail = "<color=#5aa2f0>Requested by " .. tostring(image.popoutRequestedBy) .. "</color>"
		else
			detail = "<color=#97a1b0>None - drop a file here or Upload</color>"
		end

		return gui.Panel{
			width = "100%",
			height = "auto",
			flow = "vertical",
			vmargin = 3,
			pad = 4,
			borderBox = true,
			bgimage = true,
			bgcolor = "#00000033",
			cornerRadius = 3,
			dragAndDropExtensions = spec.extensions,
			dragfilesenter = function(element)
				element.selfStyle.bgcolor = "#5aa2f044"
			end,
			dragfilesleave = function(element)
				element.selfStyle.bgcolor = "#00000033"
			end,
			dropfiles = function(element, paths)
				element.selfStyle.bgcolor = "#00000033"
				if paths ~= nil and paths[1] ~= nil then
					UploadToSlot(image, spec, paths[1], statusLabel)
				end
			end,
			gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 12,
				bold = true,
				text = spec.label,
			},
			gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 12,
				text = detail,
			},
			gui.Panel{
				width = "100%",
				height = "auto",
				flow = "horizontal",
				wrap = true,
				tmargin = 2,
				children = buttons,
			},
		}
	end

	local function MapLinksBlock(image, d)
		local rows = {}
		for _, link in ipairs(d.linksByImage[image.id] or {}) do
			rows[#rows + 1] = gui.Panel{
				width = "100%",
				height = "auto",
				flow = "horizontal",
				wrap = true,
				vmargin = 2,
				gui.Label{
					width = "auto",
					height = "auto",
					fontSize = 12,
					valign = "center",
					text = string.format("%s  <color=#97a1b0>%s / %s</color>", link.label ~= "" and link.label or "Map", link.gameId,
						link.mapId),
				},
				SmallButton("Open map", function()
					if link.gameId == dmhub.gameid then
						OpenMap(link, Report)
						return
					end
					local rootPanel = root
					gui.ModalMessage{
						owner = rootPanel,
						title = "Open map",
						message = "This map is in another game. Leave this game and open it?",
						options = {
							{
								text = "Cancel",
								execute = function()
									gui.CloseModal(rootPanel)
								end,
							},
							{
								text = "Open",
								execute = function()
									gui.CloseModal(rootPanel)
									OpenMap(link, Report)
								end,
							},
						},
					}
				end),
				SmallButton("Unlink", function()
					Api("DELETE", "/map-links/" .. link.id, nil, function(ok, r)
						Report(cond(ok, "Map unlinked.", "Could not unlink: " .. tostring(r.error)), not ok)
					end)
				end),
			}
		end
		if #rows == 0 then
			rows[#rows + 1] = gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 12,
				color = "#97a1b0",
				text = "Not linked to a game map yet.",
			}
		end
		rows[#rows + 1] = gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			tmargin = 2,
			SmallButton("Link current map", function()
				local map = game.currentMap
				if map == nil then
					Report("There is no current map.", true)
					return
				end
				local label = ""
				if type(map.description) == "string" then
					label = map.description
				end
				Api("POST", "/images/" .. image.id .. "/map-links", { gameId = dmhub.gameid, mapId = game.currentMapId, label = label }, function(ok, r)
					Report(cond(ok, "Linked this map.", "Could not link: " .. tostring(r.error)), not ok)
				end)
			end),
		}
		return gui.Panel{
			width = "100%",
			height = "auto",
			flow = "vertical",
			vmargin = 3,
			pad = 4,
			borderBox = true,
			bgimage = true,
			bgcolor = "#00000033",
			cornerRadius = 3,
			gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 12,
				bold = true,
				text = "Built maps",
			},
			gui.Panel{
				width = "100%",
				height = "auto",
				flow = "vertical",
				children = rows,
			},
		}
	end

	local function ImageBlock(entry, image, index, d)
		local files = d.filesByImage[image.id] or {}
		local display = files.display
		local previewHash = nil
		if display ~= nil then
			previewHash = display.previewHash or display.thumbHash
		elseif files.source ~= nil then
			previewHash = files.source.previewHash or files.source.thumbHash
		elseif files.popout ~= nil then
			previewHash = files.popout.thumbHash
		end

		local slots = {}
		for _, spec in ipairs(ROLES) do
			if not spec.creatureOnly or entry.type == "creature" or files[spec.role] ~= nil then
				slots[#slots + 1] = SlotRow(entry, image, spec, files[spec.role])
			end
		end
		if entry.type == "map" then
			slots[#slots + 1] = MapLinksBlock(image, d)
		end

		return gui.Panel{
			width = "100%",
			height = "auto",
			flow = "vertical",
			vmargin = 6,
			pad = 6,
			borderBox = true,
			bgimage = true,
			bgcolor = "#ffffff0a",
			borderWidth = 1,
			borderColor = "#ffffff1a",
			cornerRadius = 4,
			gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 13,
				bold = true,
				text = cond(image.label ~= "", image.label, "Image " .. tostring(index)),
			},
			Thumb(previewHash, PREVIEW_SIZE, PREVIEW_SIZE, cond(files.source ~= nil, "PSD (no preview yet)", "No image")),
			gui.Panel{
				width = "100%",
				height = "auto",
				flow = "vertical",
				tmargin = 4,
				children = slots,
			},
		}
	end

	local function EntryView(s, d)
		local entry = g_repo.entries[s.entryId]
		if entry == nil then
			return {
				gui.Label{
					width = "100%",
					height = "auto",
					fontSize = 13,
					color = "#97a1b0",
					text = "This entry is gone (deleted, or moved to the trash).",
				},
			}
		end
		local state = EntryStatus(entry, d)
		local header = {
				gui.Label{
					width = "auto",
					height = "auto",
					fontSize = 18,
					bold = true,
					valign = "center",
					rmargin = 10,
					text = entry.name,
				},
				gui.Dropdown{
					width = 120,
					height = 24,
					fontSize = 13,
					valign = "center",
					options = SET_TYPE_OPTIONS,
					idChosen = entry.type or "",
					change = function(element)
						---@cast element Dropdown
						local chosen = element.idChosen
						if chosen == (entry.type or "") then
							return
						end
						-- "" means no type (a nil would just be left out of the JSON).
						Api("PATCH", "/entries/" .. entry.id, { version = entry.version, type = chosen }, function(ok, r)
							Report(cond(ok, "Type updated.", "Could not change the type: " .. tostring(r.error)), not ok)
						end)
					end,
				},
		}
		header[#header + 1] = Badge(state)
		local children = {
			gui.Panel{
				width = "100%",
				height = "auto",
				flow = "horizontal",
				wrap = true,
				children = header,
			},
		}
		if (entry.notes or "") ~= "" then
			children[#children + 1] = gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 12,
				color = "#97a1b0",
				vmargin = 4,
				text = entry.notes,
			}
		end
		local imgs = d.imagesByEntry[entry.id] or {}
		for i, image in ipairs(imgs) do
			children[#children + 1] = ImageBlock(entry, image, i, d)
		end
		if #imgs == 0 then
			children[#children + 1] = gui.Label{
				width = "100%",
				height = "auto",
				fontSize = 13,
				color = "#97a1b0",
				vmargin = 8,
				text = "No images yet. Add them on the web page (Web button).",
			}
		end
		return children
	end

	Render = function()
		if root == nil or not root.valid then
			return
		end
		local s = State()
		local d = Derived()
		root.data.renderedVersion = g_repo.version

		-- Toolbar: breadcrumb and which buttons apply.
		local crumbs = {}
		if s.view == "requests" then
			crumbs = { "Popout requests" }
		else
			local folderId = s.folderId
			if s.view == "entry" and g_repo.entries[s.entryId] ~= nil then
				folderId = g_repo.entries[s.entryId].folderId
			end
			crumbs[1] = "All images"
			for _, f in ipairs(FolderPath(folderId)) do
				crumbs[#crumbs + 1] = f.name
			end
		end
		crumbLabel.text = table.concat(crumbs, " / ")
		backButton:SetClass("collapsed", s.view == "folder" and s.folderId == nil)

		local requests = 0
		for _, img in pairs(g_repo.images) do
			if img.popoutRequestedAt ~= nil and g_repo.entries[img.entryId] ~= nil then
				requests = requests + 1
			end
		end
		requestsButton.text = cond(requests > 0, string.format("Requests (%d)", requests), "Requests")

		local children
		if g_repo.error ~= nil and not g_repo.loaded then
			children = {
				gui.Label{
					width = "100%",
					height = "auto",
					fontSize = 13,
					color = "#ef6a5a",
					text = g_repo.error,
				},
			}
		elseif not g_repo.loaded then
			children = {
				gui.Label{
					width = "100%",
					height = "auto",
					fontSize = 13,
					color = "#97a1b0",
					text = "Loading the repository...",
				},
			}
		elseif s.view == "entry" then
			children = EntryView(s, d)
		elseif s.view == "requests" then
			children = RequestsView(d)
		else
			children = FolderView(s, d)
		end
		content.children = children
	end

	messageLabel = gui.Label{
		width = "100%",
		height = "auto",
		fontSize = 12,
		color = "#97a1b0",
		text = "",
	}

	crumbLabel = gui.Label{
		width = "auto",
		height = "auto",
		fontSize = 13,
		valign = "center",
		lmargin = 6,
		text = "All images",
	}

	backButton = gui.Button{
		text = "Back",
		width = 60,
		height = 24,
		fontSize = 13,
		valign = "center",
		click = function()
			GoBack()
		end,
	}

	requestsButton = gui.Button{
		text = "Requests",
		width = 116,
		height = 24,
		fontSize = 13,
		valign = "center",
		halign = "right",
		click = function()
			Navigate{ view = "requests" }
		end,
	}

	content = gui.Panel{
		width = "100%",
		height = "auto",
		flow = "vertical",
	}

	local searchTimer = 0

	root = gui.Panel{
		width = "100%",
		height = "auto",
		flow = "vertical",
		pad = 6,
		borderBox = true,
		thinkTime = 0.5,
		-- Hover looks live in rules, not inline: an inline value would always win over :hover.
		styles = {
			{ selectors = { "diCard" }, bgcolor = "#ffffff10", borderColor = "#ffffff22" },
			{ selectors = { "diCard", "hover" }, borderColor = "#ffffff99" },
			{ selectors = { "diRow" }, bgcolor = "clear" },
			{ selectors = { "diRow", "hover" }, bgcolor = "#ffffff18" },
		},
		data = {
			renderedVersion = -1,
			state = {
				view = "folder",
				folderId = nil,
				entryId = nil,
				search = "",
				type = "",
				status = "",
				history = {},
			},
		},

		create = function(element)
			if not dmhub.isAdminAccount then
				content.children = {
					gui.Label{
						width = "100%",
						height = "auto",
						fontSize = 13,
						color = "#97a1b0",
						text = "The image repository is for admin accounts.",
					},
				}
				return
			end
			Sync()
			Render()
		end,

		-- Polls while the panel is open and redraws when the shared copy changed.
		think = function(element)
			if not dmhub.isAdminAccount then
				return
			end
			if dmhub.Time() - g_lastSync >= POLL_SECONDS then
				Sync()
			end
			if element.data.renderedVersion ~= g_repo.version then
				Render()
			end
		end,

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			backButton,
			crumbLabel,
			gui.Panel{
				width = "auto",
				height = "auto",
				flow = "horizontal",
				halign = "right",
				requestsButton,
				gui.Button{
					text = "Web",
					width = 56,
					height = 24,
					fontSize = 13,
					lmargin = 4,
					valign = "center",
					click = function()
						local s = State()
						if s.view == "entry" and s.entryId ~= nil then
							DevImagesBridge:OpenWeb("/entry/" .. s.entryId)
						elseif s.view == "requests" then
							DevImagesBridge:OpenWeb("/requests")
						elseif s.folderId ~= nil then
							DevImagesBridge:OpenWeb("/f/" .. s.folderId)
						else
							DevImagesBridge:OpenWeb(nil)
						end
					end,
				},
			},
		},

		gui.Panel{
			width = "100%",
			height = "auto",
			flow = "horizontal",
			vmargin = 4,
			gui.Input{
				width = "45%",
				height = 24,
				fontSize = 13,
				valign = "center",
				placeholderText = "Search names, tags, notes",
				text = "",
				edit = function(element)
					-- Redraw a moment after typing stops rather than on every key.
					searchTimer = searchTimer + 1
					local mine = searchTimer
					local text = element.text
					dmhub.Schedule(0.3, function()
						if mod.unloaded or mine ~= searchTimer or not root.valid then
							return
						end
						local s = State()
						s.search = text
						if s.view == "entry" then
							s.view = "folder"
						end
						Render()
					end)
				end,
			},
			gui.Dropdown{
				width = 110,
				height = 24,
				fontSize = 13,
				lmargin = 4,
				valign = "center",
				options = TYPE_OPTIONS,
				idChosen = "",
				change = function(element)
					---@cast element Dropdown
					State().type = element.idChosen
					Render()
				end,
			},
			gui.Dropdown{
				width = 150,
				height = 24,
				fontSize = 13,
				lmargin = 4,
				valign = "center",
				options = STATUS_OPTIONS,
				idChosen = "",
				change = function(element)
					---@cast element Dropdown
					State().status = element.idChosen
					Render()
				end,
			},
		},

		messageLabel,
		content,
	}

	return root
end
