-- TODO:
-- make time-diff able to be setting - option panel
-- report to channel setting - option panel
-- set level threshold - option panel

-- VARIABLES

local ilvlreader = CreateFrame("Frame")
local addonName = "ItemLevelReader"
local addonVersion = GetAddOnMetadata(addonName, "Version")
local DEBUG_MODE = true
local unitId = "target"
local autoRead = false
local partyScore = 0
local oldPartyScore = 0
-- match pattern for finding ilvl in a tooltip string
local pattern = ITEM_LEVEL:gsub("%%d","(%%d+)")
-- table of InventorySlotNames
local gearTable = {
    "HeadSlot",
    "NeckSlot",
    "ShoulderSlot",
    "BackSlot",
    "ChestSlot",
    "WristSlot",
    "HandsSlot",
    "WaistSlot",
    "LegsSlot",
    "FeetSlot",
    "Finger0Slot",
    "Finger1Slot",
    "Trinket0Slot",
    "Trinket1Slot",
    "MainHandSlot",
    "SecondaryHandSlot"
  }

-- ONLOAD ACTIONS

-- Bind events
ilvlreader:SetScript("OnEvent", function (self, event, arg1)
  if event == "INSPECT_READY" then
    ilvlreader:InspectReady()
  elseif event == "PLAYER_TARGET_CHANGED" then
    if autoRead then
      ilvlreader:ReadTarget()
    end
  elseif event == "ADDON_LOADED" and arg1 == addonName then
    autoRead = true
    ilvlreader:InitDB()
  end
end)

-- Register event, same as Onload in xml
ilvlreader:RegisterEvent("ADDON_LOADED")
ilvlreader:RegisterEvent("PLAYER_TARGET_CHANGED")
-- welcome message
print("|cffffff00Item Level Reader version " .. addonVersion .. " loaded!|r")


-- FUNCTIONS

function ilvlreader:InitDB()
  DebugMsg("checking for db")

  -- create database table if not already around, or overwrite if out of date
  if not ItemLevelReaderDB or not (ItemLevelReaderDB.version == addonVersion) then
    DebugMsg('creating/updating db')
    ItemLevelReaderDB = {
      version = addonVersion,
      options = {
        minimumLvl = 85,
        timeDiff = 43200 -- 12hrs
      },
      playerDB = {}
    }
  end
end

function ilvlreader:ReadTarget()
  local data = ilvlreader:ReadNewUnit()
  if data then
    ilvlreader:PrintUnitData(data)
  end
end

function ilvlreader:ReadNewUnit()
  -- Check if we can inspect the target/meet minimum level we're interested in
  local inRange = CanInspect(unitId) and CheckInteractDistance(unitId, 1)
  if inRange and (UnitLevel(unitId) >= ItemLevelReaderDB.options.minimumLvl) then
    -- get name of unit to be read
    fullName = GetUnitName(unitId, true)
    -- check for entry
    local unitData = ItemLevelReaderDB["playerDB"][fullName]
    DebugMsg('can inspect')
    -- Always get fresh data if the player targets themselves or
    -- if we don't have a name or if its out of date
    local newEntry = UnitIsUnit("player", unitId) or not unitData
    if newEntry or (unitData and ((time() - unitData.time) > ItemLevelReaderDB.options.timeDiff)) then
      NotifyInspect(unitId)
      ilvlreader:RegisterEvent("INSPECT_READY")
    else
      DebugMsg('entry already exists')
      return unitData
    end
  end
end

function ilvlreader:InspectReady()
  ilvlreader:UnregisterEvent("INSPECT_READY")
  ilvlreader:SetScript("OnUpdate", nil)

  -- will be true if any links missing (not cached)
  local missing = false
  local id, link
  -- loop through gear to cache them
  for slot = 1, 16 do
    id = GetInventoryItemID(unitId, GetInventorySlotInfo(gearTable[slot]))
    link = GetInventoryItemLink(unitId, GetInventorySlotInfo(gearTable[slot]))
    -- id confirms gear in slot, link makes first request to cache item
    if id and not link then
      missing = true
    end
  end

  -- if not all links cached, run loop again
  if missing then
    ilvlreader:SetScript("OnUpdate", ilvlreader.InspectReady)
    return
  end

  -- Once all links are cached this fires
  -- get data, including name, class, and item level
  local data = ilvlreader:ReportItemLevel()
  -- print out the results if we're just reporting on target
  if unitId == "target" then
    ilvlreader:PrintUnitData(data)
  else
    oldPartyScore = partyScore
    partyScore = partyScore + data.ilvl
  end
end

function ilvlreader:ReportItemLevel()
  local ilevel = 0
  -- number of valid armor slots
  local baseSlotCount = 16

  -- loop through items and get their ilvls
  for slot = 1, 16 do
    local item = GetInventoryItemLink(unitId, GetInventorySlotInfo(gearTable[slot]))
    local val = ilvlreader:GetLevelFromLink(item)

    -- check for 2h support, skip if they're fury as they can dualwield 2h
    if slot == 15 and not (GetInspectSpecialization(unitId) == 72) then
      local itemEquipLoc = select(9, GetItemInfo(item))
      if itemEquipLoc == "INVTYPE_RANGED" or itemEquipLoc == "INVTYPE_2HWEAPON" then
        baseSlotCount = 15
      end
    end

    ilevel = ilevel + val
  end

  ilevel = math.floor(ilevel / baseSlotCount)
  -- build table from unit data
  local unitData = {
    class = UnitClass(unitId),
    ilvl = ilevel,
    time = time()
  }

  -- save the unit data
  ItemLevelReaderDB["playerDB"][fullName] = unitData
  ClearInspectPlayer()
  return unitData
end

function ilvlreader:PrintUnitData(d)
  DebugMsg('printing target data')
  local color = GetClassColor(d.class)
  print(color .. fullName .. "|r (" .. d.ilvl .. ")")
  -- cleanup
  local preGC = collectgarbage("count")
  collectgarbage()
  DebugMsg("Collected " .. (preGC - collectgarbage("count")) .. " kB of garbage")  
end

function ilvlreader:PrintPartyScore(t)
  DebugMsg('printing party data')
  print(t.numRead .. " of " .. (t.numGroupMembers +  1) .. " party members read, avg ilvl of (" .. t.ilevel .. ")")
end

-- Get the ilevel from an itemlink
function ilvlreader:GetLevelFromLink(itemLink)
  -- Create a tooltip from the itemLink passed
  if itemLink then
    if not ItemTooltip then
      CreateFrame("GameTooltip", "ItemTooltip", nil, "GameTooltipTemplate")
    end
    local tooltip = ItemTooltip
    tooltip:SetOwner(UIParent,"ANCHOR_NONE")
    tooltip:SetHyperlink(itemLink)
    -- pull out the item level text from tooltip and return it as a number
    for i = 2, 3 do
      local line = _G["ItemTooltipTextLeft" .. i]
      local ilevel = line and (line:GetText() or ""):match(pattern)
      if ilevel then
        DebugMsg(ilevel)
        return tonumber(ilevel)
      end
    end
  end
  return 0
end

-- HELPERS

-- takes a class name, ie. 'Rogue', 'Death Knight', 'Monk', returns the hexcolor value for that class
function GetClassColor(className)
  -- uppercase name and remove spaces
  className = string.upper(className)
  className = string.gsub(className, "%s+", "")
  -- Query table and extract rgb values
  local color = RAID_CLASS_COLORS[className]
  local r = (color["r"] or 0) * 255
  local g = (color["g"] or 0) * 255
  local b = (color["b"] or 0) * 255
  -- return hexcode string
  return "|cff" .. string.format("%02x%02x%02x", r, g, b)
end

function DebugMsg(output)
  if DEBUG_MODE then
    DebugMsg
    print(output)
  end
end

--- SLASH COMMANDS

SLASH_ILVLREADER1 = "/ilvl"
SlashCmdList.ILVLREADER = function(param)
  param = string.lower(param)
  local lookup = {
    party = ilvlreader.ReadParty,
    raid = ilvlreader.ReadRaid,
    on = ilvlreader.EnableAddon,
    off = ilvlreader.DisableAddon
  }
  local cmd = lookup[param]

  -- check that they're grouped before running group commands
  if (param == "party" or param == "raid") and not IsInGroup() then
    print("|cffffff00You are not in a group.|r")
  elseif cmd then
    cmd()
  else
    print("|cffffff00Item Level Reader Usage:")
    print("|cffffff00/ilvl party: get the average item level of your party")
    -- print("|cffffff00/ilvl raid: get the average item level of your raid")
    print("|cffffff00/ilvl on: enables auto reading of targets")
    print("|cffffff00/ilvl off: disables auto reading of targets")
  end
end

function ilvlreader:ReadParty()
  local numGroupMembers = GetNumGroupMembers()
  -- if we're in a raid we just want our party
  if numGroupMembers > 5 then
    numGroupMembers = 5
  end
  
  DebugMsg(numGroupMembers)
  -- tracks how many players were actually read, to account for out of range players
  local numRead = 0
  -- loop through # - 1 and inspect partyN, then inspect player and get average
  for i = 1, (numGroupMembers - 1) do
    unitId = "party" .. i
    DebugMsg(unitId)
    ilvlreader:ReadNewUnit()
    -- test old and current totals to see if player was read or not
    if not (partyScore == oldPartyScore) then
      numRead = numRead + 1
    end
  end

  -- get players ilvl and calculate avg group ilvl
  unitId = "player"
  local results = {
    numRead = numRead + 1,
    numGroupMembers = numGroupMembers,
    ilevel = (partyScore + ilvlreader:ReadNewUnit()) / numGroupMembers
  }
  -- reset values
  unitId = "target"
  partyScore = 0
  oldPartyScore = 0
  -- print results
  ilvlreader:PrintPartyScore(results)
  -- cleanup
  local preGC = collectgarbage("count")
  collectgarbage()
  DebugMsg("Collected " .. (preGC - collectgarbage("count")) .. " kB of garbage")
end

function ilvlreader:ReadRaid()
  DebugMsg("raid reader NYI")
  --[[ for raid + numberInRaid
  loop through each party in the raid
  get the party members ilvl add to a total
  average the total and return it
  ]]
end

function ilvlreader:EnableAddon()
  if not autoRead then
    print("Item Level Reader: Enabled")
    autoRead = true
  end
end

function ilvlreader:DisableAddon()
  if autoRead then
    print("Item Level Reader: Disabled")
    autoRead = false
  end
end
