---@meta

--- @alias Vector2Arg Vector2|{x: number, y: number}
--- @alias Vector3Arg Vector3|{x: number, y: number, z: number}
--- @alias Vector4Arg Vector4|{x1: number, x2: number, y1: number, y2: number}
--- @alias ColorArg Color|string|{r: number, g: number, b: number, a: number?}|{h: number, s: number, v: number, a: number?}

--- A handle to a registered setting, returned by setting{}.
--- @class SettingRef: GameType
--- @field id string The setting id.
SettingRef = {}

--- The current value of the setting.
--- @return any
function SettingRef:Get() end

--- Sets the setting to val.
--- @param val any
function SettingRef:Set(val) end

--- setting: Register a setting.
--- @param info {id: string, description: string, help: string, storage: SettingStorage, enum: {value: any, icon: nil|string, text: nil|string, help: nil|string}[], editor: nil|"slider"|"sliderexponential"|"iconbuttons"|"iconlibrary"|"dropdown"|"check"|"color"|"text"|"input"|"buttonincrement"}
--- @return SettingRef
function setting(info) end

--- A roll definition, from DiceHarness.cs RollInfo.FromLua
--- @class RollDefinition
--- @field roll nil|string Either this should be defined, or @see categories
--- @field categories nil|table<string, {mod: nil|number, primary: nil|boolean, typedMods: table<string,integer>, attr: table<string,integer>, groups: {numDice: nil|number, numFaces: nil|number, numKeep: nil|number, subtract: nil|boolean, multiply: nil|number}[] }>
--- @field amendable nil|boolean Whether this roll is still open to being changed.
--- @field silent nil|boolean
--- @field instant nil|boolean
--- @field dmonly nil|boolean If this is only visible to the GM.
--- @field properties any Arbitrary lua object which can hold any additional roll data.
--- @field description nil|string
--- @field exploding nil|boolean
--- @field reroll nil|integer
--- @field critical nil|integer
--- @field minroll nil|integer
--- @field autofailure nil|boolean
--- @field autosuccess nil|boolean
--- @field tiers nil|integer
--- @field delay nil|boolean
--- @field begin nil|function Callback to execute when the roll begins.
--- @field complete nil|function Callback to execute when the roll ends.
--- @field tokenid nil|string
--- @field boons nil|integer
--- @field banes nil|integer
--- @field amendmentRerolls nil|boolean
RollDefinition = {}

--- The members RegisterGameType gives every game type and, through its metatable, every
--- instance of one. Each registered type should be declared `--- @class X: GameType`
--- (or `: <its base type>`, whose chain ends here).
--- @class GameType
--- @field typeName string The registered type name.
--- @field baseTypeName nil|string The registered base type name, if any.
--- @field mt table The metatable RegisterGameType sets on instances of this type.
GameType = {}

--- Creates an instance of this type: o (or a new table) with the type's metatable set.
--- @param o? table
--- @return any
function GameType.new(o) end

--- True if key is set directly on this instance (a raw get, so class defaults do not count).
--- @param key string
--- @return boolean
function GameType:has_key(key) end

--- The value set directly on this instance for key, or defaultValue when there is none.
--- Never consults the class defaults and never raises for an unknown key.
--- @param key string
--- @param defaultValue? any
--- @return any
function GameType:try_get(key, defaultValue) end

--- Like try_get, but stores defaultValue on the instance when the key was not set.
--- @param key string
--- @param defaultValue any
--- @return any
function GameType:get_or_add(key, defaultValue) end

--- Strings this instance contributes to translation; nil when there are none.
--- @return nil|table
function GameType:TranslationStrings() end

--- True if this type is, or derives from, the named type.
--- @param typeName string
--- @return boolean
function GameType.IsDerivedFrom(typeName) end

--- Makes reads and writes of field a on this type's instances go to field b.
--- @param a string
--- @param b string
function GameType.AddAlias(a, b) end

--- Engine globals set outside the stub generator's view: by core Lua TextAssets
--- (commands.txt, game-hud-menu.txt, input.txt) or by C# LuaNative.SetGlobal, which the
--- generator does not learn names from. Declared here so a stub regen keeps them.

--- Slash commands and command-line actions: `/name args` calls Commands.name(args).
--- Defined in commands.txt; the codex adds entries (`Commands.foo = function(str) ... end`).
--- @type table<string, function>
Commands = {}

--- The Dice Studio API. Set by ScriptEngine.cs only for admin accounts (and in the editor);
--- nil for everyone else, so code outside the admin-only Dice Studio must check it.
--- @type DiceStudioLua
dicestudio = nil

--- The live game HUD: the object the codex's CreateGameHud returns, installed by
--- SheetHud.cs. nil until a game's HUD has been created (not set at the title screen).
--- @type GameHud
gamehud = nil

--- Escape-key priorities, lowest to highest, from input.txt. Each value is the priority's
--- rank; pass it as a panel's `escapePriority`.
--- @class EscapePriorityTable
--- @field DMHUB_MOCKUP_DEV integer
--- @field EXIT_DM_MODE integer
--- @field DMHUB_EXIT_TITLESCREEN integer
--- @field DMHUB_EXIT_TOOL_DIALOG integer
--- @field DMHUB_OBJECT_ESCAPE integer
--- @field DMHUB_TOKEN_ESCAPE integer
--- @field DMHUB_TOKEN integer
--- @field CANCEL_TOKEN_MENU integer
--- @field CANCEL_ACTION_BAR integer
--- @field EXIT_CHARACTER_SHEET integer
--- @field DMHUB_CANCEL_TOOL integer
--- @field DMHUB_CONTEXT_MENU integer
--- @field EXIT_INVENTORY_DIALOG integer
--- @field EXIT_DIALOG integer
--- @field EXIT_ROLL_DIALOG integer
--- @field EXIT_MODAL_DIALOG integer
--- @field DMHUB_POPUP integer
--- @field DMHUB_DROPDOWN integer

--- @type EscapePriorityTable
EscapePriority = nil

--- Panels launchable from the HUD menu and by name, from game-hud-menu.txt.
--- @class LaunchablePanelRegistry
LaunchablePanel = {}

--- Registers a launchable panel. args is the registration table (name, icon, content,
--- folder, dmonly, devonly, ...); a panel with an identical name replaces the old one.
--- @param args table
function LaunchablePanel.Register(args) end

--- The open panel with this name, launching it first if it is not open.
--- @param name string
--- @return Panel|nil
function LaunchablePanel.GetOrLaunchPanel(name) end

--- Creates, parents and focuses the panel for registration entry p.
--- @param p table
--- @param args? table
--- @return Panel
function LaunchablePanel.LaunchPanel(p, args) end

--- Launches the panel whose name matches str (case-insensitive), including filtered ones.
--- @param str string
--- @param args? table
--- @return boolean launched
function LaunchablePanel.LaunchPanelByName(str, args) end

--- Appends this registry's menu items to result.
--- @param result table[]
--- @param subfolders table
--- @param includeFiltered? boolean
function LaunchablePanel.AccumulateMenuItems(result, subfolders, includeFiltered) end

--- Every launchable panel's menu item, sorted by group, ordering and text.
--- @param includeFiltered? boolean
--- @return table[]
function LaunchablePanel.GetMenuItems(includeFiltered) end

--- BEGIN generated by tools/lua-typing/gen_table_overloads.py -- do not edit by hand
--- Typed overloads for the data-table getters: each registered game type that declares
--- `X.tableName = "name"` makes GetTable("name") return its rows as X. Merged by LuaLS
--- with the declarations in dmhub.lua; names no type declares keep the plain signature.
---@overload fun(tableName: "abilityTemplates"): table<string, AbilityTemplate>
---@overload fun(tableName: "attributeGenerator"): table<string, AttributeGenerator>
---@overload fun(tableName: "audioPlaylists"): table<string, AudioPlaylist>
---@overload fun(tableName: "audioVariantPools"): table<string, VariantPool>
---@overload fun(tableName: "backgrounds"|"careers"): table<string, Background>
---@overload fun(tableName: "campaignNotes"): table<string, CampaignNote>
---@overload fun(tableName: "characterOngoingEffects"): table<string, CharacterOngoingEffect>
---@overload fun(tableName: "characterResources"): table<string, CharacterResource>
---@overload fun(tableName: "characterTypes"): table<string, CharacterType>
---@overload fun(tableName: "charConditions"): table<string, CharacterCondition>
---@overload fun(tableName: "classes"): table<string, Class>
---@overload fun(tableName: "compendiumPermissions"): table<string, CompendiumPermission>
---@overload fun(tableName: "complications"): table<string, CharacterComplication>
---@overload fun(tableName: "cultureAspects"): table<string, CultureAspect>
---@overload fun(tableName: "cultures"): table<string, Culture>
---@overload fun(tableName: "currency"): table<string, Currency>
---@overload fun(tableName: "customAttributes"): table<string, CustomAttribute>
---@overload fun(tableName: "customfields"): table<string, CustomFieldCollection>
---@overload fun(tableName: "damageFlags"): table<string, DamageFlag>
---@overload fun(tableName: "damageTypes"): table<string, DamageType>
---@overload fun(tableName: "Deities"): table<string, Deity>
---@overload fun(tableName: "DeityDomains"): table<string, DeityDomain>
---@overload fun(tableName: "documents"): table<string, CustomDocument>
---@overload fun(tableName: "downtimeActivities"): table<string, DowntimeActivity>
---@overload fun(tableName: "encounterfolders"): table<string, EncounterFolder>
---@overload fun(tableName: "encounterRuleSets"): table<string, EncounterRuleSet>
---@overload fun(tableName: "encounters"): table<string, Encounter>
---@overload fun(tableName: "encounterScripts"): table<string, EncounterScript>
---@overload fun(tableName: "environmentalKeywords"): table<string, EnvironmentalKeyword>
---@overload fun(tableName: "equipmentCategories"): table<string, EquipmentCategory>
---@overload fun(tableName: "feats"): table<string, CharacterFeat>
---@overload fun(tableName: "featurePrefabs"): table<string, CharacterFeaturePrefabs>
---@overload fun(tableName: "FishSpecies"): table<string, FishSpecies>
---@overload fun(tableName: "footprintStyles"): table<string, FootprintStyle>
---@overload fun(tableName: "glossaryTerms"): table<string, GlossaryTerm>
---@overload fun(tableName: "journalStyles"): table<string, JournalStylesheet>
---@overload fun(tableName: "kits"): table<string, Kit>
---@overload fun(tableName: "languageRelations"): table<string, LanguageRelation>
---@overload fun(tableName: "languages"): table<string, Language>
---@overload fun(tableName: "liveencounters"): table<string, LiveEncounter>
---@overload fun(tableName: "mapScripts"): table<string, MapScript>
---@overload fun(tableName: "MonsterGroup"): table<string, MonsterGroup>
---@overload fun(tableName: "negotiators"): table<string, Negotiator>
---@overload fun(tableName: "parties"): table<string, Party>
---@overload fun(tableName: "pdfReferences"): table<string, PDFFragment>
---@overload fun(tableName: "powerRolls"): table<string, PowerRollTableGroup>
---@overload fun(tableName: "proficiencyLevel"): table<string, ProficiencyLevel>
---@overload fun(tableName: "races"): table<string, Race>
---@overload fun(tableName: "Skills"): table<string, Skill>
---@overload fun(tableName: "SpellLists"): table<string, SpellList>
---@overload fun(tableName: "Spells"): table<string, Spell>
---@overload fun(tableName: "tbl_Gear"): table<string, equipment>
---@overload fun(tableName: "titles"): table<string, Title>
---@overload fun(tableName: "VisionType"): table<string, VisionType>
---@overload fun(tableName: "weaponProperties"): table<string, WeaponProperty>
---@param tableName string
---@return table<string, table>
function dmhub.GetTable(tableName) end

--- Typed overloads for the data-table getters: each registered game type that declares
--- `X.tableName = "name"` makes GetTable("name") return its rows as X. Merged by LuaLS
--- with the declarations in dmhub.lua; names no type declares keep the plain signature.
---@overload fun(tableName: "abilityTemplates"): table<string, AbilityTemplate>
---@overload fun(tableName: "attributeGenerator"): table<string, AttributeGenerator>
---@overload fun(tableName: "audioPlaylists"): table<string, AudioPlaylist>
---@overload fun(tableName: "audioVariantPools"): table<string, VariantPool>
---@overload fun(tableName: "backgrounds"|"careers"): table<string, Background>
---@overload fun(tableName: "campaignNotes"): table<string, CampaignNote>
---@overload fun(tableName: "characterOngoingEffects"): table<string, CharacterOngoingEffect>
---@overload fun(tableName: "characterResources"): table<string, CharacterResource>
---@overload fun(tableName: "characterTypes"): table<string, CharacterType>
---@overload fun(tableName: "charConditions"): table<string, CharacterCondition>
---@overload fun(tableName: "classes"): table<string, Class>
---@overload fun(tableName: "compendiumPermissions"): table<string, CompendiumPermission>
---@overload fun(tableName: "complications"): table<string, CharacterComplication>
---@overload fun(tableName: "cultureAspects"): table<string, CultureAspect>
---@overload fun(tableName: "cultures"): table<string, Culture>
---@overload fun(tableName: "currency"): table<string, Currency>
---@overload fun(tableName: "customAttributes"): table<string, CustomAttribute>
---@overload fun(tableName: "customfields"): table<string, CustomFieldCollection>
---@overload fun(tableName: "damageFlags"): table<string, DamageFlag>
---@overload fun(tableName: "damageTypes"): table<string, DamageType>
---@overload fun(tableName: "Deities"): table<string, Deity>
---@overload fun(tableName: "DeityDomains"): table<string, DeityDomain>
---@overload fun(tableName: "documents"): table<string, CustomDocument>
---@overload fun(tableName: "downtimeActivities"): table<string, DowntimeActivity>
---@overload fun(tableName: "encounterfolders"): table<string, EncounterFolder>
---@overload fun(tableName: "encounterRuleSets"): table<string, EncounterRuleSet>
---@overload fun(tableName: "encounters"): table<string, Encounter>
---@overload fun(tableName: "encounterScripts"): table<string, EncounterScript>
---@overload fun(tableName: "environmentalKeywords"): table<string, EnvironmentalKeyword>
---@overload fun(tableName: "equipmentCategories"): table<string, EquipmentCategory>
---@overload fun(tableName: "feats"): table<string, CharacterFeat>
---@overload fun(tableName: "featurePrefabs"): table<string, CharacterFeaturePrefabs>
---@overload fun(tableName: "FishSpecies"): table<string, FishSpecies>
---@overload fun(tableName: "footprintStyles"): table<string, FootprintStyle>
---@overload fun(tableName: "glossaryTerms"): table<string, GlossaryTerm>
---@overload fun(tableName: "journalStyles"): table<string, JournalStylesheet>
---@overload fun(tableName: "kits"): table<string, Kit>
---@overload fun(tableName: "languageRelations"): table<string, LanguageRelation>
---@overload fun(tableName: "languages"): table<string, Language>
---@overload fun(tableName: "liveencounters"): table<string, LiveEncounter>
---@overload fun(tableName: "mapScripts"): table<string, MapScript>
---@overload fun(tableName: "MonsterGroup"): table<string, MonsterGroup>
---@overload fun(tableName: "negotiators"): table<string, Negotiator>
---@overload fun(tableName: "parties"): table<string, Party>
---@overload fun(tableName: "pdfReferences"): table<string, PDFFragment>
---@overload fun(tableName: "powerRolls"): table<string, PowerRollTableGroup>
---@overload fun(tableName: "proficiencyLevel"): table<string, ProficiencyLevel>
---@overload fun(tableName: "races"): table<string, Race>
---@overload fun(tableName: "Skills"): table<string, Skill>
---@overload fun(tableName: "SpellLists"): table<string, SpellList>
---@overload fun(tableName: "Spells"): table<string, Spell>
---@overload fun(tableName: "tbl_Gear"): table<string, equipment>
---@overload fun(tableName: "titles"): table<string, Title>
---@overload fun(tableName: "VisionType"): table<string, VisionType>
---@overload fun(tableName: "weaponProperties"): table<string, WeaponProperty>
---@param tableName string
---@return table<string, table>
function dmhub.GetTableVisible(tableName) end
--- END generated by tools/lua-typing/gen_table_overloads.py
