-- Buff Checker - written entirely by AI (Claude), designed and tested in the game by the maintainer.
-- Shows one row of action-button style icons for buffs that are MISSING or
-- about to expire. Nothing is shown when everything is fine.
-- In combat the game hides buffs from addons, so there the icons go by the clock
-- (a buff seen before combat runs out -> icon appears) and by your own casts
-- (you cast a watched buff -> icon disappears). Gaps close after combat.
--
-- /bc (or a middle click on an icon) opens the window:
--   * every character has its own list of buffs - add by spell ID (last line), remove with the button,
--     arrows change the order (= order of the icons); changing it never touches other characters
--   * "Add this character" puts the character you are on into the drop-down
--   * the checkbox says whether the character chosen in the drop-down watches that buff
--     (so any character can be set up from any other one)
--   * every line has click slots L, R, S+L, S+R (left / right click, the same with Shift): drop a
--     spell from the spellbook or an item from the bags there and that click on the icon uses it
--     (spells are always cast on yourself). The icon at the start of the line is a slot too:
--     what is dropped there only gives the bar icon its picture.
--   * "Add empty" adds a line that watches no buff: just a button for whatever is dropped into its click
--     slots (a trinket, a potion, a spell). It is always on the bar, in colour.
--     Gear (trinkets, rings) is put on, not used: with two trinkets on L and R the clicks swap them
--     in the same trinket slot, and the icon shows the one you wear.
--   * "always" = the icon is always on the bar: red when the buff is missing, in colour when it is on
--   * "Show all icons" shows the whole row so it can be moved with Alt+drag

local ADDON = ...

---------------------------------------------------------------------------
-- SETTINGS
---------------------------------------------------------------------------
local WARN_SECONDS = 120      -- show the icon when less than this is left (2 min), for every buff
local SHORT_SECONDS = 120     -- a buff lasting this long or less (e.g. a 1-minute proc like Frigid Power) is "short":
                              -- always shown, clock sweep on the icon, red icon when it is missing
local DEFAULT_SIZE = 45  -- icon size (45 = default action buttons); "Icon size" in /bc changes it
local SIZE = DEFAULT_SIZE
local GAP = 4            -- space between icons (about what the action bars have)
local COLUMNS = 6        -- icons per row; more icons start a new row below
-- space between the icons and the frame around them ("Frame" in /bc); the frame's edges are not
-- equally thick (the top is a title bar), so these differ to make the visible gaps look even
local PAD_LEFT, PAD_RIGHT = 14, 13
local PAD_TOP, PAD_BOTTOM = 33, 14

-- DEFAULT BUFFS. They are put into the list on the first run (and by the
-- "Restore defaults" button). In the game they can be removed like any other.
-- These are here because they need more than a spell ID:
--   name      text in the list and tooltip (do not rename - the saved list refers to it)
--   buffs     buff names; any ONE of them being active is enough
--   weapon    true = watch a temporary weapon enchant (oil/stone) on the main hand instead of a buff,
--             "off" = the same on the off hand (fine when the off hand is not a weapon: shield, book, nothing)
--   iconSpell / iconItem   spell ID or item ID to take the icon from (until the buff itself was seen)
--   icon      icon file, used instead of everything else
--   countItem item ID whose count in bags is shown in the corner (when no item is in a click slot)
--   slots     what the clicks do until the player changes it in /bc: L, R, SL, SR, each
--             { kind = "spell" or "item", id = ID and/or name = "Name" }
--   always    the icon is always shown (until the player unticks "always" in /bc)
--   class     a new character only gets it in its list when it is of this class
local DEFAULTS = {
	{ name = "Well Fed", buffs = { "Well Fed" }, icon = "Interface\\Icons\\Spell_Misc_Food" },
	{ name = "Arcane Intellect", buffs = { "Arcane Intellect", "Arcane Brilliance" }, iconSpell = 1459, class = "MAGE",
	  slots = { L = { kind = "spell", name = "Arcane Intellect" } } },
	{ name = "Wizard Oil", weapon = true, iconItem = 20744, countItem = 20744,
	  slots = { L = { kind = "item", id = 20744 } } },
	{ name = "Off-hand Oil", weapon = "off", iconItem = 20744, countItem = 20744,
	  slots = { L = { kind = "item", id = 20744 } } },
	{ name = "Well-Rested", buffs = { "Well-Rested" }, iconSpell = 429959,
	  slots = { L = { kind = "item", name = "Cozy Sleeping Bag" } } },
	{ name = "Amplify / Dampen Magic", buffs = { "Amplify Magic", "Dampen Magic" }, iconSpell = 604, class = "MAGE", always = true,
	  slots = { L = { kind = "spell", name = "Amplify Magic" }, R = { kind = "spell", name = "Dampen Magic" } } },
	{ name = "Mage Armor / Ice Armor", buffs = { "Mage Armor", "Ice Armor", "Frost Armor" }, iconSpell = 7302, class = "MAGE", always = true,
	  slots = { L = { kind = "spell", name = "Mage Armor" }, R = { kind = "spell", name = "Ice Armor" } } },
}

---------------------------------------------------------------------------
-- DATA
-- BuffCheckerDB.chars = per character:
--     list   its buff list, in order. An entry is either
--            { preset = "Well Fed" }  (one of DEFAULTS above), { spell = 1459 } (added by ID)
--            or { empty = 1 } (added with "Add empty": no buff, only click slots; the number tells them apart)
--     watch  which entries are ticked
--     slots  what the clicks on an entry do and which icon it has, when changed in /bc:
--            slots[key] = { L = action, R = action, SL = action, SR = action, icon = action }
--     always entries ticked / unticked as "always" in /bc (true / false)
--     saved  copy of all of the above made by "Save user" ("Restore user" puts it back)
---------------------------------------------------------------------------
local FALLBACK_ICON = 134400 -- question mark
local showAll = false
local buttons = {}
local checks = {}    -- what this character watches right now
local needRebuild = false
local charKey        -- "Name Surname-Realm" of the character you are logged in with (Forever: first names are not unique)
local me             -- its saved settings; nil until "Add this character" is pressed
local selected       -- "Name Surname-Realm" chosen in the window's drop-down
local spellChecks = {}
local checkKeys = {} -- list key of each entry in "checks"
local checkEntries = {} -- and the list entry itself
local RefreshList    -- the window's list, filled in further down

-- race, sex, class, faction and ruleset of the character you are on (saved with it, for the drop-down)
local function MyDetails()
	local ruleset
	if C_GameRules and C_GameRules.IsGameRuleActive and Enum.GameRule then -- same as Baganator / Syndicator show it
		local pvp = Enum.GameRule.PvPRuleset and C_GameRules.IsGameRuleActive(Enum.GameRule.PvPRuleset)
		local rp = Enum.GameRule.RPRuleset and C_GameRules.IsGameRuleActive(Enum.GameRule.RPRuleset)
		local hc = Enum.GameRule.HardcoreRuleset and C_GameRules.IsGameRuleActive(Enum.GameRule.HardcoreRuleset)
		ruleset = (pvp and rp and "RPPvP") or (pvp and "PvP") or (rp and "RP") or (hc and "HC") or "PvE"
	end
	return { race = select(2, UnitRace("player")), sex = UnitSex("player"), class = select(2, UnitClass("player")),
		faction = UnitFactionGroup("player"), ruleset = ruleset }
end

-- how a character is written in the drop-down: race icon and name in its class colour, without the realm.
-- long = also the ruleset and the faction emblem (in the list)
local RACE_ATLAS = { scourge = "undead", zandalaritroll = "zandalari", highmountaintauren = "highmountain",
	lightforgeddraenei = "lightforged", earthendwarf = "earthen", harronir = "haranir" }
local function CharLabel(name, long)
	local char = BuffCheckerDB.chars[name]
	local d = (name == charKey) and MyDetails() or (char and char.details) or {}
	local text = name:match("^[^-]+") or name
	local color = d.class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[d.class]
	if color and color.colorStr then text = "|c" .. color.colorStr .. text .. "|r" end
	if d.race then
		local race = d.race:lower()
		local sex = (d.sex == 3 and "female") or (d.sex == 2 and "male") or "unknown"
		text = "|A:raceicon-" .. (RACE_ATLAS[race] or race) .. "-" .. sex .. ":13:13|a " .. text
	end
	if long then
		if d.ruleset then text = text .. "  |cffbfbfbf" .. d.ruleset .. "|r" end
		if d.faction == "Horde" then
			text = text .. " |A:charcreatetest-logo-horde:16:14|a"
		elseif d.faction == "Alliance" then
			text = text .. " |A:charcreatetest-logo-alliance:16:14|a"
		end
	end
	return text
end

local DEFAULT_BY_NAME = {}
for _, check in ipairs(DEFAULTS) do DEFAULT_BY_NAME[check.name] = check end

local function Key(entry)
	if entry.empty then return "e:" .. entry.empty end
	return entry.preset and ("p:" .. entry.preset) or ("s:" .. entry.spell)
end

-- Turns a list entry into "what to watch". nil = unknown (e.g. default deleted from this file).
local function CopyTable1(t)
	local copy = {}
	for k, v in pairs(t or {}) do copy[k] = v end
	return copy
end

local function CopyList(list)
	local copy = {}
	for i, entry in ipairs(list or {}) do copy[i] = CopyTable1(entry) end
	return copy
end

-- the defaults a new character starts with (those of other classes are left out)
local function DefaultList()
	local _, class = UnitClass("player")
	local list = {}
	for _, check in ipairs(DEFAULTS) do
		if not check.class or check.class == class then list[#list + 1] = { preset = check.name } end
	end
	return list
end

local function InList(list, key)
	for _, entry in ipairs(list or {}) do
		if Key(entry) == key then return true end
	end
	return false
end

-- what an "Add empty" line watches: nothing (it is never missing)
local EMPTY_CHECK = { name = "Empty", empty = true, always = true, buffs = {} }

local function Resolve(entry)
	if entry.empty then return EMPTY_CHECK end
	if entry.preset then return DEFAULT_BY_NAME[entry.preset] end
	local check = spellChecks[entry.spell]
	if not check then
		local spellName = C_Spell.GetSpellName(entry.spell)
		if not spellName then return nil end
		-- watched by NAME, so any rank of the buff counts; left click tries to cast it on yourself
		check = { name = spellName, buffs = { spellName }, iconSpell = entry.spell,
		          slots = { L = { kind = "spell", id = entry.spell, name = spellName } } }
		spellChecks[entry.spell] = check
	end
	return check
end

-- CLICK SLOTS. An action is { kind = "spell" or "item", id = ID, name = "Name" } (id or name may be missing).
local SLOTS = { "L", "R", "SL", "SR" }
local SLOT_LABEL = { L = "L", R = "R", SL = "S+L", SR = "S+R" }
local SLOT_TIP = { L = "Left click", R = "Right click", SL = "Shift + left click", SR = "Shift + right click" }
local EMPTY = {}

local function ActionName(a)
	if a.kind == "spell" then return (a.id and C_Spell.GetSpellName(a.id)) or a.name end
	return (a.id and C_Item.GetItemNameByID(a.id)) or a.name
end

local function ActionIcon(a)
	local icon
	if a.kind == "spell" then
		icon = C_Spell.GetSpellTexture(a.id or a.name)
	else
		icon = C_Item.GetItemIconByID(a.id or a.name)
	end
	return icon or FALLBACK_ICON
end

-- Gear that goes into one of two slots: which pair it is.
local PAIR_SLOTS = { INVTYPE_TRINKET = { 13, 14 }, INVTYPE_FINGER = { 11, 12 } }

-- The equipment slot an item from a click slot is put on: a trinket goes where another trinket
-- of the same line is now (so left / right click swap the two), otherwise into the first trinket slot.
-- nil = let the game choose.
local function EquipSlot(a, actions)
	local equipLoc = C_Item.GetItemInfoInstant and select(4, C_Item.GetItemInfoInstant(a.id))
	local pair = equipLoc and PAIR_SLOTS[equipLoc]
	if not pair then return nil end
	for _, slot in ipairs(pair) do
		local worn = GetInventoryItemID("player", slot)
		for _, name in ipairs(SLOTS) do
			local other = actions and actions[name]
			if worn and other and other.kind == "item" and other.id == worn then return slot end
		end
	end
	return pair[1]
end

-- the macro text a click runs; spells always go on yourself, gear (trinkets...) is put on
local function ActionMacro(a, check, actions)
	if not a then return nil end
	local name = ActionName(a)
	if a.kind == "spell" then return name and ("/cast [@player] " .. name) or nil end
	if not a.id and not name then return nil end
	if a.id and C_Item.IsEquippableItem and C_Item.IsEquippableItem(a.id) then
		local slot = EquipSlot(a, actions)
		if slot then return "/equipslot " .. slot .. " item:" .. a.id end
		return "/equip item:" .. a.id
	end
	local text = "/use " .. (a.id and ("item:" .. a.id) or name)
	if check.weapon then -- oil/stone: put it on the main hand (16) or the off hand (17)
		text = text .. "\n/use " .. (check.weapon == "off" and 17 or 16)
	end
	return text
end

-- what is on the mouse cursor, as an action. nil = nothing, false = something that cannot be used here
local function CursorAction()
	local kind, a, _, c = GetCursorInfo()
	if not kind then return nil end
	if kind == "item" and a then return { kind = "item", id = a, name = C_Item.GetItemNameByID(a) } end
	if kind == "spell" and c then return { kind = "spell", id = c, name = C_Spell.GetSpellName(c) } end
	return false
end

-- the slots of an entry for a character: its own when changed in /bc, otherwise the entry's defaults.
-- (Read only - change them with SetSlot.)
local function SlotsFor(char, entry)
	local own = char and char.slots and char.slots[Key(entry)]
	if own then return own end
	local check = Resolve(entry)
	return check and check.slots or EMPTY
end

local function SetSlot(char, entry, slot, action)
	char.slots = char.slots or {}
	local key = Key(entry)
	if not char.slots[key] then char.slots[key] = CopyTable1(SlotsFor(char, entry)) end
	char.slots[key][slot] = action
end

local function CopySlots(slots)
	local copy = {}
	for key, t in pairs(slots or {}) do copy[key] = CopyTable1(t) end
	return copy
end

local function IsAlways(char, entry)
	local own = char and char.always and char.always[Key(entry)]
	if own ~= nil then return own end
	local check = Resolve(entry)
	return check and check.always or false
end

local function IsSecret(v)
	return issecretvalue and issecretvalue(v)
end

-- true when the game hides buffs from addons right now: combat, but also a boss
-- encounter (that one can start a moment before combat and end a moment after it).
-- Reading buffs then looks like "you have none", so we must not read at all.
local function AurasHidden()
	if InCombatLockdown() then return true end
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local ok, hidden = pcall(C_Secrets.ShouldAurasBeSecret)
		if not ok or IsSecret(hidden) then return true end
		return hidden and true or false
	end
	return false
end

local function GetIcon(check)
	local icon
	if check.icon then
		icon = check.icon
	elseif check.iconSpell and C_Spell and C_Spell.GetSpellTexture then
		icon = C_Spell.GetSpellTexture(check.iconSpell)
	elseif check.iconItem and C_Item and C_Item.GetItemIconByID then
		icon = C_Item.GetItemIconByID(check.iconItem)
	end
	return icon or FALLBACK_ICON
end

-- Returns: active (true/false, or nil = the game does not let us read it right now),
--          secondsLeft (nil = no timer), total duration of the buff in seconds (nil = unknown),
--          icon of the buff that is on (nil = unknown)
local function GetState(check, buffs)
	if check.empty then return true end -- no buff: always fine
	if check.weapon then
		local off = check.weapon == "off"
		if off then -- shield, book or nothing in the off hand: nothing to put oil on, do not nag
			local id = GetInventoryItemID("player", 17)
			local classID = id and select(6, C_Item.GetItemInfoInstant(id))
			if classID ~= (Enum.ItemClass and Enum.ItemClass.Weapon or 2) then return true end
		end
		if C_Item and C_Item.GetWeaponEnchantInfo and Enum.WeaponSlot and Enum.ItemEnchantType then
			local list = C_Item.GetWeaponEnchantInfo(off and Enum.WeaponSlot.OffHand or Enum.WeaponSlot.MainHand)
			if IsSecret(list) then return nil end
			for _, entry in ipairs(list or {}) do
				if IsSecret(entry) or IsSecret(entry.hasEnchant) or IsSecret(entry.timeLeft) then return nil end
				if entry.hasEnchant and entry.enchantType == Enum.ItemEnchantType.Temporary then
					return true, entry.timeLeft / 1000
				end
			end
			return false
		elseif GetWeaponEnchantInfo then
			local has, timeLeft, _, _, offHas, offTimeLeft = GetWeaponEnchantInfo()
			if off then has, timeLeft = offHas, offTimeLeft end
			return has and true or false, has and timeLeft and timeLeft / 1000 or nil
		end
		return true -- cannot read it, do not nag
	end

	local active, best, bestDuration, bestIcon = false, nil, nil, nil
	for _, buffName in ipairs(buffs or check.buffs or EMPTY) do
		local aura = C_UnitAuras.GetAuraDataBySpellName("player", buffName, "HELPFUL")
		if IsSecret(aura) then return nil end
		if aura then
			local exp = aura.expirationTime
			if IsSecret(exp) then return nil end
			local icon = not IsSecret(aura.icon) and aura.icon or nil
			if not exp or exp == 0 then return true, nil, nil, icon end -- no timer = fine
			local left = exp - GetTime()
			active = true
			if not best or left > best then
				best = left
				bestDuration = not IsSecret(aura.duration) and aura.duration or nil
				bestIcon = icon
			end
		end
	end
	return active, best, bestDuration, bestIcon
end

-- Icons of an entry. Returns: fixed (set by hand - never changes; nil = none),
-- base (shown while the buff is missing: the buff's icon as the game last showed it).
local function EntryIcons(char, entry, check)
	local slots = SlotsFor(char, entry)
	local fixed = (slots.icon and ActionIcon(slots.icon)) or check.icon
	local base = BuffCheckerDB.icons[Key(entry)]
	if not base and check.weapon then -- oil/stone: the item you put on
		for _, name in ipairs(SLOTS) do
			if slots[name] and slots[name].kind == "item" then base = ActionIcon(slots[name]) break end
		end
	end
	if check.empty then -- no buff: the gear of the line you wear now, else the first thing in its click slots
		base = nil
		for _, name in ipairs(SLOTS) do
			local a = slots[name]
			if a and a.kind == "item" and a.id and C_Item.IsEquippedItem and C_Item.IsEquippedItem(a.id) then
				base = ActionIcon(a)
				break
			end
		end
		for _, name in ipairs(SLOTS) do
			if base then break end
			if slots[name] then base = ActionIcon(slots[name]) end
		end
	end
	return fixed, base or GetIcon(check)
end

---------------------------------------------------------------------------
-- THE ROW OF ICONS
---------------------------------------------------------------------------
-- One parent frame: all icons live inside it, so they move as one block.
local bar = CreateFrame("Frame", "BuffCheckerBar", UIParent)
bar:SetSize(SIZE, SIZE)

-- optional frame around the visible icons ("Frame" checkbox in /bc): the game's own
-- window template (as the /bc window and Baganator's bags), without the portrait
local border = CreateFrame("Frame", "BuffCheckerFrame", bar, "ButtonFrameTemplate")
border:SetFrameLevel(math.max(0, bar:GetFrameLevel() - 1))
-- exactly what Baganator does for its bags
ButtonFrameTemplate_HidePortrait(border)
ButtonFrameTemplate_HideButtonBar(border)
if border.Inset then border.Inset:Hide() end
-- The frame's edges as in Baganator's "Blizzard black" skin (with a flat dark background).
local BORDER_LAYOUT = {
	disableSharpening = true,
	TopLeftCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerTopLeft", x = -13, y = 16, },
	TopRightCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerTopRight", x = 4, y = 16, },
	BottomLeftCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomLeft", x = -13, y = -3, },
	BottomRightCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomRight", x = 4, y = -3, },
	TopEdge = { layer = "OVERLAY", atlas = "_UI-Frame-Metal-EdgeTop", x = 0, y = 0, x1 = 0, y1 = 0, },
	BottomEdge = { layer = "OVERLAY", atlas = "_UI-Frame-Metal-EdgeBottom", x = 0, y = 0, x1 = 0, y1 = 0, },
	LeftEdge = { layer = "OVERLAY", atlas = "!UI-Frame-Metal-EdgeLeft", x = 0, y = 0, x1 = 0, y1 = 0 },
	RightEdge = { layer = "OVERLAY", atlas = "!UI-Frame-Metal-EdgeRight", x = 0, y = 0, x1 = 0, y1 = 0, },
}
if border.Bg then border.Bg:Hide() end
if border.TopTileStreaks then border.TopTileStreaks:Hide() end
local flatBg = CreateFrame("Frame", nil, border, "FlatPanelBackgroundTemplate")
flatBg:SetFrameLevel(border:GetFrameLevel())
flatBg:SetPoint("TOPLEFT", 2, -3)
flatBg:SetPoint("BOTTOMRIGHT", -2, -3)
if border.NineSlice then
	border.NineSlice:SetPoint("BOTTOMRIGHT", 0, -5) -- the Forever client's bottom edge sits lower (as in Baganator)
	NineSliceUtil.ApplyLayout(border.NineSlice, BORDER_LAYOUT, border.NineSlice:GetFrameLayoutTextureKit())
end

-- The corner pictures are big (about 94 x 94) and this frame is small, so they would overlap and
-- draw over each other's bevel. Each corner is cut down to at most its half of the frame
-- (keeping the part at the frame's corner). Done again whenever the frame changes size.
local CORNERS = {
	TopLeftCorner = { left = true, top = true }, TopRightCorner = { top = true },
	BottomLeftCorner = { left = true }, BottomRightCorner = {},
}
local function FitCorners(width, height)
	local ns = border.NineSlice
	if not ns then return end
	-- the edges reach past the frame: 13 left, 4 right, 16 up, 8 down (see BORDER_LAYOUT)
	local halfW, halfH = math.floor((width + 13 + 4) / 2), math.floor((height + 16 + 8) / 2)
	for key, side in pairs(CORNERS) do
		local piece = ns[key]
		local info = piece and C_Texture.GetAtlasInfo(BORDER_LAYOUT[key].atlas)
		if info then
			local w, h = math.min(info.width, halfW), math.min(info.height, halfH)
			local l, r, t, b = 0, 1, 0, 1 -- for a picture set by atlas these are relative to that picture
			if side.left then r = l + (r - l) * w / info.width else l = r - (r - l) * w / info.width end
			if side.top then b = t + (b - t) * h / info.height else t = b - (b - t) * h / info.height end
			piece:SetSize(w, h)
			piece:SetTexCoord(l, r, t, b)
		end
	end
end
border:Hide()

-- close button (X) of the template: hides the icons until /bc is opened again
border.close = border.CloseButton
local titleBar = border.TitleContainer or border -- sits above the frame's edges

-- gear button in the title bar next to the X (like Baganator's): opens the /bc window
border.gear = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
border.gear:SetSize(30, 20)
border.gear:SetPoint("RIGHT", border.close, "LEFT", -2, 0)
border.gear.icon = border.gear:CreateTexture(nil, "OVERLAY")
border.gear.icon:SetTexture("Interface\\WorldMap\\GEAR_64GREY") -- the game's own gear icon (menus)
border.gear.icon:SetVertexColor(1, 0.82, 0) -- gold, like the X
border.gear.icon:SetPoint("CENTER")
border.gear.icon:SetSize(16, 16)

-- title, centred in the title bar left of the buttons
border.title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
border.title:SetPoint("TOPLEFT", border, "TOPLEFT", 8, -5)
border.title:SetPoint("RIGHT", border.gear, "LEFT", -4, 0)
border.title:SetJustifyH("CENTER")
border.title:SetWordWrap(false)
border.title:SetText("Buff Checker")
border.gear:SetScript("OnClick", function()
	BuffCheckerWindow:SetShown(not BuffCheckerWindow:IsShown())
end)
border.gear:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Buff Checker settings (/bc)")
	GameTooltip:Show()
end)
border.gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Alt+drag the frame or an icon moves the whole bar (Shift is taken by the Shift+click slots)
local function StartMove()
	if IsAltKeyDown() and not InCombatLockdown() then bar:StartMoving() end
end
local function StopMove()
	bar:StopMovingOrSizing()
	local point, _, relPoint, x, y = bar:GetPoint()
	BuffCheckerDB.pos = { point, relPoint, x, y }
end
border:EnableMouse(true)
border:RegisterForDrag("LeftButton")
border:SetScript("OnDragStart", StartMove)
border:SetScript("OnDragStop", StopMove)

border.close:SetScript("OnClick", function()
	if InCombatLockdown() then return end -- clickable icons cannot be hidden in combat
	BuffCheckerDB.hidden = true
	bar:Hide()
	print("Buff Checker: icons hidden - /bc shows them again.")
end)

-- frame around the first "count" places of the grid
local function UpdateBorder(count)
	if not (BuffCheckerDB and BuffCheckerDB.frame) or count == 0 then
		border:Hide()
		return
	end
	local cols, rows = math.min(count, COLUMNS), math.ceil(count / COLUMNS)
	border:ClearAllPoints()
	-- at least wide enough for the title and the buttons; when wider than the icons, they sit in the middle
	local width = cols * (SIZE + GAP) - GAP + PAD_LEFT + PAD_RIGHT
	local extra = math.max(0, 170 - width)
	border:SetPoint("TOPLEFT", bar, "TOPLEFT", -PAD_LEFT - extra / 2, PAD_TOP)
	local height = rows * (SIZE + GAP) - GAP + PAD_TOP + PAD_BOTTOM
	border:SetSize(width + extra, height)
	FitCorners(width + extra, height)
	border:Show()
end

-- puts a button at place n (0 = first) of the grid: COLUMNS per row, rows go down
local function Place(b, n)
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", bar, "TOPLEFT", (n % COLUMNS) * (SIZE + GAP), -math.floor(n / COLUMNS) * (SIZE + GAP))
	b.place = n
end
bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
bar:SetMovable(true)
bar:SetClampedToScreen(true)

-- Looks at one buff and paints its button. Returns true when the icon should be visible,
-- false when the buff is fine, nil when the game does not let us read it right now.
-- Also remembers what it saw (b.missing, b.expires, b.duration) for use in combat.
-- like the game's own buffs: minutes down to 100 seconds, from 99 on seconds
local function TimeText(left)
	if left >= 100 then return math.ceil(left / 60) .. "m" end
	return math.floor(left) .. "s" -- a fresh 1-minute buff starts at 59
end

-- Draws a button from what is remembered about it (b.missing, b.expires, b.duration),
-- without reading the game - so it also works in combat. Returns true when the icon should be visible.
local function Look(b)
	local left = b.expires and (b.expires - GetTime())
	if left and left <= 0 then b.missing, b.expires, left = true, nil, nil end -- its time ran out
	local short = b.duration and b.duration <= SHORT_SECONDS
	local expiring = not b.missing and left and left < WARN_SECONDS
	b.icon:SetDesaturated(b.missing) -- missing = black and white with a red tint on top
	if b.missing then b.icon:SetVertexColor(1, 0.35, 0.35) else b.icon:SetVertexColor(1, 1, 1) end
	-- the icon set by hand, else the buff you have (Mage Armor or Ice Armor...), else the one last seen
	local tex = b.fixedIcon or (not b.missing and b.activeIcon) or b.baseIcon
	if tex ~= b.shownIcon then
		b.shownIcon = tex
		b.icon:SetTexture(tex)
	end
	b.time:SetText(expiring and TimeText(left) or "")
	-- clock sweep, only for short buffs
	local start = short and expiring and (b.expires - b.duration) or nil
	if start ~= b.cdStart then
		b.cdStart = start
		if start then b.cd:SetCooldown(start, b.duration) else b.cd:SetCooldown(0, 0) end
	end
	b.status = (b.missing and "Missing") or (expiring and "Expires soon") or "OK"
	return (b.missing or expiring or b.always) and true or false
end

local function Paint(b, check)
	local active, left, duration, icon = GetState(check, b.buffs)
	if active == nil then return nil end
	b.activeIcon = active and icon or nil
	local db = BuffCheckerDB
	if db and b.key and active and icon and db.icons[b.key] ~= icon then -- the icon as the game shows it
		db.icons[b.key] = icon
		b.baseIcon = icon
	end
	if db and b.key and duration and duration > 0 then db.durations[b.key] = duration end -- remembered for combat
	b.duration = (db and b.key and db.durations[b.key]) or duration
	b.missing = not active
	b.expires = left and (GetTime() + left) or nil -- nil = no timer
	local count = b.countItem and C_Item.GetItemCount(b.countItem)
	if check.empty and count == 1 then count = nil end -- a trinket: no "1" on it
	b.count:SetText(count or "")
	return Look(b)
end

local function Update()
	if AurasHidden() then
		-- In combat the game hides buffs from addons and does not allow showing, hiding or
		-- moving clickable buttons. So here nothing is read from the game: we go by what was
		-- seen just before combat (b.missing, b.expires) and by the clock, and only make the
		-- buttons visible / invisible. A buff you cast in combat is noticed by OnPlayerCast below.
		local last = 0 -- the frame reaches to the last visible icon
		for i in ipairs(checks) do
			local b = buttons[i]
			if b:IsShown() then
				b:SetAlpha(Look(b) and 1 or 0)
				if b:GetAlpha() > 0 and b.place then last = math.max(last, b.place + 1) end
			end
		end
		UpdateBorder(last)
		return
	end
	local shown = 0
	for i, check in ipairs(checks) do
		local b = buttons[i]
		local visible = Paint(b, check)
		b:SetAlpha(1)
		if showAll or visible then
			Place(b, shown)
			b:Show()
			shown = shown + 1
		else
			b:Hide()
		end
	end
	UpdateBorder(shown)
end

-- Out of combat: a short buff that appeared right after your cast was put on by that spell
-- (e.g. Ice Barrier -> Frigid Power). Remembered, so the same cast counts in combat too.
local function LearnTrigger(spellID)
	if AurasHidden() then return end
	for i, check in ipairs(checks) do
		local b = buttons[i]
		if b.key and check.buffs then
			local active, left, duration = GetState(check, b.buffs)
			if active and left and duration and duration <= SHORT_SECONDS and duration - left < 0.8 then
				BuffCheckerDB.triggers[spellID] = b.key
			end
		end
	end
end

-- Spells that put on a buff with a different name: cast spell -> buff, its duration in seconds.
-- (Others are learned on their own out of combat, see LearnTrigger.)
local TRIGGERS = {
	["Ice Barrier"] = { buff = "Frigid Power", seconds = 60 },
}

-- In combat the game hides which spell the cast event is about, so the press of an
-- action bar button (or its key) is remembered here and paired with the next successful cast.
local pressed -- { id = spellID, time = GetTime() }
hooksecurefunc("UseAction", function(slot)
	if not AurasHidden() then return end
	local kind, id = GetActionInfo(slot)
	if IsSecret(kind) or IsSecret(id) then return end
	if kind == "macro" and GetMacroSpell then
		id = GetMacroSpell(id)
		if IsSecret(id) then return end
		kind = "spell"
	end
	if kind ~= "spell" or not id then return end
	pressed = { id = id, time = GetTime() }
end)

-- The same for a click on one of our own icons (they cast by macro, not through the action bar).
local pressedOwn -- { b = button, slot = which click slot it was ("L", "SR"...), time = GetTime() }
local function OnOwnClick(self, mouseButton)
	if not AurasHidden() or IsAltKeyDown() or IsControlKeyDown() then return end
	if mouseButton ~= "LeftButton" and mouseButton ~= "RightButton" then return end
	local slot = (IsShiftKeyDown() and "S" or "") .. (mouseButton == "RightButton" and "R" or "L")
	if self.actions and self.actions[slot] then pressedOwn = { b = self, slot = slot, time = GetTime() } end
end

-- In combat: you cast a spell. If it is one of the watched buffs (or the spell that puts it on),
-- the buff counts as freshly on for its usual duration - buffs are not read for this.
-- (The real state is read again after combat.)
local function OnPlayerCast(spellID)
	if IsSecret(spellID) then spellID = nil end
	if not AurasHidden() then
		if spellID then C_Timer.After(0.3, function() LearnTrigger(spellID) end) end
		return
	end
	if not spellID and pressed and GetTime() - pressed.time < 0.7 then spellID = pressed.id end
	pressed = nil
	if not spellID and pressedOwn and GetTime() - pressedOwn.time < 0.7 then
		-- the cast came from a click on our icon: that buff is on now
		local b, slot = pressedOwn.b, pressedOwn.slot
		pressedOwn = nil
		if b.check then
			b.missing = false
			b.expires = b.duration and (GetTime() + b.duration) or nil
			-- which spell it was: the one in that click slot
			local a = b.actions and b.actions[slot]
			local icon = a and a.kind == "spell" and C_Spell.GetSpellTexture(a.id or a.name)
			if icon and not IsSecret(icon) then b.activeIcon = icon end
			Update()
		end
		return
	end
	pressedOwn = nil
	if not spellID then return end
	local learned = BuffCheckerDB.triggers[spellID]
	local spellName = C_Spell.GetSpellName(spellID)
	if IsSecret(spellName) then spellName = nil end
	local trigger = spellName and TRIGGERS[spellName]
	for i, check in ipairs(checks) do
		local b = buttons[i]
		local hit = learned ~= nil and learned == b.key
		local seconds = b.duration
		local named = false
		for _, buffName in ipairs(b.buffs or check.buffs or EMPTY) do
			if spellName and buffName == spellName then hit, named = true, true end
			if trigger and buffName == trigger.buff then
				hit = true
				seconds = seconds or trigger.seconds
			end
		end
		if hit then
			b.missing = false
			b.expires = seconds and (GetTime() + seconds) or nil
			if named then -- the cast spell is the buff itself: show its icon
				local icon = C_Spell.GetSpellTexture(spellID)
				if icon and not IsSecret(icon) then b.activeIcon = icon end
			end
		end
	end
	Update()
end

-- Runs at the moment combat starts (the last moment buttons may still be shown/moved).
-- The icons that are visible now stay where they are; the buffs that are fine get an
-- INVISIBLE button to the right of them, so the icon can appear if the buff runs out in combat.
local function CombatLayout()
	local shown = 0
	local fine = {}
	for i, check in ipairs(checks) do
		local b = buttons[i]
		-- no reading here (buffs may already be hidden from addons): what was shown a moment ago stays shown
		if b:IsShown() and b:GetAlpha() > 0 and not showAll then
			b:SetAlpha(1)
			Place(b, shown)
			b:Show()
			shown = shown + 1
		else
			fine[#fine + 1] = b
		end
	end
	for _, b in ipairs(fine) do
		b:SetAlpha(0)
		Place(b, shown)
		b:Show()
		shown = shown + 1
	end
end

local Rebuild -- defined below

local function SizeButton(b)
	b:SetSize(SIZE, SIZE)
	-- the game's action button is 45 wide; its frame pictures are 46x45 and the mask is bigger than the icon
	local k = SIZE / 45
	for _, t in ipairs(b.frameArt) do t:SetSize(46 * k, 45 * k) end
	local info = C_Texture.GetAtlasInfo("UI-HUD-ActionBar-IconFrame-Mask")
	b.mask:SetSize((info and info.width or 64) * k, (info and info.height or 64) * k)
	b.cd:ClearAllPoints()
	b.cd:SetPoint("TOPLEFT", b.icon, 3 * k, -3 * k)
	b.cd:SetPoint("BOTTOMRIGHT", b.icon, -3 * k, 3 * k)
end

local OnWheel -- Ctrl + mouse wheel changes the icon size; defined further down

local function CreateButton(i)
	local b = CreateFrame("Button", "BuffCheckerButton" .. i, bar, "SecureActionButtonTemplate")
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:SetScript("OnMouseWheel", function(self, delta) OnWheel(delta) end)
	b:Hide()

	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()

	-- same look as the game's action bar buttons (ActionButtonTemplate): rounded icon, thin frame
	b.mask = b:CreateMaskTexture()
	b.mask:SetAtlas("UI-HUD-ActionBar-IconFrame-Mask")
	b.mask:SetPoint("CENTER", b.icon)
	b.icon:AddMaskTexture(b.mask)
	b:SetNormalAtlas("UI-HUD-ActionBar-IconFrame")
	b:SetPushedAtlas("UI-HUD-ActionBar-IconFrame-Down")
	b:SetHighlightAtlas("UI-HUD-ActionBar-IconFrame-Mouseover")
	b.frameArt = { b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture() }
	for _, t in ipairs(b.frameArt) do
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT")
	end

	-- clock sweep (short buffs); the texts sit on a frame above it so they stay readable
	b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cd:SetReverse(true)
	b.cd:SetDrawEdge(false)
	b.cd:SetDrawBling(false)
	b.cd:SetHideCountdownNumbers(true)
	SizeButton(b)
	local texts = CreateFrame("Frame", nil, b)
	texts:SetAllPoints()
	texts:SetFrameLevel(b.cd:GetFrameLevel() + 1)

	b.count = texts:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", -2, 2)
	b.time = texts:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.time:SetPoint("TOPLEFT", 2, -2)

	b:SetScript("OnEnter", function(self)
		if not self.check or self:GetAlpha() == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.check.empty then
			-- an "Add empty" line: no buff, named after the first thing in its click slots
			local title = "Empty"
			for _, name in ipairs(SLOTS) do
				local a = self.actions and self.actions[name]
				if a then title = ActionName(a) or "?" break end
			end
			GameTooltip:AddLine(title)
		else
			GameTooltip:AddLine(self.check.name)
			GameTooltip:AddLine(self.status or "", 1, 1, 1)
		end
		for _, name in ipairs(SLOTS) do
			local a = self.actions and self.actions[name]
			if a then GameTooltip:AddLine(SLOT_TIP[name] .. ": " .. (ActionName(a) or "?"), 0.6, 0.6, 0.6) end
		end
		GameTooltip:AddLine("Middle click opens /bc (clicks are set there). Alt+drag moves the bar. Ctrl+wheel = size.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)

	-- a spell or an item dropped on the icon: from now on a left click uses it
	b:SetScript("OnReceiveDrag", function(self)
		if InCombatLockdown() or not me or not self.entry then return end
		local action = CursorAction()
		if not action then return end
		SetSlot(me, self.entry, "L", action)
		ClearCursor()
		Rebuild()
		if RefreshList and BuffCheckerWindow:IsShown() then RefreshList() end
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Alt+drag any icon moves the whole bar
	b:RegisterForDrag("LeftButton")
	b:HookScript("PostClick", OnOwnClick)
	-- middle click (mouse wheel) opens / closes the /bc window; it has no click slot, so it casts nothing
	b:HookScript("PostClick", function(self, mouseButton, down)
		if mouseButton == "MiddleButton" and not down then
			BuffCheckerWindow:SetShown(not BuffCheckerWindow:IsShown())
		end
	end)
	b:SetScript("OnDragStart", StartMove)
	b:SetScript("OnDragStop", StopMove)
	return b
end

-- Takes the ticked entries of the list and gives each its button.
-- Not possible in combat - then it is done after it.
Rebuild = function()
	if InCombatLockdown() then
		needRebuild = true
		return
	end
	needRebuild = false

	checks, checkKeys, checkEntries = {}, {}, {}
	for _, entry in ipairs(me and me.list or {}) do
		local check = me.watch[Key(entry)] and Resolve(entry)
		if check then
			checks[#checks + 1] = check
			checkKeys[#checks] = Key(entry)
			checkEntries[#checks] = entry
		end
	end

	for i, check in ipairs(checks) do
		local b = buttons[i] or CreateButton(i)
		buttons[i] = b
		b.check = check
		b.key = checkKeys[i]
		local entry = checkEntries[i]
		local slots = SlotsFor(me, entry)
		b.entry = entry
		b.actions = slots
		b.always = IsAlways(me, entry)
		b.fixedIcon, b.baseIcon = EntryIcons(me, entry, check)
		b.shownIcon = nil
		b.icon:SetTexture(b.fixedIcon or b.baseIcon)
		-- the buff counts as on when any of its names is on: its own, or a spell in a click slot
		-- (Mage Armor on left click, Ice Armor on right click -> either one is fine)
		b.buffs, b.countItem = {}, check.countItem
		local seen, firstItem = {}, nil
		for _, buffName in ipairs(check.buffs or EMPTY) do
			seen[buffName] = true
			b.buffs[#b.buffs + 1] = buffName
		end
		for _, name in ipairs(SLOTS) do
			local a = slots[name]
			local actionName = a and ActionName(a)
			if a and a.kind == "spell" and actionName and not seen[actionName] then
				seen[actionName] = true
				b.buffs[#b.buffs + 1] = actionName
			elseif a and a.kind == "item" and a.id and not firstItem then
				firstItem = a.id
			end
		end
		if firstItem then b.countItem = firstItem end
		-- an empty slot does nothing; neither does a click with Alt or Ctrl (Alt+drag moves the bar)
		b:SetAttribute("type", nil)
		b:SetAttribute("macrotext", nil)
		for name, suffix in pairs({ L = "1", R = "2" }) do
			local plain, shift = ActionMacro(slots[name], check, slots), ActionMacro(slots["S" .. name], check, slots)
			b:SetAttribute("type" .. suffix, plain and "macro" or nil)
			b:SetAttribute("macrotext" .. suffix, plain)
			b:SetAttribute("shift-type" .. suffix, shift and "macro" or nil)
			b:SetAttribute("shift-macrotext" .. suffix, shift)
		end
	end
	for i = #checks + 1, #buttons do
		buttons[i].check = nil
		buttons[i].key = nil
		buttons[i].entry = nil
		buttons[i].actions = nil
		buttons[i]:Hide()
	end
	bar:SetSize(math.max(1, math.min(#checks, COLUMNS)) * (SIZE + GAP) - GAP, SIZE)
	Update()
end

---------------------------------------------------------------------------
-- WINDOW (/bc)
---------------------------------------------------------------------------
local ROW = 28
local rows = {}

local window = CreateFrame("Frame", "BuffCheckerWindow", UIParent, "ButtonFrameTemplate")
window:Hide()
window:SetSize(600, 590)
window:SetPoint("CENTER")
window:SetToplevel(true)
window:SetMovable(true)
window:SetClampedToScreen(true)
window:EnableMouse(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", window.StopMovingOrSizing)
tinsert(UISpecialFrames, "BuffCheckerWindow") -- Esc closes it

-- Middle click anywhere over the window closes it. The buttons inside the window
-- take the click themselves, so watch the global mouse-up instead of the window.
-- (the event is switched on and off in OnShow/OnHide further down)
window:SetScript("OnEvent", function(self, event, mouseButton)
	if mouseButton == "MiddleButton" and self:IsMouseOver() then self:Hide() end
end)

if window.SetTitle then
	window:SetTitle("Buff Checker")
elseif BuffCheckerWindowTitleText then
	BuffCheckerWindowTitleText:SetText("Buff Checker")
end
local portrait = (window.PortraitContainer and window.PortraitContainer.portrait) or window.portrait

-- top line: whose ticks are shown / edited
local charDropDown = CreateFrame("Frame", "BuffCheckerCharDropDown", window, "UIDropDownMenuTemplate")
charDropDown:SetPoint("TOPLEFT", 48, -28)
UIDropDownMenu_SetWidth(charDropDown, 150)

local addCharButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
addCharButton:SetSize(96, 22)
addCharButton:SetPoint("TOPRIGHT", -84, -31)
addCharButton:SetText("Add this char")

local removeCharButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
removeCharButton:SetSize(70, 22)
removeCharButton:SetPoint("LEFT", addCharButton, "RIGHT", 4, 0)
removeCharButton:SetText("Remove")

-- copies the list of the character chosen in the drop-down onto the one you are on
local copyCharButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
copyCharButton:SetSize(130, 22)
copyCharButton:SetPoint("LEFT", charDropDown, "RIGHT", -6, 2)
copyCharButton:SetText("Copy from this char")

-- second line: buffs you have on you right now -> pick one and add it
local buffDropDown = CreateFrame("Frame", "BuffCheckerActiveBuffDropDown", window, "UIDropDownMenuTemplate")
buffDropDown:SetPoint("TOPLEFT", 48, -60)
UIDropDownMenu_SetWidth(buffDropDown, 150)
local pickedBuff -- spell ID chosen in this drop-down

local addBuffButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
addBuffButton:SetSize(70, 22)
addBuffButton:SetPoint("LEFT", buffDropDown, "RIGHT", -10, 2)
addBuffButton:SetText("Add")

-- icon size, right of the Add button (Enter applies)
local sizeBox = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
sizeBox:SetSize(32, 20)
sizeBox:SetPoint("TOPRIGHT", -14, -62)
sizeBox:SetAutoFocus(false)
sizeBox:SetNumeric(true)
sizeBox:SetMaxLetters(2)
local sizeLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sizeLabel:SetPoint("RIGHT", sizeBox, "LEFT", -8, 0)
sizeLabel:SetText("Icon size")

local message = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
message:SetPoint("TOPLEFT", 14, -98)
message:SetPoint("RIGHT", -14, 0)
message:SetJustifyH("LEFT")
local HINT = "Tick = watch. Drop a spell or an item on L / R / S+L / S+R = that click uses it (right click empties)."
message:SetText(HINT)

-- middle: the list (scrolls when long)
if window.Inset then
	window.Inset:ClearAllPoints()
	window.Inset:SetPoint("TOPLEFT", 4, -116)
	window.Inset:SetPoint("BOTTOMRIGHT", -6, 30)
end
local scroll = CreateFrame("ScrollFrame", "BuffCheckerScroll", window, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -122)
scroll:SetPoint("BOTTOMRIGHT", -32, 34)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(550, 10)
scroll:SetScrollChild(content)

-- last line of the list: add a buff by spell ID
local addRow = CreateFrame("Frame", nil, content)
addRow:SetSize(550, 26)
local addLabel = addRow:CreateFontString(nil, "ARTWORK", "GameFontNormal")
addLabel:SetPoint("LEFT", 4, 0)
addLabel:SetText("Spell ID:")

local input = CreateFrame("EditBox", nil, addRow, "InputBoxTemplate")
input:SetSize(90, 22)
input:SetPoint("LEFT", addLabel, "RIGHT", 12, 0)
input:SetAutoFocus(false)
input:SetNumeric(true)
input:SetMaxLetters(7)

local addButton = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
addButton:SetSize(70, 22)
addButton:SetPoint("LEFT", input, "RIGHT", 8, 0)
addButton:SetText("Add")

local addHint = addRow:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
addHint:SetPoint("LEFT", addButton, "RIGHT", 8, 0)
addHint:SetText("number from the Wowhead URL")

local addEmptyButton = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
addEmptyButton:SetSize(90, 22)
addEmptyButton:SetPoint("RIGHT", -4, 0)
addEmptyButton:SetText("Add empty")

-- small arrow button used for moving a line up / down
local function ArrowButton(parent, direction)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(22, 22)
	b:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. direction .. "-Up")
	b:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. direction .. "-Down")
	b:SetDisabledTexture("Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. direction .. "-Disabled")
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	return b
end

-- bottom: show all icons / save + restore user defaults / restore defaults
local showAllBox = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
showAllBox:SetSize(24, 24)
showAllBox:SetPoint("BOTTOMLEFT", 8, 3)
local showAllLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
showAllLabel:SetPoint("LEFT", showAllBox, "RIGHT", 2, 0)
showAllLabel:SetText("Show all")
showAllBox:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Show all icons")
	GameTooltip:AddLine("Move the row: Alt+drag an icon", 1, 1, 1)
	GameTooltip:Show()
end)
showAllBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
showAllBox:SetScript("OnClick", function(self)
	showAll = self:GetChecked() and true or false
	Update()
end)

local frameBox = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
frameBox:SetSize(24, 24)
frameBox:SetPoint("LEFT", showAllLabel, "RIGHT", 6, 0)
local frameLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
frameLabel:SetPoint("LEFT", frameBox, "RIGHT", 2, 0)
frameLabel:SetText("Frame")
frameBox:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Frame around the icons")
	GameTooltip:AddLine("The game's window border and background behind the icons", 1, 1, 1)
	GameTooltip:Show()
end)
frameBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
frameBox:SetScript("OnClick", function(self)
	BuffCheckerDB.frame = self:GetChecked() and true or nil
	Update()
end)

local restoreButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
restoreButton:SetSize(110, 22)
restoreButton:SetPoint("BOTTOMRIGHT", -8, 4)
restoreButton:SetText("Restore defaults")

-- user defaults: the whole list of the character chosen in the drop-down
local restoreUserButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
restoreUserButton:SetSize(88, 22)
restoreUserButton:SetPoint("RIGHT", restoreButton, "LEFT", -2, 0)
restoreUserButton:SetText("Restore user")
local saveUserButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
saveUserButton:SetSize(76, 22)
saveUserButton:SetPoint("RIGHT", restoreUserButton, "LEFT", -2, 0)
saveUserButton:SetText("Save user")
local function ButtonTip(button, title, text)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
ButtonTip(saveUserButton, "Save user defaults",
	"Remembers the whole list of the character chosen above: its buffs and their order, the ticks, the click slots and the icons.")
ButtonTip(restoreUserButton, "Restore user defaults",
	"Puts back the list saved with Save user for the character chosen above.")

RefreshList = function()
	local char = selected and BuffCheckerDB.chars[selected]
	local list = char and char.list or {}
	UIDropDownMenu_SetText(charDropDown, selected and CharLabel(selected) or "(none)")
	addCharButton:SetEnabled(not BuffCheckerDB.chars[charKey])
	removeCharButton:SetEnabled(char ~= nil)
	copyCharButton:SetEnabled(char ~= nil and selected ~= charKey) -- grey on yourself
	for i, entry in ipairs(list) do
		local row = rows[i]
		if not row then
			row = CreateFrame("Frame", nil, content)
			row:SetSize(550, ROW - 2)
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)

			row.box = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			row.box:SetSize(24, 24)
			row.box:SetPoint("LEFT", 0, 0)
			row.box:SetScript("OnClick", function(self)
				local char = selected and BuffCheckerDB.chars[selected]
				if not char then
					self:SetChecked(false)
					message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
					return
				end
				char.watch[Key(row.entry)] = self:GetChecked() and true or nil
				if selected == charKey then Rebuild() end
			end)

			-- the icon and the four click slots: drop a spell (spellbook) or an item (bags) on them
			row.slot = {}
			local function MakeSlot(name)
				local s = CreateFrame("Button", nil, row)
				s:SetSize(22, 22)
				s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
				s:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
				s.bg = s:CreateTexture(nil, "BACKGROUND")
				s.bg:SetAllPoints()
				s.bg:SetColorTexture(0, 0, 0, 0.5)
				s.icon = s:CreateTexture(nil, "ARTWORK")
				s.icon:SetAllPoints()
				s.label = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				s.label:SetPoint("CENTER")
				s.label:SetText(SLOT_LABEL[name] or "")
				local function Drop()
					local action = CursorAction()
					if action == nil then return false end
					ClearCursor()
					local char = selected and BuffCheckerDB.chars[selected]
					if not char then
						message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
					elseif not action then
						message:SetText("|cffff4040Only spells from the spellbook and items from the bags go here.|r")
					else
						SetSlot(char, row.entry, name, action)
						if selected == charKey then Rebuild() end
						RefreshList()
					end
					return true
				end
				s:SetScript("OnReceiveDrag", Drop)
				s:SetScript("OnClick", function(self, button)
					if Drop() then return end
					local char = selected and BuffCheckerDB.chars[selected]
					if button == "RightButton" and char and SlotsFor(char, row.entry)[name] then
						SetSlot(char, row.entry, name, nil)
						if selected == charKey then Rebuild() end
						RefreshList()
					end
				end)
				s:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					if name == "icon" then
						GameTooltip:AddLine("Icon")
						GameTooltip:AddLine("Drop a spell or an item here to use its icon on the bar. Empty = the buff's own icon.", 1, 1, 1, true)
					else
						GameTooltip:AddLine(SLOT_TIP[name])
						GameTooltip:AddLine("Drop a spell from the spellbook or an item from your bags here. Spells are cast on yourself.", 1, 1, 1, true)
					end
					local char = selected and BuffCheckerDB.chars[selected]
					local a = row.entry and SlotsFor(char, row.entry)[name]
					if a then
						GameTooltip:AddLine("Now: " .. (ActionName(a) or "?") .. "   Right click = empty it", 0.6, 0.6, 0.6)
					end
					GameTooltip:Show()
				end)
				s:SetScript("OnLeave", function() GameTooltip:Hide() end)
				row.slot[name] = s
				return s
			end
			MakeSlot("icon"):SetPoint("LEFT", row.box, "RIGHT", 4, 0)
			for _, name in ipairs(SLOTS) do MakeSlot(name) end

			row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.remove:SetSize(70, 20)
			row.remove:SetPoint("RIGHT", 0, 0)
			row.remove:SetText("Remove")
			row.remove:SetScript("OnClick", function()
				local char = selected and BuffCheckerDB.chars[selected]
				if not char then return end
				local key = Key(row.entry)
				for n, e in ipairs(char.list) do
					if Key(e) == key then
						table.remove(char.list, n)
						break
					end
				end
				-- forget its tick, clicks and icon too, so they do not come back when it is added again
				char.watch[key] = nil
				if char.slots then char.slots[key] = nil end
				if char.always then char.always[key] = nil end
				Rebuild()
				RefreshList()
			end)

			-- arrows: swap this line with its neighbour (order in the list = order of the icons)
			local function Move(step)
				local char = selected and BuffCheckerDB.chars[selected]
				if not char then return end
				local l, from = char.list, row.index
				local to = from + step
				if to < 1 or to > #l then return end
				l[from], l[to] = l[to], l[from]
				Rebuild()
				RefreshList()
			end
			row.down = ArrowButton(row, "Down")
			row.down:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
			row.down:SetScript("OnClick", function() Move(1) end)
			row.up = ArrowButton(row, "Up")
			row.up:SetPoint("RIGHT", row.down, "LEFT", 0, 0)
			row.up:SetScript("OnClick", function() Move(-1) end)

			-- "always": the icon stays on the bar (red when the buff is missing, in colour when it is on)
			row.alwaysLabel = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.alwaysLabel:SetPoint("RIGHT", row.up, "LEFT", -6, 0)
			row.alwaysLabel:SetText("always")
			row.always = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			row.always:SetSize(24, 24)
			row.always:SetPoint("RIGHT", row.alwaysLabel, "LEFT", 0, 0)
			row.always:SetScript("OnClick", function(self)
				local char = selected and BuffCheckerDB.chars[selected]
				if not char then
					self:SetChecked(false)
					message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
					return
				end
				char.always = char.always or {}
				char.always[Key(row.entry)] = self:GetChecked() and true or false
				if selected == charKey then Rebuild() end
			end)
			row.always:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine("Always shown")
				GameTooltip:AddLine("The icon stays on the bar: red when the buff is missing, in colour when it is on.", 1, 1, 1, true)
				GameTooltip:Show()
			end)
			row.always:SetScript("OnLeave", function() GameTooltip:Hide() end)
			row.slot.SR:SetPoint("RIGHT", row.always, "LEFT", -6, 0)
			row.slot.SL:SetPoint("RIGHT", row.slot.SR, "LEFT", -2, 0)
			row.slot.R:SetPoint("RIGHT", row.slot.SL, "LEFT", -2, 0)
			row.slot.L:SetPoint("RIGHT", row.slot.R, "LEFT", -2, 0)

			row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			row.text:SetPoint("LEFT", row.slot.icon, "RIGHT", 8, 0)
			row.text:SetPoint("RIGHT", row.slot.L, "LEFT", -6, 0)
			row.text:SetJustifyH("LEFT")
			row.text:SetWordWrap(false)
			rows[i] = row
		end
		local check = Resolve(entry)
		row.entry = entry
		row.index = i
		row.up:SetEnabled(i > 1)
		row.down:SetEnabled(i < #list)
		row.box:SetChecked(char and char.watch[Key(entry)] and true or false)
		local slots = SlotsFor(char, entry)
		local fixed, base = nil, FALLBACK_ICON
		if check then fixed, base = EntryIcons(char, entry, check) end
		row.slot.icon.icon:SetTexture(fixed or base)
		for _, name in ipairs(SLOTS) do
			local a = slots[name]
			row.slot[name].icon:SetTexture(a and ActionIcon(a) or nil)
			row.slot[name].label:SetShown(not a)
		end
		row.always:SetChecked(IsAlways(char, entry))
		-- grey number after the name: spell ID (defaults: the spell its icon comes from; oil: item ID)
		local id = entry.spell or (check and (check.iconSpell or (check.iconItem and ("item " .. check.iconItem))))
		local name = check and check.name or "?"
		if entry.empty then -- named after what is in its slots
			id, name = nil, "|cff808080Empty - drop an item or a spell into L / R / S+L / S+R|r"
			for _, slotName in ipairs(SLOTS) do
				local a = slots[slotName]
				if a then name = ActionName(a) or "?" break end
			end
		end
		row.text:SetText(name .. (id and ("  |cff808080" .. id .. "|r") or ""))
		row:Show()
	end
	for i = #list + 1, #rows do rows[i]:Hide() end
	addRow:ClearAllPoints()
	addRow:SetPoint("TOPLEFT", 0, -#list * ROW - 4)
	content:SetHeight((#list + 1) * ROW + 8)
end

-- Adds a spell ID to the list (and ticks it on the chosen character). Returns true when added.
local function AddSpellID(spellID)
	if not spellID then return end
	local spellName = C_Spell.GetSpellName(spellID)
	if not spellName then
		message:SetText("|cffff4040No spell with ID " .. spellID .. "|r")
		return
	end
	local char = selected and BuffCheckerDB.chars[selected]
	if not char then
		message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
		return
	end
	local entry = { spell = spellID }
	if InList(char.list, Key(entry)) then
		message:SetText(spellName .. " is already in the list.")
		return
	end
	table.insert(char.list, entry)
	char.watch[Key(entry)] = true -- what you add, you want to watch
	message:SetText("Added: " .. spellName .. (InCombatLockdown() and " (shows after combat)" or ""))
	Rebuild()
	RefreshList()
	return true
end

-- a line with no buff, only click slots (trinkets, potions...)
addEmptyButton:SetScript("OnClick", function()
	local char = selected and BuffCheckerDB.chars[selected]
	if not char then
		message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
		return
	end
	local n = 0
	for _, e in ipairs(char.list) do n = math.max(n, e.empty or 0) end
	local entry = { empty = n + 1 }
	table.insert(char.list, entry)
	char.watch[Key(entry)] = true
	message:SetText("Added an empty line: drop an item or a spell into its click slots.")
	Rebuild()
	RefreshList()
end)

local function AddSpell()
	input:ClearFocus()
	if AddSpellID(tonumber(input:GetText())) then input:SetText("") end
end
addButton:SetScript("OnClick", AddSpell)
input:SetScript("OnEnterPressed", AddSpell)
input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

-- "Active buffs" drop-down: filled each time it is opened, from the buffs you have right now
UIDropDownMenu_Initialize(buffDropDown, function()
	if not BuffCheckerDB then return end -- the game calls this once right away, before our settings are loaded
	local seen = {}
	for i = 1, 40 do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura or IsSecret(aura) or IsSecret(aura.spellId) then break end
		if not seen[aura.spellId] then
			seen[aura.spellId] = true
			local info = UIDropDownMenu_CreateInfo()
			info.text = aura.name .. "  |cff808080" .. aura.spellId .. "|r"
			info.icon = aura.icon
			info.checked = (aura.spellId == pickedBuff)
			local char = selected and BuffCheckerDB.chars[selected]
			info.disabled = char and InList(char.list, "s:" .. aura.spellId) -- already in the list
			info.func = function()
				pickedBuff = aura.spellId
				UIDropDownMenu_SetText(buffDropDown, aura.name)
			end
			UIDropDownMenu_AddButton(info)
		end
	end
	if not next(seen) then
		local info = UIDropDownMenu_CreateInfo()
		info.text = AurasHidden() and "Not readable now (combat / boss)" or "No buffs on you"
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info)
	end
end)

addBuffButton:SetScript("OnClick", function()
	if not pickedBuff then
		message:SetText("|cffff4040First pick a buff in the drop-down on the left.|r")
		return
	end
	if AddSpellID(pickedBuff) then
		pickedBuff = nil
		UIDropDownMenu_SetText(buffDropDown, "Active buffs")
	end
end)

restoreButton:SetScript("OnClick", function()
	local char = selected and BuffCheckerDB.chars[selected]
	if not char then
		message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
		return
	end
	local added = 0
	for _, check in ipairs(DEFAULTS) do
		local entry = { preset = check.name }
		if not InList(char.list, Key(entry)) then
			table.insert(char.list, entry)
			added = added + 1
		end
	end
	message:SetText(added > 0 and ("Put back " .. added .. " default buff(s), unticked.") or "All default buffs are already in the list.")
	RefreshList()
end)

saveUserButton:SetScript("OnClick", function()
	local char = selected and BuffCheckerDB.chars[selected]
	if not char then
		message:SetText("|cffff4040First press \"Add this char\" or choose a character.|r")
		return
	end
	char.saved = { list = CopyList(char.list), watch = CopyTable1(char.watch),
	               slots = CopySlots(char.slots), always = CopyTable1(char.always) }
	message:SetText("Saved the list of " .. selected .. " (" .. #char.list .. " buffs, ticked and unticked).")
end)

restoreUserButton:SetScript("OnClick", function()
	local char = selected and BuffCheckerDB.chars[selected]
	if not (char and char.saved) then
		message:SetText("|cffff4040Nothing saved for " .. (selected or "this character") .. " yet (Save user).|r")
		return
	end
	char.list = CopyList(char.saved.list)
	char.watch = CopyTable1(char.saved.watch)
	char.slots = CopySlots(char.saved.slots)
	char.always = CopyTable1(char.saved.always)
	message:SetText("Restored the saved list of " .. selected .. ".")
	RefreshList()
	if selected == charKey then Rebuild() end
end)

UIDropDownMenu_Initialize(charDropDown, function()
	if not BuffCheckerDB then return end -- the game calls this once right away, before our settings are loaded
	local names = {}
	for name in pairs(BuffCheckerDB.chars) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = CharLabel(name, true) .. (name == charKey and "  (this one)" or "")
		info.checked = (name == selected)
		info.func = function()
			selected = name
			RefreshList()
		end
		UIDropDownMenu_AddButton(info)
	end
end)

-- replaces your own list (buffs, order, ticks, click slots, icons) with a copy of the chosen character's
local function CopyFromSelected()
	local from = selected and BuffCheckerDB.chars[selected]
	if not from or selected == charKey then return end
	BuffCheckerDB.chars[charKey] = BuffCheckerDB.chars[charKey] or { watch = {} }
	me = BuffCheckerDB.chars[charKey]
	me.details = MyDetails()
	me.list = CopyList(from.list)
	me.watch = CopyTable1(from.watch)
	me.slots = CopySlots(from.slots)
	me.always = CopyTable1(from.always)
	message:SetText("Copied the list of " .. CharLabel(selected) .. " to " .. CharLabel(charKey) .. ".")
	selected = charKey
	Rebuild()
	RefreshList()
end

StaticPopupDialogs["BUFFCHECKER_COPY_CHAR"] = {
	text = "Replace the whole list of %s with a copy of the list of %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = CopyFromSelected,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}
copyCharButton:SetScript("OnClick", function()
	StaticPopup_Show("BUFFCHECKER_COPY_CHAR", CharLabel(charKey), CharLabel(selected))
end)
ButtonTip(copyCharButton, "Copy from this char",
	"Replaces the list of the character you are on with a copy of the list of the character chosen on the left: buffs, order, ticks, click slots and icons.")

addCharButton:SetScript("OnClick", function()
	BuffCheckerDB.chars[charKey] = BuffCheckerDB.chars[charKey] or { list = DefaultList(), watch = {} }
	me = BuffCheckerDB.chars[charKey]
	me.details = MyDetails()
	selected = charKey
	message:SetText("Added " .. CharLabel(charKey) .. ". Now tick what it should watch.")
	Rebuild()
	RefreshList()
end)

removeCharButton:SetScript("OnClick", function()
	if not selected then return end
	local label = CharLabel(selected)
	BuffCheckerDB.chars[selected] = nil
	message:SetText("Removed " .. label .. " and its list.")
	if selected == charKey then
		me = nil
		Rebuild()
	end
	selected = next(BuffCheckerDB.chars) -- any remaining one, or nothing
	RefreshList()
end)

window:SetScript("OnShow", function(self)
	-- middle click closes the window; start a frame later, so the middle click
	-- that just opened it (from an icon under the window) does not close it again
	C_Timer.After(0, function()
		if self:IsShown() then self:RegisterEvent("GLOBAL_MOUSE_UP") end
	end)
	-- the icons were closed with the X: opening /bc brings them back
	if BuffCheckerDB.hidden and not InCombatLockdown() then
		BuffCheckerDB.hidden = nil
		bar:Show()
	end
	-- start on the character you are on, if it is in the list
	if BuffCheckerDB.chars[charKey] then
		selected = charKey
	elseif not (selected and BuffCheckerDB.chars[selected]) then
		selected = next(BuffCheckerDB.chars)
	end
	if portrait then SetPortraitTexture(portrait, "player") end -- the player's face, like the character window
	message:SetText(HINT)
	pickedBuff = nil
	UIDropDownMenu_SetText(buffDropDown, "Active buffs")
	showAllBox:SetChecked(showAll)
	frameBox:SetChecked(BuffCheckerDB.frame and true or false)
	sizeBox:SetText(SIZE)
	RefreshList()
end)
window:SetScript("OnHide", function(self)
	self:UnregisterEvent("GLOBAL_MOUSE_UP")
	-- "show all" is only for setting things up
	if showAll then
		showAll = false
		Update()
	end
end)

local function ApplySize()
	sizeBox:ClearFocus()
	local size = tonumber(sizeBox:GetText())
	if InCombatLockdown() then
		message:SetText("|cffff4040Not in combat.|r")
	elseif size and size >= 24 and size <= 80 then
		SIZE = size
		BuffCheckerDB.size = (size ~= DEFAULT_SIZE) and size or nil
		for _, b in ipairs(buttons) do SizeButton(b) end
		Rebuild()
		message:SetText("Icon size " .. size .. ".")
	else
		message:SetText("|cffff4040Icon size: 24 - 80 (default " .. DEFAULT_SIZE .. ").|r")
	end
	sizeBox:SetText(SIZE)
end
-- Ctrl + mouse wheel over the icons: size one step bigger / smaller
OnWheel = function(delta)
	if InCombatLockdown() then return end
	local size = math.max(24, math.min(80, SIZE + (delta > 0 and 1 or -1)))
	if size == SIZE then return end
	SIZE = size
	BuffCheckerDB.size = (size ~= DEFAULT_SIZE) and size or nil
	for _, b in ipairs(buttons) do SizeButton(b) end
	Rebuild()
	sizeBox:SetText(SIZE)
end
border:SetScript("OnMouseWheel", function(self, delta) OnWheel(delta) end)

-- the icons take the mouse wheel only while Ctrl is held, so the wheel still zooms the camera over them
local wheelWatch = CreateFrame("Frame")
wheelWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
wheelWatch:SetScript("OnEvent", function()
	if InCombatLockdown() then return end
	local on = IsControlKeyDown()
	for _, b in ipairs(buttons) do b:EnableMouseWheel(on) end
	border:EnableMouseWheel(on)
end)

sizeBox:SetScript("OnEnterPressed", ApplySize)
sizeBox:SetScript("OnEscapePressed", function(self) self:SetText(SIZE) self:ClearFocus() end)
sizeBox:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Icon size")
	GameTooltip:AddLine("24 - 80, default " .. DEFAULT_SIZE .. ". Type it and press Enter, or Ctrl + mouse wheel over the icons.", 1, 1, 1)
	GameTooltip:Show()
end)
sizeBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

SLASH_BUFFCHECKER1 = "/bc"
SLASH_BUFFCHECKER2 = "/buffchecker"
SLASH_BUFFCHECKER3 = "/cbc" -- the old command, kept so it still works
SlashCmdList["BUFFCHECKER"] = function()
	window:SetShown(not window:IsShown())
end

-- Options > AddOns: just a pointer to the window
local optionsPanel = CreateFrame("Frame")
optionsPanel.OnCommit = function() end
optionsPanel.OnDefault = function() end
optionsPanel.OnRefresh = function() end
local optionsTitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
optionsTitle:SetPoint("TOPLEFT", 16, -16)
optionsTitle:SetText("Buff Checker")
local optionsButton = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
optionsButton:SetSize(260, 24)
optionsButton:SetPoint("TOPLEFT", optionsTitle, "BOTTOMLEFT", 0, -14)
optionsButton:SetText("Open the Buff Checker window (/bc)")
optionsButton:SetScript("OnClick", function()
	if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
	window:Show()
end)

---------------------------------------------------------------------------
-- START
---------------------------------------------------------------------------
local function LoadSettings()
	BuffCheckerDB = BuffCheckerDB or {}
	local db = BuffCheckerDB
	db.chars = db.chars or {}
	db.durations = db.durations or {} -- key -> buff duration in seconds, as last seen
	db.triggers = db.triggers or {}   -- spell ID you cast -> key of the short buff it puts on
	db.icons = db.icons or {}         -- key -> icon of the buff as the game last showed it
	local name, surname = UnitName("player")
	local sep = Constants and Constants.CharacterNameSeparatorConsts and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "
	charKey = ((surname and surname ~= "") and (name .. sep .. surname) or name) .. "-" .. GetRealmName()
	-- older versions saved the character under the first name only: it moves to the full name
	-- (with two characters of the same first name, the first one to log in gets it)
	local old = name .. "-" .. GetRealmName()
	if old ~= charKey and db.chars[old] and not db.chars[charKey] then
		db.chars[charKey] = db.chars[old]
		db.chars[old] = nil
	end
	if db.chars[charKey] then db.chars[charKey].details = MyDetails() end
	SIZE = db.size or DEFAULT_SIZE

	if not db.charsByButton then
		-- one-time cleanup: older versions saved every character that logged in; keep only those with something ticked
		db.charsByButton = true
		for name, char in pairs(db.chars) do
			if not char.watch or not next(char.watch) then db.chars[name] = nil end
		end
	end
	-- renamed presets: saved lists, ticks and items follow the new name
	local RENAMED = {
		["Dampen / Amplify Magic"] = "Amplify / Dampen Magic",
		["Ice Armor / Mage Armor"] = "Mage Armor / Ice Armor",
	}
	local function RenameIn(list, ...)
		for _, entry in ipairs(list or {}) do
			if RENAMED[entry.preset] then entry.preset = RENAMED[entry.preset] end
		end
		for _, t in pairs({ ... }) do
			for old, new in pairs(RENAMED) do
				if t["p:" .. old] ~= nil then t["p:" .. new], t["p:" .. old] = t["p:" .. old], nil end
			end
		end
	end
	RenameIn(db.list, db.durations)
	for _, char in pairs(db.chars) do
		RenameIn(char.list, char.watch, char.items)
		if char.saved then RenameIn(char.saved.list, char.saved.watch, char.saved.items) end
	end
	-- older versions: one bag item per entry, used by any click -> now the left click slot
	local function ItemsToSlots(t)
		if not t or not t.items then return end
		t.slots = t.slots or {}
		for key, itemID in pairs(t.items) do
			t.slots[key] = t.slots[key] or { L = { kind = "item", id = itemID } }
		end
		t.items = nil
	end
	for _, char in pairs(db.chars) do
		ItemsToSlots(char)
		ItemsToSlots(char.saved)
	end
	me = db.chars[charKey] -- nil = this character is not in the list (yet)

	if not db.list and not db.perChar then
		-- first run of this version: defaults + whatever was added by spell ID before
		db.list = {}
		for _, check in ipairs(DEFAULTS) do
			db.list[#db.list + 1] = { preset = check.name }
		end
		local function Take(ids)
			for _, id in ipairs(ids or {}) do
				local entry = { spell = id }
				if not InList(db.list, Key(entry)) then db.list[#db.list + 1] = entry end
			end
		end
		Take(db.custom)
		for _, c in pairs(db.classes or {}) do Take(c.custom) end

		-- this character keeps watching what it watched in the old version
		db.chars[charKey] = db.chars[charKey] or { watch = {} }
		me = db.chars[charKey]
		local _, class = UnitClass("player")
		local oldClass = db.classes and db.classes[class]
		for _, check in ipairs(DEFAULTS) do
			local wasDisabled = oldClass and oldClass.disabled and oldClass.disabled[check.name]
			if (not check.class or check.class == class) and not wasDisabled then
				me.watch["p:" .. check.name] = true
			end
		end
		for _, id in ipairs(db.custom or {}) do me.watch["s:" .. id] = true end
		for _, id in ipairs(oldClass and oldClass.custom or {}) do me.watch["s:" .. id] = true end
		db.custom, db.classes = nil, nil
	end

	if not db.perChar then
		-- the list used to be shared by all characters: now every character gets its own copy
		db.perChar = true
		for _, char in pairs(db.chars) do
			char.list = CopyList(db.list)
			char.saved = nil -- old "Save user" kept only the ticks
		end
		db.list = nil
	end
end

bar:RegisterEvent("ADDON_LOADED")
bar:RegisterEvent("PLAYER_ENTERING_WORLD")
bar:RegisterEvent("PLAYER_REGEN_ENABLED")
bar:RegisterEvent("PLAYER_REGEN_DISABLED")
pcall(bar.RegisterEvent, bar, "ADDON_RESTRICTION_STATE_CHANGED") -- boss encounter starts / ends
bar:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
bar:RegisterEvent("BAG_UPDATE_DELAYED")
bar:RegisterUnitEvent("UNIT_AURA", "player")
bar:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
bar:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
bar:SetScript("OnEvent", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		LoadSettings()
		if BuffCheckerDB.hidden and not InCombatLockdown() then bar:Hide() end
		local pos = BuffCheckerDB.pos
		if pos and not InCombatLockdown() then
			bar:ClearAllPoints()
			bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
		if Settings and Settings.RegisterCanvasLayoutCategory then
			local category = Settings.RegisterCanvasLayoutCategory(optionsPanel, "Buff Checker")
			Settings.RegisterAddOnCategory(category)
		end
		Rebuild()
		return
	end
	if not charKey then return end -- our saved settings are not loaded yet
	if event == "PLAYER_REGEN_DISABLED" then
		CombatLayout()
		return
	end
	if event == "PLAYER_EQUIPMENT_CHANGED" then
		Rebuild() -- the icon of a trinket line and which slot its clicks put the trinket into (after combat if in combat)
		return
	end
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		local _, spellID = ...
		OnPlayerCast(spellID)
		return
	end
	if needRebuild then
		Rebuild()
	else
		Update()
	end
end)

-- timers run out without any event, so also look every few seconds
C_Timer.NewTicker(5, Update)
-- every quarter second: move the timers on (seconds, clock); a timer that ran out -> full update
C_Timer.NewTicker(0.25, function()
	if not charKey then return end
	if AurasHidden() then Update() return end
	for i in ipairs(checks) do
		local b = buttons[i]
		if b:IsShown() and b.expires then
			if b.expires <= GetTime() then Update() return end
			Look(b)
		end
	end
end)
