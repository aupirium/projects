local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local E = ReplicatedStorage:WaitForChild("E")
local ButtonBuy = E:WaitForChild("ButtonBuy")
local BuyCar = E:FindFirstChild("BuyCar")
local RebirthRemote = E:FindFirstChild("Rebirth")
local Paycheck = E:FindFirstChild("PaycheckInteract")

local EXPLOIT_PRICE = -99999999999999999

local CAR_NAMES = {
	"Lambo", "Furari", "Bogati", "Regular", "Rich", "VanCar",
	"Lambo1", "Ferrari", "Bugatti", "Sports", "Supercar",
}

if _G.RestStopBuyCleanup then
	pcall(_G.RestStopBuyCleanup)
end

local oldGui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("RestStopBuyAllUI")
if oldGui then
	oldGui:Destroy()
end

local running = true

local function getMyPlot()
	local tycoons = workspace:FindFirstChild("Tycoons")
	if not tycoons then
		return nil
	end
	for _, plot in tycoons:GetChildren() do
		local oid = plot:FindFirstChild("OwnerId")
		if oid and oid.Value == LocalPlayer.UserId then
			return plot
		end
	end
	return nil
end

local function buyButton(btn)
	if not (btn and btn.Parent) then
		return
	end
	local reqObj = btn:FindFirstChild("RequiresThis")
	local req = reqObj and reqObj.Value or ""
	local priceObj = btn:FindFirstChild("Price")
	if priceObj then
		pcall(function()
			priceObj.Value = EXPLOIT_PRICE
		end)
	end
	pcall(function()
		ButtonBuy:FireServer(EXPLOIT_PRICE, btn.Name, req)
	end)
end

local function buyAllButtons()
	local plot = getMyPlot()
	if not plot then
		return
	end
	local folder = plot:FindFirstChild("Buttons")
	if not folder then
		return
	end
	for _, btn in folder:GetChildren() do
		buyButton(btn)
	end
end

local function tryCars()
	if not BuyCar then
		return
	end
	for _, name in ipairs(CAR_NAMES) do
		pcall(function()
			BuyCar:FireServer(EXPLOIT_PRICE, name)
		end)
		pcall(function()
			BuyCar:FireServer(name, EXPLOIT_PRICE)
		end)
		pcall(function()
			BuyCar:FireServer(name)
		end)
	end
end

local function tryCollect()
	if not Paycheck then
		return
	end
	pcall(function()
		Paycheck:FireServer()
	end)
	pcall(function()
		Paycheck:FireServer("Collect")
	end)
end

_G.RestStopBuyCleanup = function()
	running = false
end

task.spawn(function()
	local carTick = 0
	while running do
		buyAllButtons()
		tryCollect()
		carTick += 1
		if carTick >= 120 then
			carTick = 0
			tryCars()
		end
		task.wait() 
	end
end)

local RunService = game:GetService("RunService")
local hb
hb = RunService.Heartbeat:Connect(function()
	if not running then
		hb:Disconnect()
		return
	end
	buyAllButtons()
end)