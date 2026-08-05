--[[
	Aup Farm v1
	RightShift = toggle
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Networking = require(ReplicatedStorage.SharedModules.Networking)
local SeedData = require(ReplicatedStorage.SharedModules.SeedData)
local GearShopData = require(ReplicatedStorage.SharedModules.GearShopData)
local Worlds = require(ReplicatedStorage.SharedModules.Worlds)
local FruitValueCalc = require(ReplicatedStorage.SharedModules.FruitValueCalc)
local NumberUtils = require(ReplicatedStorage.SharedModules.NumberUtils)

local SeedFolder = ReplicatedStorage.SharedModules.SeedData
local FruitImages = SeedFolder.FruitImages
local PlantImages = SeedFolder.PlantImages
local SeedImages = SeedFolder.SeedImages

local C = {
	bg = Color3.fromRGB(10, 11, 16),
	card = Color3.fromRGB(15, 17, 24),
	inset = Color3.fromRGB(11, 13, 19),
	elev = Color3.fromRGB(22, 26, 36),
	line = Color3.fromRGB(42, 68, 118),
	blue = Color3.fromRGB(59, 130, 246),
	blue2 = Color3.fromRGB(96, 165, 250),
	blueDeep = Color3.fromRGB(37, 99, 235),
	blueSoft = Color3.fromRGB(28, 55, 110),
	headerA = Color3.fromRGB(90, 160, 255),
	headerB = Color3.fromRGB(35, 90, 220),
	label = Color3.fromRGB(186, 214, 255),
	text = Color3.fromRGB(248, 250, 255),
	muted = Color3.fromRGB(148, 163, 184),
	dim = Color3.fromRGB(100, 116, 139),
	gold = Color3.fromRGB(234, 179, 8),
	red = Color3.fromRGB(239, 68, 68),
	footA = Color3.fromRGB(50, 130, 255),
	footB = Color3.fromRGB(180, 70, 255),
}

local R = 10 -- Mail Bypass soft radius
local UI_NAME = "AupFarmUI"
local CONFIG_FILE = "AupFarm/config.json"
local PLANT_SPACING = 1.2
-- Game hard-cap: 100 plants per BedSection / FRONT_BedSection (verified: exp3 = 8 beds → 800)
local PLANTS_PER_BED = 100

-- Kill previous inject's farm loop (re-execute used to leave harvest running)
local SESSION = (tonumber(_G.AupFarmSession) or 0) + 1
_G.AupFarmSession = SESSION
if typeof(_G.AupFarmStop) == "function" then
	pcall(_G.AupFarmStop)
end

local State = {
	running = false,
	autoPlant = true,
	autoHarvest = true,
	autoSell = true,
	dailyDeal = true,
	autoBuySeeds = false,
	autoBuyGears = false,
	fpsBoost = false,
	selectedPlant = nil,
	buySeeds = {},
	buyGears = {},
	status = "Idle",
	planted = 0,
	harvested = 0,
	sold = 0,
	bought = 0,
	sessionStart = os.clock(),
}

local cd = { plant = 0, sell = 0, buy = 0, harv = 0, paintWorth = 0 }
local plantPaused = false -- true when garden full; cleared when harvest frees space
local worthCache = "0"
local areaCache = { plot = nil, list = nil }
local occCache = { plot = nil, t = -1, list = {}, buckets = nil }
local UI = {}

------------------------------------------------------------------------
-- Data helpers
------------------------------------------------------------------------
local function worldId()
	return Worlds.CurrentId or (Worlds.Current and Worlds.Current.Id) or "Main"
end

local function worldName()
	local w = Worlds.Worlds and Worlds.Worlds[worldId()]
	return (w and w.DisplayName) or worldId()
end

local function seedInWorld(data, wid)
	if type(data.Worlds) ~= "table" then
		return true
	end
	for _, w in pairs(data.Worlds) do
		if w == wid then
			return true
		end
	end
	return false
end

local function isSyrup(n)
	return type(n) == "string" and string.find(n, "Syrup", 1, true) ~= nil
end

local function gearFits(n, wid)
	local syrup = isSyrup(n)
	if wid == "FallHarvest" then
		return syrup or (not string.find(n, "Sprinkler", 1, true) and not string.find(n, "Watering", 1, true))
	end
	return not syrup
end

local function itemImage(name)
	-- prefer fruit/plant art (cleaner than seed packets)
	local function val(folder)
		if not folder then
			return nil
		end
		local v = folder:FindFirstChild(name)
		if v and v:IsA("StringValue") and v.Value ~= "" then
			return v.Value
		end
		-- maple → base
		local base = string.gsub(name, "^Maple ", "")
		if base ~= name then
			v = folder:FindFirstChild(base)
			if v and v:IsA("StringValue") and v.Value ~= "" then
				return v.Value
			end
		end
		return nil
	end
	return val(FruitImages) or val(PlantImages) or val(SeedImages) or ""
end

local function worldSeeds(shopOnly)
	local wid, list = worldId(), {}
	for _, d in ipairs(SeedData) do
		if d.SeedName and seedInWorld(d, wid) and d.SeedName ~= "Gold" and d.SeedName ~= "Rainbow" and d.SeedName ~= "Mega" then
			if not shopOnly or d.RestockShop then
				table.insert(list, {
					name = d.SeedName,
					price = d.PurchasePrice or 0,
					image = itemImage(d.SeedName),
					prime = d.PrimeTime or 0,
				})
			end
		end
	end
	table.sort(list, function(a, b)
		return a.price < b.price
	end)
	return list
end

local function worldGears()
	local wid, list = worldId(), {}
	for _, d in ipairs(GearShopData.Data) do
		if d.HideFromShop or not d.ItemName then
			continue
		end
		local ok = true
		if type(d.Worlds) == "table" then
			ok = seedInWorld(d, wid)
		else
			ok = gearFits(d.ItemName, wid)
		end
		if ok then
			table.insert(list, {
				name = d.ItemName,
				image = d.IMG or "",
				cost = tonumber(d.Cost) or 0,
			})
		end
	end
	table.sort(list, function(a, b)
		return (a.cost or 0) < (b.cost or 0)
	end)
	return list
end

local function ensureGear()
end

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------
local function saveConfig()
	return pcall(function()
		if typeof(makefolder) == "function" and not isfolder("AupFarm") then
			makefolder("AupFarm")
		end
		writefile(CONFIG_FILE, HttpService:JSONEncode({
			autoPlant = State.autoPlant,
			autoHarvest = State.autoHarvest,
			autoSell = State.autoSell,
			dailyDeal = State.dailyDeal,
			autoBuySeeds = State.autoBuySeeds,
			autoBuyGears = State.autoBuyGears,
			fpsBoost = State.fpsBoost,
			selectedPlant = State.selectedPlant,
			buySeeds = State.buySeeds,
			buyGears = State.buyGears,
		}))
	end)
end

local function loadConfig()
	local ok, raw = pcall(function()
		if isfile(CONFIG_FILE) then
			return readfile(CONFIG_FILE)
		end
		if isfile("GroveFarm/config.json") then
			return readfile("GroveFarm/config.json")
		end
		return nil
	end)
	if not (ok and raw and raw ~= "") then
		return false
	end
	local dOk, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not dOk or type(data) ~= "table" then
		return false
	end
	for _, k in ipairs({
		"autoPlant", "autoHarvest", "autoSell", "dailyDeal",
		"autoBuySeeds", "autoBuyGears", "fpsBoost", "selectedPlant",
	}) do
		if data[k] ~= nil then
			State[k] = data[k]
		end
	end
	if type(data.buySeeds) == "table" then
		State.buySeeds = data.buySeeds
	end
	if type(data.buyGears) == "table" then
		State.buyGears = data.buyGears
	end
	return true
end

------------------------------------------------------------------------
-- FPS boost (local only — strips other gardens + lowers render quality)
------------------------------------------------------------------------
local fpsConns = {}
local fpsLighting = {}

local function isMyPlot(plot)
	if not plot then
		return false
	end
	local uid = plot:GetAttribute("OwnerUserId") or plot:GetAttribute("UserId") or plot:GetAttribute("Owner")
	if uid == LocalPlayer.UserId or tostring(uid) == tostring(LocalPlayer.UserId) then
		return true
	end
	if uid == LocalPlayer.Name then
		return true
	end
	local myId = LocalPlayer:GetAttribute("PlotId")
	if myId and plot.Name == ("Plot" .. tostring(myId)) then
		return true
	end
	return false
end

local function stripOtherPlots()
	local gardens = workspace:FindFirstChild("Gardens")
	if not gardens then
		return
	end
	for _, plot in ipairs(gardens:GetChildren()) do
		if not isMyPlot(plot) then
			pcall(function()
				plot:Destroy()
			end)
		end
	end
end

local function clearFpsConns()
	for _, c in ipairs(fpsConns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	fpsConns = {}
end

local function applyFpsBoost(on)
	State.fpsBoost = on == true
	clearFpsConns()
	if not State.fpsBoost then
		if fpsLighting.GlobalShadows ~= nil then
			Lighting.GlobalShadows = fpsLighting.GlobalShadows
		end
		if fpsLighting.FogEnd ~= nil then
			Lighting.FogEnd = fpsLighting.FogEnd
		end
		if fpsLighting.Brightness ~= nil then
			Lighting.Brightness = fpsLighting.Brightness
		end
		pcall(function()
			settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
		end)
		State.status = "FPS boost off (rejoin to restore plots)"
		if UI.paint then
			UI.paint()
		end
		return
	end

	fpsLighting.GlobalShadows = Lighting.GlobalShadows
	fpsLighting.FogEnd = Lighting.FogEnd
	fpsLighting.Brightness = Lighting.Brightness

	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)
	Lighting.GlobalShadows = false
	Lighting.FogEnd = 9e9
	pcall(function()
		Lighting.Technology = Enum.Technology.Legacy
	end)

	stripOtherPlots()
	local gardens = workspace:FindFirstChild("Gardens")
	if gardens then
		table.insert(fpsConns, gardens.ChildAdded:Connect(function(plot)
			if State.fpsBoost and not isMyPlot(plot) then
				task.defer(function()
					pcall(function()
						plot:Destroy()
					end)
				end)
			end
		end))
	end
	task.spawn(function()
		while State.fpsBoost do
			stripOtherPlots()
			task.wait(2)
		end
	end)

	State.status = "FPS boost on"
	if UI.paint then
		UI.paint()
	end
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------
local function getPlot()
	local id = LocalPlayer:GetAttribute("PlotId")
	if id then
		local p = workspace.Gardens:FindFirstChild("Plot" .. tostring(id))
		if p then
			return p, tonumber(id)
		end
	end
	for _, p in ipairs(workspace.Gardens:GetChildren()) do
		if p:GetAttribute("OwnerUserId") == LocalPlayer.UserId or p:GetAttribute("Owner") == LocalPlayer.Name then
			return p, tonumber(string.match(p.Name, "%d+"))
		end
	end
end

local function inv()
	local n = LocalPlayer:GetAttribute("FruitCount") or 0
	local m = LocalPlayer:GetAttribute("MaxFruitCapacity") or 100
	return n >= m, n, m
end

local function invWorth()
	local total, count = 0, 0
	local function add(inst)
		if not inst then
			return
		end
		-- backpack stores most fruits as Configuration, hotbar ones as Tool
		local name = inst:GetAttribute("FruitName")
		if not name then
			return
		end
		local ok, val = pcall(
			FruitValueCalc,
			name,
			inst:GetAttribute("SizeMultiplier"),
			inst:GetAttribute("Mutation"),
			LocalPlayer,
			inst:GetAttribute("DecayAlpha")
		)
		if ok and typeof(val) == "number" then
			total += val
			count += 1
		end
	end
	local function scan(parent)
		if not parent then
			return
		end
		for _, c in ipairs(parent:GetChildren()) do
			add(c)
		end
	end
	scan(LocalPlayer:FindFirstChild("Backpack"))
	scan(LocalPlayer.Character)
	local abbr = total
	if NumberUtils and NumberUtils.Abbreviate then
		local ok, a = pcall(NumberUtils.Abbreviate, total)
		if ok then
			abbr = a
		end
	elseif total >= 1e6 then
		abbr = string.format("%.2fM", total / 1e6)
	elseif total >= 1000 then
		abbr = string.format("%.2fK", total / 1000)
	else
		abbr = tostring(math.floor(total + 0.5))
	end
	return total, abbr, count
end

local function findTool(a, v)
	local function scan(c)
		if not c then
			return
		end
		for _, t in ipairs(c:GetChildren()) do
			if t:IsA("Tool") and t:GetAttribute(a) == v then
				return t
			end
		end
	end
	return scan(LocalPlayer.Character) or scan(LocalPlayer.Backpack)
end

local function equip(tool)
	if not tool then
		return false
	end
	local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	if tool.Parent == LocalPlayer.Character then
		return true
	end
	hum:EquipTool(tool)
	return true
end

local function setStatus(s)
	State.status = s
	-- light pill update only — full paint (esp. inv worth) is too heavy to run every action
	if UI.pill then
		local _, n, m = inv()
		UI.pill.Text = string.format("%s  ·  %d/%d", s, n, m)
	end
end

local function paintStats()
	if not UI.paint then
		return
	end
	UI.paint()
end

local function gardenCount(plot)
	plot = plot or select(1, getPlot())
	if not plot then
		return 0
	end
	local f = plot:FindFirstChild("Plants")
	return f and #f:GetChildren() or 0
end

-- Active garden beds from Visual (same models GardenVisualController places from GardenExpansion)
local function bedCount(plot)
	plot = plot or select(1, getPlot())
	if not plot then
		return 0
	end
	local visual = plot:FindFirstChild("Visual")
	if not visual then
		return 0
	end
	local n = 0
	for _, c in ipairs(visual:GetChildren()) do
		if c.Name == "BedSection" or c.Name == "FRONT_BedSection" then
			n += 1
		end
	end
	return n
end

local function maxPlants(plot)
	local beds = bedCount(plot)
	if beds <= 0 then
		return 0
	end
	return beds * PLANTS_PER_BED
end

local function gardenAtMax(plot)
	local max = maxPlants(plot)
	if max <= 0 then
		return false
	end
	return gardenCount(plot) >= max
end

local spotCursor = { plot = nil, ai = 1, x = nil, z = nil }

local function invalidateOcc()
	occCache.t = -1
	occCache.buckets = nil
	spotCursor.plot = nil
end

local function plantPos(plot)
	if occCache.plot == plot and (os.clock() - occCache.t) < 0.8 and occCache.buckets then
		return occCache.list, occCache.buckets
	end
	local t, buckets, f = {}, {}, plot:FindFirstChild("Plants")
	if f then
		for _, p in ipairs(f:GetChildren()) do
			local pos
			local pp = p.PrimaryPart
			if not pp then
				for _, c in ipairs(p:GetChildren()) do
					if c:IsA("BasePart") then
						pp = c
						break
					end
				end
			end
			if pp then
				pos = pp.Position
			else
				local ok, piv = pcall(function()
					return p:GetPivot().Position
				end)
				if ok then
					pos = piv
				end
			end
			if pos then
				table.insert(t, pos)
				local bx = math.floor(pos.X / 1.05)
				local bz = math.floor(pos.Z / 1.05)
				local key = bx .. "," .. bz
				local bucket = buckets[key]
				if not bucket then
					bucket = {}
					buckets[key] = bucket
				end
				table.insert(bucket, pos)
			end
		end
	end
	occCache.plot = plot
	occCache.t = os.clock()
	occCache.list = t
	occCache.buckets = buckets
	return t, buckets
end

local function markOcc(pos)
	if not occCache.buckets then
		return
	end
	table.insert(occCache.list, pos)
	local bx = math.floor(pos.X / 1.05)
	local bz = math.floor(pos.Z / 1.05)
	local key = bx .. "," .. bz
	local bucket = occCache.buckets[key]
	if not bucket then
		bucket = {}
		occCache.buckets[key] = bucket
	end
	table.insert(bucket, pos)
end

local function free(pos, buckets)
	local bx = math.floor(pos.X / 1.05)
	local bz = math.floor(pos.Z / 1.05)
	local a = Vector2.new(pos.X, pos.Z)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local bucket = buckets[(bx + dx) .. "," .. (bz + dz)]
			if bucket then
				for _, o in ipairs(bucket) do
					if (a - Vector2.new(o.X, o.Z)).Magnitude < 1.05 then
						return false
					end
				end
			end
		end
	end
	return true
end

local function areas(plot)
	if areaCache.plot == plot and areaCache.list then
		return areaCache.list
	end
	local t = {}
	for _, p in ipairs(CollectionService:GetTagged("PlantArea")) do
		-- only real beds (ignore invisible PlantAreaColumn* placeholders)
		if p:IsA("BasePart") and p:IsDescendantOf(plot) and p.Transparency < 1 and p.CanCollide then
			table.insert(t, p)
		end
	end
	table.sort(t, function(a, b)
		return a.Size.X * a.Size.Z > b.Size.X * b.Size.Z
	end)
	areaCache.plot = plot
	areaCache.list = t
	return t
end

local function nextSpot(plot)
	local _, buckets = plantPos(plot)
	local ar = areas(plot)
	if #ar == 0 then
		return nil
	end

	local startAi = 1
	local resumeX, resumeZ = nil, nil
	if spotCursor.plot == plot then
		startAi = spotCursor.ai or 1
		resumeX, resumeZ = spotCursor.x, spotCursor.z
	end

	for ai = startAi, #ar do
		local area = ar[ai]
		local s, cf = area.Size, area.CFrame
		local x0 = -s.X / 2 + PLANT_SPACING * 0.5
		local x1 = s.X / 2 - PLANT_SPACING * 0.4
		local z0 = -s.Z / 2 + PLANT_SPACING * 0.5
		local z1 = s.Z / 2 - PLANT_SPACING * 0.4
		local xStart = x0
		if ai == startAi and resumeX ~= nil then
			xStart = resumeX
		end
		for x = xStart, x1, PLANT_SPACING do
			local zStart = z0
			if ai == startAi and resumeX ~= nil and math.abs(x - resumeX) < 1e-6 and resumeZ ~= nil then
				zStart = resumeZ + PLANT_SPACING
			end
			for z = zStart, z1, PLANT_SPACING do
				local w = (cf * CFrame.new(x, s.Y * 0.5 + 0.05, z)).Position
				if free(w, buckets) then
					spotCursor.plot = plot
					spotCursor.ai = ai
					spotCursor.x = x
					spotCursor.z = z
					return w
				end
			end
		end
		resumeX, resumeZ = nil, nil
	end

	-- full pass from start if we resumed mid-plot and found nothing
	if startAi > 1 or resumeX ~= nil then
		spotCursor.plot = nil
		return nextSpot(plot)
	end
	spotCursor.plot = plot
	spotCursor.ai = #ar + 1
	return nil
end

local function trySell()
	if os.clock() - cd.sell < 1 then
		return false
	end
	cd.sell = os.clock()
	if (LocalPlayer:GetAttribute("FruitCount") or 0) <= 0 then
		return false
	end
	local ok, res = pcall(function()
		if State.dailyDeal then
			local d = Networking.NPCS.CheckDailyDeal:Fire()
			if d and d.Available then
				return Networking.NPCS.UseDailyDealAll:Fire()
			end
		end
		return Networking.NPCS.SellAll:Fire()
	end)
	if ok and (res == nil or res.Success ~= false) then
		State.sold += 1
		setStatus("Sold")
		return true
	end
	setStatus("Sell failed")
	return false
end

local function space()
	-- never yield here — harvest/plant loops call this often
	return not select(1, inv())
end

local function plantReady(plant)
	if plant:GetAttribute("PlantGrowthReady") == true then
		return true
	end
	local age, max = tonumber(plant:GetAttribute("Age")), tonumber(plant:GetAttribute("MaxAge"))
	if age ~= nil and max ~= nil and max > 0 and age >= max then
		return true
	end
	if plant:FindFirstChild("HarvestPrompt") then
		return true
	end
	return false
end

-- skip re-fire spam on the same plant for a short window
local harvCooldown = {}
local tickCleanup = 0
local plantsWatch = nil
local plantsWatchConn = nil

local function watchPlantsFolder(folder)
	if plantsWatch == folder and plantsWatchConn then
		return
	end
	if plantsWatchConn then
		pcall(function()
			plantsWatchConn:Disconnect()
		end)
		plantsWatchConn = nil
	end
	plantsWatch = folder
	if not folder then
		return
	end
	plantsWatchConn = folder.ChildRemoved:Connect(function()
		if not State.running then
			return
		end
		State.harvested += 1
		plantPaused = false
		invalidateOcc()
	end)
end

local function tryHarvest()
	if not State.autoHarvest then
		return 0
	end
	if os.clock() - cd.harv < 0.03 then
		return 0
	end
	if not space() then
		if State.autoSell then
			trySell()
		end
		if not space() then
			setStatus("Inventory full")
			return 0
		end
	end
	local plot = getPlot()
	if not plot then
		return 0
	end
	local folder = plot:FindFirstChild("Plants")
	if not folder then
		return 0
	end
	watchPlantsFolder(folder)

	local maxCap = LocalPlayer:GetAttribute("MaxFruitCapacity") or 100
	local fired = 0
	local now = os.clock()
	cd.harv = now

	for _, plant in ipairs(folder:GetChildren()) do
		if not State.running or not State.autoHarvest then
			break
		end
		if (LocalPlayer:GetAttribute("FruitCount") or 0) >= maxCap then
			break
		end
		local pid = plant:GetAttribute("PlantId")
		if not pid then
			continue
		end
		local key = tostring(pid)
		if harvCooldown[key] and now - harvCooldown[key] < 0.35 then
			continue
		end

		local fruits = plant:FindFirstChild("Fruits")
		if not fruits then
			if not plantReady(plant) then
				continue
			end
			if pcall(function()
				Networking.Garden.CollectFruit:Fire(key, "")
			end) then
				harvCooldown[key] = now
				fired += 1
			end
			if fired >= 25 then
				break
			end
			continue
		end

		for _, fruit in ipairs(fruits:GetChildren()) do
			if not State.running then
				break
			end
			if (LocalPlayer:GetAttribute("FruitCount") or 0) >= maxCap then
				break
			end
			local harvestable = fruit:HasTag("Harvestable") or fruit:FindFirstChild("HarvestPrompt") ~= nil
			if not harvestable then
				continue
			end
			local fid = fruit:GetAttribute("FruitId")
			if fid == nil then
				continue
			end
			local fkey = key .. ":" .. tostring(fid)
			if harvCooldown[fkey] and now - harvCooldown[fkey] < 0.35 then
				continue
			end
			if pcall(function()
				Networking.Garden.CollectFruit:Fire(key, tostring(fid))
			end) then
				harvCooldown[fkey] = now
				fired += 1
			end
			if fired >= 25 then
				break
			end
		end
		if fired >= 25 then
			break
		end
	end

	if fired > 0 then
		setStatus("Harvesting")
	end

	tickCleanup += 1
	if tickCleanup % 40 == 0 then
		local cut = now - 3
		for k, t in pairs(harvCooldown) do
			if t < cut then
				harvCooldown[k] = nil
			end
		end
	end
	return fired
end

local function tryPlant()
	if not State.autoPlant or not State.selectedPlant then
		return
	end
	if plantPaused then
		return
	end
	if os.clock() - cd.plant < 0.04 then
		return
	end
	local plot = getPlot()
	if not plot then
		return
	end
	local max = maxPlants(plot)
	local count = gardenCount(plot)
	if max > 0 and count >= max then
		plantPaused = true
		setStatus("Garden full · harvesting")
		return
	end
	local tool = findTool("SeedTool", State.selectedPlant)
	if not tool then
		setStatus("No seeds")
		return
	end
	if not equip(tool) then
		return
	end

	local plantedNow = 0
	for _ = 1, 12 do
		if not State.running or plantPaused then
			break
		end
		if max > 0 and count >= max then
			plantPaused = true
			setStatus("Garden full · harvesting")
			break
		end
		tool = findTool("SeedTool", State.selectedPlant)
		if not tool then
			setStatus("No seeds")
			break
		end
		local spot = nextSpot(plot)
		if not spot then
			plantPaused = true
			setStatus("Garden full · harvesting")
			break
		end
		cd.plant = os.clock()
		if pcall(function()
			Networking.Plant.PlantSeed:Fire(spot, State.selectedPlant, tool)
		end) then
			plantedNow += 1
			count += 1
			if occCache.plot == plot then
				markOcc(spot)
			else
				invalidateOcc()
			end
		else
			break
		end
	end
	if plantedNow > 0 then
		setStatus("Planted x" .. plantedNow)
	end
end

local buySkip = {} -- [itemName] = os.clock() until when we shouldn't retry (broke / fail)

local function wallet()
	local name = Worlds.WalletStatName and Worlds.WalletStatName(LocalPlayer) or "Sheckles"
	local ls = LocalPlayer:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return (v and tonumber(v.Value)) or 0, name
end

local function seedPrice(name)
	for _, d in ipairs(SeedData) do
		if d.SeedName == name then
			return tonumber(d.PurchasePrice) or tonumber(d.Price) or tonumber(d.Cost) or 0
		end
	end
	return 0
end

local function gearPrice(name)
	local list = GearShopData.Data or GearShopData
	if typeof(list) ~= "table" then
		return 0
	end
	for _, d in ipairs(list) do
		local n = d.ItemName or d.GearName or d.Name
		if n == name then
			return tonumber(d.Cost) or tonumber(d.PurchasePrice) or tonumber(d.Price) or 0
		end
	end
	return 0
end

local function stock(shop, name)
	local root = ReplicatedStorage:FindFirstChild("StockValues")
	local items = root and root:FindFirstChild(shop) and root[shop]:FindFirstChild("Items")
	local v = items and items:FindFirstChild(name)
	return (v and v:IsA("NumberValue") and v.Value) or 0
end

local function tryBuy()
	if not (State.autoBuySeeds or State.autoBuyGears) then
		return
	end
	if os.clock() - cd.buy < 2.0 then
		return
	end

	local money = wallet()
	local boughtSomething = false

	local function attempt(shop, name, price, fire)
		if buySkip[name] and os.clock() < buySkip[name] then
			return false
		end
		local qty = stock(shop, name)
		if qty < 1 then
			return false -- not in stock; quiet skip, no remote spam
		end
		price = tonumber(price) or 0
		if price > 0 and money < price then
			buySkip[name] = os.clock() + 8 -- broke: don't spam this item
			setStatus("Can't afford " .. name)
			return false
		end
		cd.buy = os.clock()
		local before = money
		local ok = pcall(fire)
		if not ok then
			buySkip[name] = os.clock() + 5
			return false
		end
		-- don't task.wait here — it freezes the whole farm loop
		money = wallet()
		local qtyAfter = stock(shop, name)
		if price > 0 and money >= before and qtyAfter >= qty then
			-- money/stock may lag a frame; soft backoff, not hard fail
			buySkip[name] = os.clock() + 1.5
			State.bought += 1
			boughtSomething = true
			setStatus("Bought " .. name)
			return true
		end
		State.bought += 1
		buySkip[name] = nil
		setStatus("Bought " .. name)
		boughtSomething = true
		return true
	end

	if State.autoBuySeeds then
		for name in pairs(State.buySeeds) do
			if attempt("SeedShop", name, seedPrice(name), function()
				Networking.SeedShop.PurchaseSeed:Fire(name)
			end) then
				return
			end
		end
	end
	if State.autoBuyGears then
		for name in pairs(State.buyGears) do
			if attempt("GearShop", name, gearPrice(name), function()
				Networking.GearShop.PurchaseGear:Fire(name)
			end) then
				return
			end
		end
	end

	-- nothing buyable right now — sleep longer so the farm loop isn't buy-spamming
	if not boughtSomething then
		cd.buy = os.clock() + 4
	end
end

local function loop()
	local tick = 0
	local mySession = SESSION
	while State.running and _G.AupFarmSession == mySession do
		pcall(function()
			tick += 1

			if State.autoSell and (LocalPlayer:GetAttribute("FruitCount") or 0) > 0 then
				trySell()
			end

			if tick % 10 == 0 then
				tryBuy()
			end

			-- harvest ready every tick; plant whenever there is space
			tryHarvest()
			local plot = getPlot()
			if plot and gardenAtMax(plot) then
				plantPaused = true
			else
				plantPaused = false
				tryPlant()
			end

			if tick % 10 == 0 then
				paintStats()
			end
		end)
		task.wait(0.03)
	end
	if _G.AupFarmSession == mySession then
		State.running = false
		setStatus("Idle")
		paintStats()
	end
end

local function startFarm()
	if State.running then
		return
	end
	State.autoPlant = true
	State.autoHarvest = true
	State.autoSell = true
	State.harvested = 0
	plantPaused = false
	table.clear(harvCooldown)
	invalidateOcc()
	areaCache.plot = nil
	areaCache.list = nil
	State.running = true
	local plot = getPlot()
	if plot then
		watchPlantsFolder(plot:FindFirstChild("Plants"))
	end
	setStatus("Running")
	task.spawn(loop)
	task.defer(function()
		if paints then
			for _, p in ipairs(paints) do
				pcall(p)
			end
		end
	end)
end

local function stopFarm()
	State.running = false
	setStatus("Idle")
end

_G.AupFarmStop = stopFarm

------------------------------------------------------------------------
-- UI kit
------------------------------------------------------------------------
local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or R)
	c.Parent = p
	return c
end

local function stroke(p, col, thick)
	local s = Instance.new("UIStroke")
	s.Color = col or C.line
	s.Thickness = thick or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = p
	return s
end

local function grad(p, a, b, rot)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, a),
		ColorSequenceKeypoint.new(1, b),
	})
	g.Rotation = rot or 0
	g.Parent = p
	return g
end

local function pad(p, n)
	local u = Instance.new("UIPadding")
	u.PaddingTop = UDim.new(0, n)
	u.PaddingBottom = UDim.new(0, n)
	u.PaddingLeft = UDim.new(0, n)
	u.PaddingRight = UDim.new(0, n)
	u.Parent = p
	return u
end

local function padXY(p, x, y)
	local u = Instance.new("UIPadding")
	u.PaddingTop = UDim.new(0, y)
	u.PaddingBottom = UDim.new(0, y)
	u.PaddingLeft = UDim.new(0, x)
	u.PaddingRight = UDim.new(0, x)
	u.Parent = p
	return u
end

local function vlist(p, g)
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, g or 8)
	l.Parent = p
	return l
end

local function hlist(p, g)
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, g or 8)
	l.Parent = p
	return l
end

local function label(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = props.font or Enum.Font.GothamMedium
	l.Text = props.text or ""
	l.TextColor3 = props.color or C.text
	l.TextSize = props.size or 13
	l.TextXAlignment = props.ax or Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Size = props.sz or UDim2.new(1, 0, 0, props.h or 18)
	l.LayoutOrder = props.order or 0
	l.Parent = parent
	return l
end

local function card(parent, order)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = C.card
	f.BorderSizePixel = 0
	f.Size = UDim2.new(1, 0, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = order or 0
	f.Parent = parent
	corner(f, R)
	stroke(f, C.line)
	pad(f, 12)
	vlist(f, 8)
	return f
end

-- Stroke lives on a wrapper; scroll content sits inside so borders aren't clipped
local function hScroll(parent, height, order)
	local wrap = Instance.new("Frame")
	wrap.BackgroundColor3 = C.inset
	wrap.BorderSizePixel = 0
	wrap.Size = UDim2.new(1, 0, 0, height)
	wrap.LayoutOrder = order or 0
	wrap.Parent = parent
	corner(wrap, R)
	stroke(wrap, C.line)

	-- separate clip layer so UIStroke on wrap isn't eaten by ClipsDescendants
	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.Size = UDim2.new(1, -2, 1, -2)
	clip.Position = UDim2.fromOffset(1, 1)
	clip.ClipsDescendants = true
	clip.Parent = wrap
	corner(clip, math.max(0, R - 1))

	local sc = Instance.new("ScrollingFrame")
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.Size = UDim2.fromScale(1, 1)
	sc.ScrollBarThickness = 3
	sc.ScrollBarImageColor3 = C.blue
	sc.ScrollingDirection = Enum.ScrollingDirection.X
	sc.AutomaticCanvasSize = Enum.AutomaticSize.X
	sc.CanvasSize = UDim2.new()
	sc.ElasticBehavior = Enum.ElasticBehavior.Never
	sc.ScrollingEnabled = true
	sc.Parent = clip
	padXY(sc, 8, 6)
	hlist(sc, 8)

	-- mouse wheel → horizontal only (locks parent page so it doesn't scroll up/down)
	local hovering = false
	local lockedPage = nil
	local function findParentPage(from)
		local p = from.Parent
		while p do
			if p:IsA("ScrollingFrame") and p ~= sc then
				return p
			end
			p = p.Parent
		end
		return nil
	end
	local function setHover(on)
		hovering = on
		if on then
			lockedPage = findParentPage(wrap)
			if lockedPage then
				lockedPage.ScrollingEnabled = false
			end
		else
			if lockedPage then
				lockedPage.ScrollingEnabled = true
				lockedPage = nil
			end
		end
	end
	wrap.MouseEnter:Connect(function()
		setHover(true)
	end)
	wrap.MouseLeave:Connect(function()
		setHover(false)
	end)
	sc.MouseEnter:Connect(function()
		setHover(true)
	end)
	sc.MouseLeave:Connect(function()
		setHover(false)
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not hovering or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		local step = 48
		local maxX = math.max(0, sc.AbsoluteCanvasSize.X - sc.AbsoluteWindowSize.X)
		local nextX = math.clamp(sc.CanvasPosition.X - input.Position.Z * step, 0, maxX)
		sc.CanvasPosition = Vector2.new(nextX, sc.CanvasPosition.Y)
		-- keep parent page locked while wheel is used here
		if lockedPage then
			lockedPage.ScrollingEnabled = false
		end
	end)

	return sc
end

local function vScroll(parent, height, order)
	local wrap = Instance.new("Frame")
	wrap.BackgroundColor3 = C.inset
	wrap.BorderSizePixel = 0
	wrap.Size = UDim2.new(1, 0, 0, height)
	wrap.LayoutOrder = order or 0
	wrap.Parent = parent
	corner(wrap, R)
	stroke(wrap, C.line)

	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.Size = UDim2.new(1, -2, 1, -2)
	clip.Position = UDim2.fromOffset(1, 1)
	clip.ClipsDescendants = true
	clip.Parent = wrap
	corner(clip, math.max(0, R - 1))

	local sc = Instance.new("ScrollingFrame")
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.Size = UDim2.fromScale(1, 1)
	sc.ScrollBarThickness = 3
	sc.ScrollBarImageColor3 = C.blue
	sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sc.CanvasSize = UDim2.new()
	sc.ElasticBehavior = Enum.ElasticBehavior.Never
	sc.Parent = clip
	pad(sc, 8)
	return sc
end

local function sect(parent, text, order)
	return label(parent, {
		text = string.upper(text),
		size = 11,
		color = C.label,
		font = Enum.Font.GothamBold,
		h = 14,
		order = order,
	})
end

local function button(parent, props)
	-- Gradient must sit on a bg frame — UIGradient on TextButton tints the text away
	local wrap = Instance.new("Frame")
	wrap.BackgroundTransparency = 1
	wrap.BorderSizePixel = 0
	wrap.Size = props.sz or UDim2.new(1, 0, 0, 40)
	wrap.LayoutOrder = props.order or 0
	wrap.Parent = parent

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BorderSizePixel = 0
	bg.Parent = wrap
	corner(bg, R)
	if props.gradient then
		bg.BackgroundColor3 = Color3.new(1, 1, 1)
		grad(bg, props.gradient[1], props.gradient[2], 90)
	else
		bg.BackgroundColor3 = props.bg or C.blue
	end
	if props.sc then
		stroke(bg, props.sc)
	end

	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Text = props.text or ""
	b.Font = Enum.Font.GothamBold
	b.TextSize = props.ts or 14
	b.TextColor3 = props.color or C.text
	b.Size = UDim2.fromScale(1, 1)
	b.ZIndex = 2
	b.Parent = wrap
	return b
end

local function check(parent, title, get, set, order)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 26)
	row.LayoutOrder = order or 0
	row.Parent = parent

	local box = Instance.new("TextButton")
	box.AutoButtonColor = false
	box.Size = UDim2.fromOffset(20, 20)
	box.Position = UDim2.new(0, 0, 0.5, -10)
	box.BackgroundColor3 = C.inset
	box.Text = ""
	box.Parent = row
	corner(box, 6)
	local st = stroke(box, C.blueSoft)
	local mark = label(box, { text = "", size = 13, ax = Enum.TextXAlignment.Center, sz = UDim2.new(1, 0, 1, 0) })

	label(row, {
		text = title,
		size = 13,
		sz = UDim2.new(1, -30, 1, 0),
	}).Position = UDim2.new(0, 30, 0, 0)

	local function paint()
		local on = get()
		box.BackgroundColor3 = on and C.blue or C.inset
		st.Color = on and C.blue2 or C.blueSoft
		mark.Text = on and "✓" or ""
	end
	paint()
	box.MouseButton1Click:Connect(function()
		set(not get())
		paint()
		pcall(saveConfig)
		if UI.paint then
			UI.paint()
		end
	end)
	return paint
end

local function clear(frame)
	for _, c in ipairs(frame:GetChildren()) do
		if not (c:IsA("UIListLayout") or c:IsA("UIGridLayout") or c:IsA("UIPadding") or c:IsA("UICorner") or c:IsA("UIStroke")) then
			c:Destroy()
		end
	end
end

local function tile(parent, image, text, on, w, h)
	w, h = w or 76, h or 88
	-- border is an inset frame (not UIStroke) so scroll clippers don't chop it
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.fromOffset(w, h)
	b.BackgroundTransparency = 1
	b.Text = ""
	b.Parent = parent

	local border = Instance.new("Frame")
	border.Name = "Border"
	border.Size = UDim2.fromScale(1, 1)
	border.BackgroundColor3 = on and C.blue or C.line
	border.BorderSizePixel = 0
	border.Parent = b
	corner(border, 8)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, -2, 1, -2)
	face.Position = UDim2.fromOffset(1, 1)
	face.BackgroundColor3 = on and C.blueSoft or C.elev
	face.BorderSizePixel = 0
	face.ClipsDescendants = true
	face.Parent = b
	corner(face, 7)

	local holder = Instance.new("Frame")
	holder.BackgroundColor3 = C.inset
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromOffset(w - 14, w - 14)
	holder.Position = UDim2.new(0.5, -(w - 14) / 2, 0, 5)
	holder.ClipsDescendants = true
	holder.Parent = face
	corner(holder, 6)

	local ic = Instance.new("ImageLabel")
	ic.BackgroundTransparency = 1
	ic.Size = UDim2.new(1, -4, 1, -4)
	ic.Position = UDim2.new(0, 2, 0, 2)
	ic.Image = image or ""
	ic.ScaleType = Enum.ScaleType.Fit
	ic.ResampleMode = Enum.ResamplerMode.Default
	ic.Parent = holder

	local name = label(face, {
		text = text,
		size = 10,
		color = on and C.label or C.muted,
		ax = Enum.TextXAlignment.Center,
		sz = UDim2.new(1, -6, 0, 18),
	})
	name.Position = UDim2.new(0, 3, 1, -20)
	name.TextWrapped = true
	return b
end

------------------------------------------------------------------------
-- Build UI
------------------------------------------------------------------------
loadConfig()
ensureGear()

local old = PlayerGui:FindFirstChild(UI_NAME) or PlayerGui:FindFirstChild("GroveFarmUI")
if old then
	old:Destroy()
end
-- ensure no leftover farm from a previous execute is still ticking
pcall(function()
	if typeof(_G.AupFarmStop) == "function" then
		_G.AupFarmStop()
	end
end)

local gui = Instance.new("ScreenGui")
gui.Name = UI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = PlayerGui

local shell = Instance.new("Frame")
shell.Name = "Window"
shell.Size = UDim2.fromOffset(780, 540)
shell.Position = UDim2.new(0.5, -390, 0.5, -270)
shell.BackgroundTransparency = 1
shell.Parent = gui
corner(shell, 12)
stroke(shell, Color3.fromRGB(55, 100, 180), 1.5)

-- CanvasGroup clips gradients to rounded corners (Frame + UIGradient does not)
local win = Instance.new("CanvasGroup")
win.Name = "Panel"
win.Size = UDim2.fromScale(1, 1)
win.BackgroundColor3 = C.bg
win.BorderSizePixel = 0
win.Parent = shell
corner(win, 12)

-- Header (Mail Bypass bright blue gradient)
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 62)
header.BackgroundColor3 = Color3.new(1, 1, 1)
header.BorderSizePixel = 0
header.Parent = win
grad(header, C.headerA, C.headerB, 90)

-- subtle shine across header
local shine = Instance.new("Frame")
shine.Size = UDim2.new(1, 0, 0, 1)
shine.BackgroundColor3 = Color3.fromRGB(180, 210, 255)
shine.BackgroundTransparency = 0.55
shine.BorderSizePixel = 0
shine.Parent = header

label(header, {
	text = "Aup Farm",
	size = 22,
	font = Enum.Font.GothamBold,
	sz = UDim2.new(0, 220, 0, 26),
}).Position = UDim2.new(0, 20, 0, 10)

UI.sub = label(header, {
	text = "by Aup  ·  v1",
	size = 12,
	color = Color3.fromRGB(190, 220, 255),
	font = Enum.Font.Gotham,
	sz = UDim2.new(0, 300, 0, 16),
})
UI.sub.Position = UDim2.new(0, 20, 0, 36)

local pill = Instance.new("Frame")
pill.Size = UDim2.fromOffset(190, 30)
pill.Position = UDim2.new(1, -274, 0.5, -15)
pill.BackgroundColor3 = Color3.fromRGB(8, 14, 28)
pill.BackgroundTransparency = 0.15
pill.BorderSizePixel = 0
pill.Parent = header
corner(pill, 8)
stroke(pill, Color3.fromRGB(90, 140, 220))
UI.pill = label(pill, {
	text = "Idle  ·  0/100",
	size = 12,
	color = Color3.fromRGB(210, 225, 255),
	ax = Enum.TextXAlignment.Center,
	sz = UDim2.new(1, 0, 1, 0),
})

local function hBtn(x, t, bg, sc)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.fromOffset(30, 30)
	b.Position = UDim2.new(1, x, 0.5, -15)
	b.BackgroundColor3 = bg
	b.Text = t
	b.Font = Enum.Font.GothamBold
	b.TextSize = 15
	b.TextColor3 = C.text
	b.Parent = header
	corner(b, 8)
	stroke(b, sc or Color3.fromRGB(70, 110, 180))
	return b
end
local minBtn = hBtn(-78, "–", Color3.fromRGB(18, 28, 48), Color3.fromRGB(70, 110, 180))
local closeBtn = hBtn(-40, "×", Color3.fromRGB(60, 24, 32), Color3.fromRGB(180, 70, 80))

do
	local drag, o, s
	header.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			drag, o, s = true, i.Position, shell.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then
					drag = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - o
			shell.Position = UDim2.new(s.X.Scale, s.X.Offset + d.X, s.Y.Scale, s.Y.Offset + d.Y)
		end
	end)
end

-- Tabs
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -36, 0, 36)
tabBar.Position = UDim2.new(0, 18, 0, 74)
tabBar.BackgroundTransparency = 1
tabBar.Parent = win
hlist(tabBar, 6)

local pages, tabs, tabBg, cur = {}, {}, {}, "Farm"
local function show(name)
	cur = name
	for n, p in pairs(pages) do
		p.Visible = n == name
	end
	for n, t in pairs(tabs) do
		local on = n == name
		local bg = tabBg[n]
		t.TextColor3 = on and C.text or Color3.fromRGB(210, 228, 255)
		if bg then
			bg.BackgroundTransparency = on and 0 or 1
			local g = bg:FindFirstChildOfClass("UIGradient")
			if on then
				if not g then
					grad(bg, C.blue2, C.blueDeep, 90)
				end
			elseif g then
				g:Destroy()
			end
		end
	end
end

local function addTab(name)
	local wrap = Instance.new("Frame")
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.fromOffset(100, 34)
	wrap.Parent = tabBar

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.BackgroundTransparency = 1
	bg.BorderSizePixel = 0
	bg.Parent = wrap
	corner(bg, 8)

	local t = Instance.new("TextButton")
	t.AutoButtonColor = false
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = name
	t.Font = Enum.Font.GothamBold
	t.TextSize = 13
	t.TextColor3 = C.label
	t.ZIndex = 2
	t.Parent = wrap

	tabs[name] = t
	tabBg[name] = bg
	t.MouseButton1Click:Connect(function()
		show(name)
	end)
end
addTab("Farm")
addTab("Shop")
addTab("Settings")

-- Body scroll host
local body = Instance.new("Frame")
body.Size = UDim2.new(1, -36, 1, -168)
body.Position = UDim2.new(0, 18, 0, 118)
body.BackgroundTransparency = 1
body.ClipsDescendants = true
body.Parent = win

local function page(name)
	local sc = Instance.new("ScrollingFrame")
	sc.Name = name
	sc.Size = UDim2.new(1, 0, 1, 0)
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.ScrollBarThickness = 3
	sc.ScrollBarImageColor3 = C.blue
	sc.CanvasSize = UDim2.new()
	sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sc.ElasticBehavior = Enum.ElasticBehavior.Never
	sc.Visible = false
	sc.Parent = body
	-- leave room so card UIStrokes aren't clipped by the page edges
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 4)
	p.PaddingBottom = UDim.new(0, 16)
	p.PaddingLeft = UDim.new(0, 4)
	p.PaddingRight = UDim.new(0, 4)
	p.Parent = sc
	vlist(sc, 12)
	pages[name] = sc
	return sc
end

------------------------------------------------------------------------
-- FARM
------------------------------------------------------------------------
local farm = page("Farm")

-- top row: status | automation via a horizontal holder
local top = Instance.new("Frame")
top.BackgroundTransparency = 1
top.Size = UDim2.new(1, 0, 0, 0)
top.AutomaticSize = Enum.AutomaticSize.Y
top.LayoutOrder = 1
top.Parent = farm
hlist(top, 14)

local statusCard = Instance.new("Frame")
statusCard.BackgroundColor3 = C.card
statusCard.BorderSizePixel = 0
statusCard.Size = UDim2.new(0.5, -8, 0, 0)
statusCard.AutomaticSize = Enum.AutomaticSize.Y
statusCard.Parent = top
corner(statusCard, R)
stroke(statusCard, C.line)
pad(statusCard, 12)
vlist(statusCard, 8)

sect(statusCard, "Status", 1)
UI.world = label(statusCard, { text = worldName(), size = 12, color = C.muted, h = 16, order = 2 })

local grid = Instance.new("Frame")
grid.BackgroundTransparency = 1
grid.Size = UDim2.new(1, 0, 0, 112)
grid.LayoutOrder = 3
grid.Parent = statusCard

local function sbox(x, y, title)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = C.inset
	f.BorderSizePixel = 0
	f.Size = UDim2.new(0.5, -6, 0, 50)
	f.Position = UDim2.new(x, x > 0 and 6 or 0, 0, y)
	f.Parent = grid
	corner(f, 8)
	stroke(f, C.line)
	label(f, { text = title, size = 10, color = C.dim, font = Enum.Font.GothamBold, sz = UDim2.new(1, -14, 0, 14) }).Position =
		UDim2.new(0, 8, 0, 6)
	local v = label(f, { text = "0", size = 17, font = Enum.Font.GothamBold, sz = UDim2.new(1, -14, 0, 20) })
	v.Position = UDim2.new(0, 8, 0, 22)
	return v
end
UI.tSession = sbox(0, 0, "SESSION")
UI.tInv = sbox(0.5, 0, "INVENTORY")
UI.tPlant = sbox(0, 56, "GARDEN")
UI.tHarv = sbox(0.5, 56, "HARVEST")

-- full-width worth row under the 2x2 (matches Automation padding rhythm)
local worthBox = Instance.new("Frame")
worthBox.BackgroundColor3 = C.inset
worthBox.BorderSizePixel = 0
worthBox.Size = UDim2.new(1, 0, 0, 50)
worthBox.LayoutOrder = 4
worthBox.Parent = statusCard
corner(worthBox, 8)
stroke(worthBox, C.line)
label(worthBox, {
	text = "INV WORTH",
	size = 10,
	color = C.dim,
	font = Enum.Font.GothamBold,
	sz = UDim2.new(1, -16, 0, 14),
}).Position = UDim2.new(0, 10, 0, 6)
UI.tWorth = label(worthBox, {
	text = "0",
	size = 18,
	color = C.gold,
	font = Enum.Font.GothamBold,
	sz = UDim2.new(1, -16, 0, 22),
})
UI.tWorth.Position = UDim2.new(0, 10, 0, 22)

local autoCard = Instance.new("Frame")
autoCard.BackgroundColor3 = C.card
autoCard.BorderSizePixel = 0
autoCard.Size = UDim2.new(0.5, -8, 0, 0)
autoCard.AutomaticSize = Enum.AutomaticSize.Y
autoCard.Parent = top
corner(autoCard, R)
stroke(autoCard, C.line)
pad(autoCard, 12)
vlist(autoCard, 8)

sect(autoCard, "Automation", 1)
local paints = {}
table.insert(paints, check(autoCard, "Auto Plant", function()
	return State.autoPlant
end, function(v)
	State.autoPlant = v
end, 2))
table.insert(paints, check(autoCard, "Auto Harvest", function()
	return State.autoHarvest
end, function(v)
	State.autoHarvest = v
end, 3))
table.insert(paints, check(autoCard, "Auto Sell every 1s", function()
	return State.autoSell
end, function(v)
	State.autoSell = v
end, 4))
table.insert(paints, check(autoCard, "Prefer Daily Deal", function()
	return State.dailyDeal
end, function(v)
	State.dailyDeal = v
end, 5))

local actions = Instance.new("Frame")
actions.BackgroundTransparency = 1
actions.Size = UDim2.new(1, 0, 0, 40)
actions.LayoutOrder = 6
actions.Parent = autoCard
hlist(actions, 8)

local startB = button(actions, {
	text = "Start Farm",
	bg = C.blue,
	sz = UDim2.new(0.58, -4, 1, 0),
	gradient = { C.blue2, C.blueDeep },
})
local stopB = button(actions, { text = "Stop", bg = C.elev, sc = C.line, sz = UDim2.new(0.42, -4, 1, 0) })
startB.MouseButton1Click:Connect(startFarm)
stopB.MouseButton1Click:Connect(stopFarm)

-- keep Status / Automation the same height so padding lines up
local function syncFarmCards()
	task.defer(function()
		statusCard.AutomaticSize = Enum.AutomaticSize.Y
		autoCard.AutomaticSize = Enum.AutomaticSize.Y
		statusCard.Size = UDim2.new(0.5, -8, 0, 0)
		autoCard.Size = UDim2.new(0.5, -8, 0, 0)
		task.defer(function()
			local h = math.max(statusCard.AbsoluteSize.Y, autoCard.AbsoluteSize.Y)
			if h < 10 then
				return
			end
			statusCard.AutomaticSize = Enum.AutomaticSize.None
			autoCard.AutomaticSize = Enum.AutomaticSize.None
			statusCard.Size = UDim2.new(0.5, -8, 0, h)
			autoCard.Size = UDim2.new(0.5, -8, 0, h)
		end)
	end)
end
syncFarmCards()

-- plant picker card
local plantCard = card(farm, 2)
sect(plantCard, "Plant to place", 1)
UI.plantHint = label(plantCard, {
	text = "Select a seed for this world",
	size = 12,
	color = C.muted,
	h = 16,
	order = 2,
})

local plantBox = hScroll(plantCard, 128, 3)

local sellB = button(farm, {
	text = "Sell Now",
	bg = Color3.fromRGB(42, 36, 20),
	sc = C.gold,
	color = C.gold,
	order = 3,
})
sellB.MouseButton1Click:Connect(trySell)

------------------------------------------------------------------------
-- SHOP
------------------------------------------------------------------------
local shop = page("Shop")
local shopCard = card(shop, 1)
sect(shopCard, "Auto buy", 1)
local shopPaints = {}
table.insert(shopPaints, check(shopCard, "Auto buy selected seeds", function()
	return State.autoBuySeeds
end, function(v)
	State.autoBuySeeds = v
end, 2))
table.insert(shopPaints, check(shopCard, "Auto buy selected gears", function()
	return State.autoBuyGears
end, function(v)
	State.autoBuyGears = v
end, 3))

local seedCard = card(shop, 2)
sect(seedCard, "Seeds", 1)
local seedBox = vScroll(seedCard, 210, 2)
local seedGrid = Instance.new("UIGridLayout")
seedGrid.CellSize = UDim2.fromOffset(78, 90)
seedGrid.CellPadding = UDim2.fromOffset(8, 8)
seedGrid.SortOrder = Enum.SortOrder.LayoutOrder
seedGrid.Parent = seedBox

local gearCard2 = card(shop, 3)
sect(gearCard2, "Gears", 1)
local gearBox = vScroll(gearCard2, 220, 2)
local gearGrid = Instance.new("UIGridLayout")
gearGrid.CellSize = UDim2.fromOffset(78, 90)
gearGrid.CellPadding = UDim2.fromOffset(8, 8)
gearGrid.SortOrder = Enum.SortOrder.LayoutOrder
gearGrid.Parent = gearBox

------------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------------
local settingsPage = page("Settings")
local setCard = card(settingsPage, 1)
sect(setCard, "Performance", 1)
local settingsPaints = {}
table.insert(settingsPaints, check(setCard, "FPS boost (delete other plots)", function()
	return State.fpsBoost
end, function(v)
	applyFpsBoost(v)
end, 2))
label(setCard, {
	text = "Local only · other gardens stay gone until you rejoin",
	size = 11,
	color = C.dim,
	h = 16,
	order = 3,
})

sect(setCard, "Config", 4)
label(setCard, {
	text = "Saved to " .. CONFIG_FILE,
	size = 12,
	color = C.muted,
	h = 18,
	order = 5,
})
local setActs = Instance.new("Frame")
setActs.BackgroundTransparency = 1
setActs.Size = UDim2.new(1, 0, 0, 42)
setActs.LayoutOrder = 6
setActs.Parent = setCard
hlist(setActs, 10)
local saveB = button(setActs, {
	text = "Save",
	bg = C.blue,
	sz = UDim2.new(0.5, -4, 1, 0),
	gradient = { C.blue2, C.blueDeep },
})
local loadB = button(setActs, { text = "Load", bg = C.elev, sc = C.line, sz = UDim2.new(0.5, -4, 1, 0) })
local unloadB = button(setCard, { text = "Unload", bg = Color3.fromRGB(48, 28, 34), sc = C.red, color = C.red, order = 7 })

------------------------------------------------------------------------
-- Footer (Mail Bypass blue → purple)
------------------------------------------------------------------------
local footer = Instance.new("Frame")
footer.Size = UDim2.new(1, 0, 0, 40)
footer.Position = UDim2.new(0, 0, 1, -40)
footer.BorderSizePixel = 0
footer.BackgroundColor3 = Color3.new(1, 1, 1)
footer.Parent = win
grad(footer, C.footA, C.footB, 0)
label(footer, {
	text = "RightShift  ·  hide / show",
	size = 13,
	font = Enum.Font.GothamBold,
	ax = Enum.TextXAlignment.Center,
	sz = UDim2.new(1, 0, 1, 0),
})

------------------------------------------------------------------------
-- Rebuild lists
------------------------------------------------------------------------
local function rebuild()
	ensureGear()
	UI.sub.Text = "by Aup  ·  v1  ·  " .. worldName()
	UI.world.Text = worldName() .. "  ·  Plot #" .. tostring(LocalPlayer:GetAttribute("PlotId") or "?")
	UI.plantHint.Text = State.selectedPlant and ("Selected: " .. State.selectedPlant) or "Select a seed for this world"

	clear(plantBox)
	for _, seed in ipairs(worldSeeds(false)) do
		local on = State.selectedPlant == seed.name
		local t = tile(plantBox, seed.image, seed.name, on)
		t.MouseButton1Click:Connect(function()
			State.selectedPlant = if State.selectedPlant == seed.name then nil else seed.name
			rebuild()
			pcall(saveConfig)
		end)
	end

	clear(seedBox)
	for i, seed in ipairs(worldSeeds(true)) do
		local on = State.buySeeds[seed.name]
		local t = tile(seedBox, seed.image, seed.name, on)
		t.LayoutOrder = i
		t.MouseButton1Click:Connect(function()
			if State.buySeeds[seed.name] then
				State.buySeeds[seed.name] = nil
			else
				State.buySeeds[seed.name] = true
			end
			rebuild()
			pcall(saveConfig)
		end)
	end

	clear(gearBox)
	for i, item in ipairs(worldGears()) do
		local on = State.buyGears[item.name]
		local labelText = item.name
			:gsub(" Sprinkler", "")
			:gsub(" Watering Can", " Can")
			:gsub("Syrup ", "Syr ")
		local t = tile(gearBox, item.image, labelText, on)
		t.LayoutOrder = i
		t.MouseButton1Click:Connect(function()
			if State.buyGears[item.name] then
				State.buyGears[item.name] = nil
			else
				State.buyGears[item.name] = true
			end
			rebuild()
			pcall(saveConfig)
		end)
	end
end

local function fmt(sec)
	sec = math.floor(sec)
	return string.format("%02d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

UI.paint = function()
	local _, n, m = inv()
	if os.clock() - cd.paintWorth > 4 then
		local _, abbr = invWorth()
		worthCache = tostring(abbr)
		cd.paintWorth = os.clock()
	end
	UI.pill.Text = string.format("%s  ·  %d/%d", State.status, n, m)
	UI.tSession.Text = fmt(os.clock() - State.sessionStart)
	UI.tInv.Text = string.format("%d/%d", n, m)
	local plot = select(1, getPlot())
	local gCount = gardenCount(plot)
	local gMax = maxPlants(plot)
	UI.tPlant.Text = gMax > 0 and string.format("%d/%d", gCount, gMax) or tostring(gCount)
	UI.tHarv.Text = tostring(State.harvested)
	if UI.tWorth then
		UI.tWorth.Text = worthCache
	end
end

rebuild()
show("Farm")
if State.fpsBoost then
	applyFpsBoost(true)
	for _, p in ipairs(settingsPaints) do
		p()
	end
end

saveB.MouseButton1Click:Connect(function()
	setStatus(saveConfig() and "Saved" or "Save failed")
end)
loadB.MouseButton1Click:Connect(function()
	if loadConfig() then
		for _, p in ipairs(paints) do
			p()
		end
		for _, p in ipairs(shopPaints) do
			p()
		end
		for _, p in ipairs(settingsPaints) do
			p()
		end
		if State.fpsBoost then
			applyFpsBoost(true)
		end
		rebuild()
		setStatus("Loaded")
	else
		setStatus("No config")
	end
end)
unloadB.MouseButton1Click:Connect(function()
	stopFarm()
	gui:Destroy()
end)

minBtn.MouseButton1Click:Connect(function()
	local on = body.Visible
	body.Visible = not on
	tabBar.Visible = not on
	footer.Visible = not on
	shell.Size = on and UDim2.fromOffset(780, 64) or UDim2.fromOffset(780, 540)
end)
closeBtn.MouseButton1Click:Connect(function()
	gui.Enabled = false
end)
UserInputService.InputBegan:Connect(function(i, g)
	if g then
		return
	end
	if i.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

local lastW = worldId()
task.spawn(function()
	while gui.Parent do
		-- skip heavy paint while farming; farm loop already paints occasionally
		if not State.running then
			paintStats()
		end
		if worldId() ~= lastW then
			lastW = worldId()
			State.selectedPlant = nil
			areaCache.plot = nil
			areaCache.list = nil
			invalidateOcc()
			rebuild()
			setStatus("World: " .. worldName())
		end
		task.wait(2.5)
	end
end)

pcall(saveConfig)
setStatus("Idle")
print("[Aup] v1 loaded")
