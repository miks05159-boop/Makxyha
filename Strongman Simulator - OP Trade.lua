--[[====================================================================
  [X2] Strongman Simulator — OP Trade (F-015)
  tg: @sigmatik323
  --------------------------------------------------------------------
  Что делает:
    • GUI-панель трейда: выбираешь игрока и петов (OP помечены),
      жмёшь «ЗАПРОСИТЬ» → «ДОБАВИТЬ» → «ПОДТВЕРДИТЬ».
    • Использует дыру F-015: серверный Trade_AddItem (TGSTrading.AddTradeItem)
      НЕ проверяет TradeBannedPets — OP-пета можно закинуть в сессию прямым
      вызовом ремоута, минуя скрытие в UI. Партнёр принимает и подтверждает
      обычным клиентом.
    • Добавление ДО принятия вторым игроком тоже работает (F-016):
      AddTradeItem не проверяет Status сессии и до Accept ёмкости пустые.
  --------------------------------------------------------------------
  ВАЖНО (Potassium): вызов require() игровых модулей метит поток — после
  этого Instance-операции в нём падают с "lacking capability Plugin".
  Поэтому ВСЕ require и WaitForChild живут только в воркер-потоке
  (task.spawn), а GUI строится чистым потоком. Не убирать.
  --------------------------------------------------------------------
  RightShift — скрыть/показать, X — unload, кнопка «ВЫГРУЗИТЬ».
  Спам-лимит <= 400 запросов/сек, анти-АФК, конфиг между запусками.
 ====================================================================]]

if getgenv and getgenv().__SM_OPTRADE and getgenv().__SM_OPTRADE.Unload then
	pcall(getgenv().__SM_OPTRADE.Unload)
end
pcall(function()
	local p = (gethui and gethui()) or game:GetService("CoreGui")
	local old = p:FindFirstChild("SMOPTradeGui")
	if old then old:Destroy() end
end)

local __ok, __err = xpcall(function()

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UIS         = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local plr         = Players.LocalPlayer

local InstanceC = Instance
local UDim2C    = UDim2
local UDimC     = UDim
local Color3C   = Color3
local Vector2C  = Vector2
local EnumC     = Enum

local CONFIG_FILE        = "StrongmanSimulator_optrade.json"
local TARGET_PLACE       = 6766156863
local RATE_LIMIT_PER_SEC = 400
local ADD_GAP            = 0.05

local CLR = {
	bg     = Color3C.fromRGB(16, 16, 20),
	card   = Color3C.fromRGB(27, 27, 33),
	card2  = Color3C.fromRGB(22, 22, 28),
	stroke = Color3C.fromRGB(62, 62, 74),
	text   = Color3C.fromRGB(235, 235, 235),
	dim    = Color3C.fromRGB(150, 150, 160),
	accent = Color3C.fromRGB(214, 58, 58),
	busy   = Color3C.fromRGB(240, 186, 58),
	ok     = Color3C.fromRGB(96, 200, 96),
	bad    = Color3C.fromRGB(150, 36, 36),
	op     = Color3C.fromRGB(255, 82, 82),
}

--====================================================================
-- КОНФИГ
--====================================================================
local function loadConfig()
	local raw
	pcall(function() raw = readfile(CONFIG_FILE) end)
	if not raw then return {} end
	local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
	if ok and type(t) == "table" then return t end
	return {}
end

local cfg = loadConfig()
cfg.x           = tonumber(cfg.x)
cfg.y           = tonumber(cfg.y)
cfg.visible     = cfg.visible ~= false
cfg.autoAdd     = cfg.autoAdd == true
cfg.autoConfirm = cfg.autoConfirm == true

local function saveConfig()
	pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode({
			x = cfg.x, y = cfg.y, visible = cfg.visible,
			autoAdd = cfg.autoAdd, autoConfirm = cfg.autoConfirm,
		}))
	end)
end

--====================================================================
-- ЛИМИТЕР (токен-бакет, суммарно <= 400 событий/сек)
--====================================================================
local bucket = RATE_LIMIT_PER_SEC
local bucketAt = os.clock()

local function rateLimit()
	local now = os.clock()
	bucket = math.min(RATE_LIMIT_PER_SEC, bucket + (now - bucketAt) * RATE_LIMIT_PER_SEC)
	bucketAt = now
	if bucket < 1 then
		task.wait((1 - bucket) / RATE_LIMIT_PER_SEC)
		bucket = 0
		bucketAt = os.clock()
	else
		bucket = bucket - 1
	end
end

--====================================================================
-- ДАННЫЕ (require/WaitForChild — только в воркере)
--====================================================================
local FALLBACK_BANNED = {
	Shishou = true, Grumz = true, OPAngler = true, OPChristmasTree = true,
	OPCuteGhost = true, OPEasterBunnyPet = true, OPHeavenHand = true,
	OPPenguin = true, OPPineapple = true, OPScorpion = true, OPSlime = true,
	OPTheWatcher = true, OPToilet_Legendary = true, OPTungTungPet = true,
	OPVikingDuck = true, OpGingerbreadMan = true, OpIceMonster = true,
	OpReindeer = true, OpTurkey = true,
}

local BannedPets    = {}
local petsData      = {}
local petsVersion   = 0
local petsStatus    = "загрузка..."
local statusVersion = 0
local fetching      = false

local function getJobId()
	local id = game.JobId
	if not id or id == "" then return "00000000-0000-0000-0000-000000000000" end
	return id
end

local function buildPets(pets, lockedIds)
	local lockedSet = {}
	if type(lockedIds) == "table" then
		for _, id in ipairs(lockedIds) do lockedSet[id] = true end
	end
	local list = {}
	for id, pet in pairs(pets) do
		if type(pet) == "table" then
			local keyName = pet.Name
			list[#list + 1] = {
				id     = id,
				name   = pet.Title or pet.Name or "?",
				key    = keyName,
				rarity = pet.Rarity or "?",
				op     = BannedPets[keyName] == true,
				locked = lockedSet[id] == true,
			}
		end
	end
	table.sort(list, function(a, b)
		if a.op ~= b.op then return a.op end
		if a.name ~= b.name then return a.name < b.name end
		return tostring(a.id) < tostring(b.id)
	end)
	return list
end

local fetchToken = 0
local fetchAttempts = 0

local function setPetsStatus(text)
	petsStatus = text
	statusVersion = statusVersion + 1
end

local function fetchPets()
	if fetching then return end
	fetching = true
	fetchToken = fetchToken + 1
	local token = fetchToken
	setPetsStatus("загрузка...")

	task.delay(15, function()
		if token == fetchToken and fetching then
			fetching = false
			setPetsStatus("таймаут данных — жми ОБНОВИТЬ")
		end
	end)

	task.spawn(function()
		local ok, err = pcall(function()
			if next(BannedPets) == nil then
				pcall(function()
					local bp = require(workspace.Lib.Trading.TradeBannedPets)
					if type(bp) == "table" then BannedPets = bp end
				end)
				if next(BannedPets) == nil then BannedPets = FALLBACK_BANNED end
			end

			local pets, lockedIds, errText

			-- путь 1: полный снапшот данных игрока через хешированный RemoteFunction
			local ok1 = pcall(function()
				local TGSMisc = require(workspace.Lib.TGSMisc)
				local remName = TGSMisc.MD5("TGSDataStore_requestPlayerDataServerFunc" .. getJobId())
				local rf = RS:WaitForChild(remName, 10)
				if not rf then error("data remote not found") end
				local data = rf:InvokeServer()
				if type(data) ~= "table" then error("bad player data") end
				pets = data.Pets
				lockedIds = data.LockedPets
			end)
			if not ok1 or type(pets) ~= "table" then
				-- путь 2: клиентский модуль PetSystem (работает не во всех экзекьюторах)
				local ok2, e2 = pcall(function()
					local P = require(workspace.Lib.PetSystem.TGSPetSystem)
					pets = P.GetOwnedPets(plr)
					lockedIds = P.GetLockedPets(plr)
				end)
				if not ok2 then errText = tostring(e2) end
			end

			if token ~= fetchToken then return end

			if type(pets) == "table" then
				petsData = buildPets(pets, lockedIds)
				local opCount = 0
				for _, it in ipairs(petsData) do
					if it.op then opCount = opCount + 1 end
				end
				setPetsStatus(("петов: %d · OP: %d"):format(#petsData, opCount))
				petsVersion = petsVersion + 1
				if #petsData == 0 and fetchAttempts < 25 then
					fetchAttempts = fetchAttempts + 1
					setPetsStatus(("ждём данные игрока (%d/25)"):format(fetchAttempts))
					task.delay(0.6, function()
						if token == fetchToken then fetchPets() end
					end)
				else
					fetchAttempts = 0
				end
			else
				setPetsStatus("ошибка данных петов")
				pcall(print, "[OPTrade] не смог получить петов: " .. tostring(errText))
			end
		end)
		if not ok then
			if token == fetchToken then setPetsStatus("ошибка: " .. tostring(err)) end
			pcall(print, "[OPTrade] fetch упал: " .. tostring(err))
		end
		if token == fetchToken then fetching = false end
	end)
end

--====================================================================
-- РЕМОУТЫ
--====================================================================
local function waitRemote(name)
	local r = RS:WaitForChild(name, 20)
	if not r then
		pcall(print, "[OPTrade] нет ремоута: " .. name)
	end
	return r
end

local TradeRequest        = waitRemote("Trade_Request")
local TradeAccept         = waitRemote("Trade_Accept")
local TradeCancel         = waitRemote("Trade_Cancel")
local TradeCancelRequest  = waitRemote("Trade_CancelRequest")
local TradeAddItem        = waitRemote("Trade_AddItem")
local TradeRemoveItem     = waitRemote("Trade_RemoveItem")
local TradeConfirm        = waitRemote("Trade_ConfirmTrade")
local TradeSessionUpdated = waitRemote("Trade_SessionUpdated")

local session         = nil
local selectedPlayer  = nil
local selectedPets    = {}
local unloaded        = false
local lastError       = nil

--====================================================================
-- СОСТОЯНИЕ СЕССИИ
--====================================================================
local function mySide()
	if not session then return nil end
	if session.RequesterUser == plr then return "Requester" end
	if session.ReceiverUser == plr then return "Receiver" end
	return nil
end

local function otherPlayer()
	if not session then return nil end
	if session.RequesterUser == plr then return session.ReceiverUser end
	if session.ReceiverUser == plr then return session.RequesterUser end
	return nil
end

local function ourItems()
	if not session then return {} end
	local side = mySide()
	if side == "Requester" then return session.RequesterItems or {} end
	if side == "Receiver" then return session.ReceiverItems or {} end
	return {}
end

local function ourFlag()
	if not session then return false end
	if mySide() == "Requester" then return session.RequesterConfirmed == true end
	if mySide() == "Receiver" then return session.ReceiverConfirmed == true end
	return false
end

local function otherFlag()
	if not session then return false end
	if mySide() == "Requester" then return session.ReceiverConfirmed == true end
	if mySide() == "Receiver" then return session.RequesterConfirmed == true end
	return false
end

local function ourItemCount()
	local n = 0
	for _ in pairs(ourItems()) do n = n + 1 end
	return n
end

local function itemInSession(petId)
	local function scan(list)
		for _, v in pairs(list or {}) do
			if v.Id == petId then return true end
		end
		return false
	end
	return scan(session and session.RequesterItems) or scan(session and session.ReceiverItems)
end

local function shortId(id)
	return tostring(id):sub(1, 8)
end

--====================================================================
-- СОБЫТИЯ / АНТИ-АФК
--====================================================================
local conns = {}
local function track(conn)
	if conn then conns[#conns + 1] = conn end
	return conn
end

track(plr.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2C.new())
	end)
end))

--====================================================================
-- GUI
--====================================================================
local function guiParent()
	local ok, hui = pcall(function() return gethui and gethui() end)
	if ok and hui then return hui end
	return game:GetService("CoreGui")
end

local VIEW_W = 430
local VIEW_H = 596
local uiScale = 1

local function isTouchDevice()
	return UIS.TouchEnabled and not UIS.KeyboardEnabled
end

local function clampPos(x, y)
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2C.new(1280, 720)
	local w, h = VIEW_W * uiScale, VIEW_H * uiScale
	return math.clamp(x, -w + 80, math.max(0, vp.X - w)),
		math.clamp(y, 0, math.max(0, vp.Y - h))
end

local ScreenGui = InstanceC.new("ScreenGui")
ScreenGui.Name = "SMOPTradeGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = EnumC.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 9998
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = guiParent()

local Window = InstanceC.new("Frame")
Window.Name = "Window"
Window.Size = UDim2C.fromOffset(VIEW_W, VIEW_H)
Window.BackgroundColor3 = CLR.bg
Window.BorderSizePixel = 0
Window.Active = true
Window.Visible = cfg.visible
Window.Parent = ScreenGui

local uiScaleObj = InstanceC.new("UIScale")
uiScaleObj.Scale = 1
uiScaleObj.Parent = Window

local function updateScale()
	local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2C.new(1280, 720)
	if isTouchDevice() then
		uiScale = math.clamp(math.min((vp.X * 0.94) / VIEW_W, (vp.Y * 0.92) / VIEW_H), 0.55, 1.7)
	else
		uiScale = 1
	end
	uiScaleObj.Scale = uiScale
	local x, y = clampPos(Window.AbsolutePosition.X, Window.AbsolutePosition.Y)
	Window.Position = UDim2C.fromOffset(x, y)
end

do
	local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2C.new(1280, 720)
	local x = math.clamp(cfg.x or 80, 0, math.max(0, vp.X - VIEW_W))
	local y = math.clamp(cfg.y or 60, 0, math.max(0, vp.Y - VIEW_H))
	Window.Position = UDim2C.fromOffset(x, y)
end

updateScale()
do
	local cam = workspace.CurrentCamera
	if cam then
		track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if not unloaded then updateScale() end
		end))
	end
end

local wStroke = InstanceC.new("UIStroke")
wStroke.Color = CLR.stroke
wStroke.Thickness = 1
wStroke.Parent = Window
local wCorner = InstanceC.new("UICorner")
wCorner.CornerRadius = UDimC.new(0, 10)
wCorner.Parent = Window

local Header = InstanceC.new("Frame")
Header.Name = "Header"
Header.Size = UDim2C.new(1, 0, 0, 44)
Header.BackgroundColor3 = CLR.card
Header.BorderSizePixel = 0
Header.Parent = Window
local hCorner = InstanceC.new("UICorner")
hCorner.CornerRadius = UDimC.new(0, 10)
hCorner.Parent = Header

local Title = InstanceC.new("TextLabel")
Title.Size = UDim2C.new(1, -40, 0, 22)
Title.Position = UDim2C.fromOffset(12, 3)
Title.BackgroundTransparency = 1
Title.Text = "OP Trade  ·  F-015"
Title.TextColor3 = CLR.text
Title.Font = EnumC.Font.GothamBold
Title.TextSize = 15
Title.TextXAlignment = EnumC.TextXAlignment.Left
Title.Parent = Header

local SubTitle = InstanceC.new("TextLabel")
SubTitle.Size = UDim2C.new(1, -40, 0, 16)
SubTitle.Position = UDim2C.fromOffset(12, 24)
SubTitle.BackgroundTransparency = 1
SubTitle.Text = "tg: @sigmatik323   ·   RS — скрыть, X — выгрузить"
SubTitle.TextColor3 = CLR.dim
SubTitle.Font = EnumC.Font.Gotham
SubTitle.TextSize = 11
SubTitle.TextXAlignment = EnumC.TextXAlignment.Left
SubTitle.Parent = Header

local Status = InstanceC.new("TextLabel")
Status.Name = "Status"
Status.Size = UDim2C.new(1, -24, 0, 40)
Status.Position = UDim2C.fromOffset(12, 50)
Status.BackgroundColor3 = CLR.card2
Status.BorderSizePixel = 0
Status.Text = "сессия: нет"
Status.TextColor3 = CLR.dim
Status.Font = EnumC.Font.Gotham
Status.TextSize = 12
Status.TextWrapped = true
Status.TextXAlignment = EnumC.TextXAlignment.Left
Status.TextYAlignment = EnumC.TextYAlignment.Top
Status.Parent = Window
local sCorner = InstanceC.new("UICorner")
sCorner.CornerRadius = UDimC.new(0, 6)
sCorner.Parent = Status
local sPad = InstanceC.new("UIPadding")
sPad.PaddingLeft = UDimC.new(0, 8)
sPad.PaddingRight = UDimC.new(0, 4)
sPad.PaddingTop = UDimC.new(0, 3)
sPad.Parent = Status

local function sectionLabel(text, y)
	local lbl = InstanceC.new("TextLabel")
	lbl.Size = UDim2C.new(1, -24, 0, 14)
	lbl.Position = UDim2C.fromOffset(12, y)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = CLR.dim
	lbl.Font = EnumC.Font.GothamBold
	lbl.TextSize = 11
	lbl.TextXAlignment = EnumC.TextXAlignment.Left
	lbl.Parent = Window
	return lbl
end

local function makeScroll(y, h)
	local sc = InstanceC.new("ScrollingFrame")
	sc.Size = UDim2C.new(1, -24, 0, h)
	sc.Position = UDim2C.fromOffset(12, y)
	sc.BackgroundColor3 = CLR.card2
	sc.BorderSizePixel = 0
	sc.ScrollBarThickness = 4
	sc.CanvasSize = UDim2C.new(0, 0, 0, 0)
	sc.AutomaticCanvasSize = EnumC.AutomaticSize.Y
	sc.ScrollingDirection = EnumC.ScrollingDirection.Y
	sc.Parent = Window
	local c = InstanceC.new("UICorner")
	c.CornerRadius = UDimC.new(0, 6)
	c.Parent = sc
	local l = InstanceC.new("UIListLayout")
	l.Padding = UDimC.new(0, 3)
	l.Parent = sc
	local p = InstanceC.new("UIPadding")
	p.PaddingTop = UDimC.new(0, 4)
	p.PaddingBottom = UDimC.new(0, 4)
	p.PaddingLeft = UDimC.new(0, 4)
	p.PaddingRight = UDimC.new(0, 4)
	p.Parent = sc
	return sc
end

local function makeButton(text, x, y, w, h, color)
	local b = InstanceC.new("TextButton")
	b.Size = UDim2C.fromOffset(w, h)
	b.Position = UDim2C.fromOffset(x, y)
	b.BackgroundColor3 = color or CLR.card
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Text = text
	b.TextColor3 = CLR.text
	b.Font = EnumC.Font.GothamBold
	b.TextSize = 12
	b.Parent = Window
	local c = InstanceC.new("UICorner")
	c.CornerRadius = UDimC.new(0, 6)
	c.Parent = b
	return b
end

sectionLabel("ИГРОКИ", 96)
local PlayersScroll = makeScroll(112, 80)

local BtnRefreshPlayers = makeButton("обновить", 12, 196, 120, 26, CLR.card)
local BtnRequest        = makeButton("ЗАПРОСИТЬ ТРЕЙД", 138, 196, 150, 26, CLR.accent)
local BtnAccept         = makeButton("ПРИНЯТЬ", 294, 196, 124, 26, CLR.card)
local BtnCancel         = makeButton("отменить сессию", 138, 226, 150, 22, CLR.card)

local PetsTitle = sectionLabel("МОИ ПЕТЫ (красные = OP, UI их скрывает)", 254)

local PetsScroll = makeScroll(270, 168)

local BtnSelectOP     = makeButton("ВСЁ OP", 12, 444, 90, 26, CLR.card)
local BtnClearSel     = makeButton("СНЯТЬ", 106, 444, 90, 26, CLR.card)
local BtnRemove       = makeButton("УБРАТЬ", 200, 444, 90, 26, CLR.card)
local BtnRefreshPets  = makeButton("ОБНОВИТЬ", 294, 444, 124, 26, CLR.card)

local BtnAdd     = makeButton("ДОБАВИТЬ ВЫБРАННЫХ", 12, 476, 200, 34, CLR.accent)
local BtnConfirm = makeButton("ПОДТВЕРДИТЬ", 218, 476, 200, 34, CLR.accent)

local function makeToggle(text, x, y, get, set)
	local btn = makeButton("", x, y, 200, 22, CLR.card)
	btn.TextXAlignment = EnumC.TextXAlignment.Left
	local pad = InstanceC.new("UIPadding")
	pad.PaddingLeft = UDimC.new(0, 8)
	pad.Parent = btn
	local function render()
		btn.Text = (get() and "[x] " or "[ ] ") .. text
		btn.TextColor3 = get() and CLR.ok or CLR.dim
	end
	track(btn.MouseButton1Click:Connect(function()
		set(not get())
		render()
		saveConfig()
	end))
	render()
	return btn
end

makeToggle("авто-добавление", 12, 516, function() return cfg.autoAdd end, function(v) cfg.autoAdd = v end)
makeToggle("авто-подтверждение", 218, 516, function() return cfg.autoConfirm end, function(v) cfg.autoConfirm = v end)

local BtnUnload = makeButton("ВЫГРУЗИТЬ GUI", 12, 544, 200, 26, CLR.bad)

local Footer = InstanceC.new("TextLabel")
Footer.Size = UDim2C.new(1, -224, 0, 42)
Footer.Position = UDim2C.fromOffset(218, 542)
Footer.BackgroundTransparency = 1
Footer.Text = "OP-петов UI не показывает — кладём ремоутом. Партнёр принимает и подтверждает сам; после каждого добавления его подтверждение сбрасывается."
Footer.TextColor3 = CLR.dim
Footer.Font = EnumC.Font.Gotham
Footer.TextSize = 10
Footer.TextXAlignment = EnumC.TextXAlignment.Left
Footer.TextYAlignment = EnumC.TextYAlignment.Top
Footer.TextWrapped = true
Footer.Parent = Window

--====================================================================
-- ПЕРЕТАСКИВАНИЕ (по шапке)
--====================================================================
do
	local dragging, dragStart, startPos = false, nil, nil
	track(Header.InputBegan:Connect(function(input)
		if input.UserInputType == EnumC.UserInputType.MouseButton1
			or input.UserInputType == EnumC.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = Window.Position
			track(input.Changed:Connect(function()
				if input.UserInputState == EnumC.UserInputState.End then
					dragging = false
					cfg.x = math.floor(Window.AbsolutePosition.X)
					cfg.y = math.floor(Window.AbsolutePosition.Y)
					saveConfig()
				end
			end))
		end
	end))
	track(UIS.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= EnumC.UserInputType.MouseMovement
			and input.UserInputType ~= EnumC.UserInputType.Touch then return end
		local delta = input.Position - dragStart
		local x, y = clampPos(startPos.X.Offset + delta.X / uiScale, startPos.Y.Offset + delta.Y / uiScale)
		Window.Position = UDim2C.fromOffset(x, y)
	end))
end

--====================================================================
-- РЕНДЕР
--====================================================================
local function flash(btn, color)
	if not btn or not btn.Parent or unloaded then return end
	local old = btn.BackgroundColor3
	btn.BackgroundColor3 = color or CLR.ok
	task.delay(1.2, function()
		if btn and btn.Parent and not unloaded then
			btn.BackgroundColor3 = old
		end
	end)
end

local function updateStatus()
	if not Status or not Status.Parent then return end
	local head
	if not session then
		head = "нет сессии · 1) ПРИНЯТЬ запрос  2) ВСЁ OP  3) ДОБАВИТЬ  4) ПОДТВЕРДИТЬ"
		Status.TextColor3 = CLR.dim
	else
		local other = otherPlayer()
		local sel = 0
		for _, on in pairs(selectedPets) do if on then sel = sel + 1 end end
		local flags = ""
		if ourFlag() then flags = " · мы:ПОДТВ." end
		if otherFlag() then flags = flags .. " · партнёр:ПОДТВ." end
		local sideText = mySide() == "Requester" and "мы=requester"
			or (mySide() == "Receiver" and "мы=receiver" or "мы=?")
		head = ("%s | %s | %s | в трейде=%d | выбрано=%d%s"):format(
			shortId(session.Id or "?"),
			tostring(session.Status or "?"),
			sideText,
			ourItemCount(),
			sel,
			flags
		)
		if other then
			head = head .. "  ·  партнёр: " .. other.DisplayName
		end
		Status.TextColor3 = (session.Status == "Confirmed") and CLR.ok
			or (session.Status == "Accepted") and CLR.busy
			or (session.Status == "Cancelled") and CLR.bad
			or CLR.text
	end
	local tail = "\n" .. petsStatus
	if lastError then tail = tail .. "  ·  " .. lastError end
	Status.Text = head .. tail
end

local playersRows = {}
local function refreshPlayers()
	for _, c in ipairs(playersRows) do pcall(function() c:Destroy() end) end
	playersRows = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr then
			local row = InstanceC.new("TextButton")
			row.Size = UDim2C.new(1, -8, 0, 24)
			row.BackgroundColor3 = (selectedPlayer == p) and CLR.stroke or CLR.card
			row.BorderSizePixel = 0
			row.Text = p.DisplayName .. "  (@" .. p.Name .. ")"
			row.TextColor3 = (selectedPlayer == p) and CLR.text or CLR.dim
			row.Font = EnumC.Font.Gotham
			row.TextSize = 12
			row.TextXAlignment = EnumC.TextXAlignment.Left
			row.Parent = PlayersScroll
			local pad = InstanceC.new("UIPadding")
			pad.PaddingLeft = UDimC.new(0, 6)
			pad.Parent = row
			local c = InstanceC.new("UICorner")
			c.CornerRadius = UDimC.new(0, 5)
			c.Parent = row
			track(row.MouseButton1Click:Connect(function()
				selectedPlayer = p
				refreshPlayers()
			end))
			table.insert(playersRows, row)
		end
	end
end

local petRows = {}
local function renderPets()
	for _, c in ipairs(petRows) do pcall(function() c:Destroy() end) end
	petRows = {}
	for _, item in ipairs(petsData) do
		local row = InstanceC.new("TextButton")
		row.Size = UDim2C.new(1, -8, 0, 24)
		row.BackgroundColor3 = item.op and Color3C.fromRGB(48, 20, 20) or CLR.card
		row.BorderSizePixel = 0
		local prefix = (selectedPets[item.id] and "[x] " or "[ ] ")
		if item.op then prefix = prefix .. "OP · " end
		if item.locked then prefix = prefix .. "LOCK · " end
		row.Text = prefix .. item.name .. " (" .. tostring(item.rarity) .. ")"
		row.TextColor3 = item.op and CLR.op or CLR.text
		row.Font = item.op and EnumC.Font.GothamBold or EnumC.Font.Gotham
		row.TextSize = 12
		row.TextXAlignment = EnumC.TextXAlignment.Left
		row.Parent = PetsScroll
		local pad = InstanceC.new("UIPadding")
		pad.PaddingLeft = UDimC.new(0, 6)
		pad.Parent = row
		local c = InstanceC.new("UICorner")
		c.CornerRadius = UDimC.new(0, 5)
		c.Parent = row
		track(row.MouseButton1Click:Connect(function()
			if selectedPets[item.id] then
				selectedPets[item.id] = nil
			else
				selectedPets[item.id] = true
			end
			renderPets()
			updateStatus()
		end))
		table.insert(petRows, row)
	end
	PetsTitle.Text = ("МОИ ПЕТЫ · %s (%d, красные = OP)"):format(plr.Name, #petsData)
end

--====================================================================
-- ЛОГИКА ТРЕЙДА
--====================================================================
local function requestTrade()
	if not TradeRequest then return end
	if not selectedPlayer or not selectedPlayer.Parent then
		lastError = "игрок не выбран"
		flash(BtnRequest, CLR.bad)
		updateStatus()
		return
	end
	task.spawn(function()
		rateLimit()
		local ok, err = pcall(function() return TradeRequest:InvokeServer(selectedPlayer) end)
		if ok then
			lastError = nil
			flash(BtnRequest, CLR.ok)
		else
			lastError = "запрос: " .. tostring(err)
			flash(BtnRequest, CLR.bad)
		end
		updateStatus()
	end)
end

local function acceptIncoming()
	if not TradeAccept then return end
	if not session or session.Status ~= "Sent" or session.RequesterUser == plr then
		lastError = "нет входящего запроса"
		flash(BtnAccept, CLR.bad)
		updateStatus()
		return
	end
	task.spawn(function()
		rateLimit()
		local ok, err = pcall(function() return TradeAccept:InvokeServer(session.RequesterUser) end)
		if ok then
			lastError = nil
			flash(BtnAccept, CLR.ok)
		else
			lastError = "принять: " .. tostring(err)
			flash(BtnAccept, CLR.bad)
		end
		updateStatus()
	end)
end

local function cancelSession()
	if not session or not TradeCancel then
		flash(BtnCancel, CLR.bad)
		return
	end
	local sid = session.Id
	local isRequesterSent = session.RequesterUser == plr and session.Status == "Sent"
	task.spawn(function()
		rateLimit()
		local ok, err
		if isRequesterSent and TradeCancelRequest then
			ok, err = pcall(function() return TradeCancelRequest:InvokeServer(session.ReceiverUser) end)
		else
			ok, err = pcall(function() return TradeCancel:InvokeServer({ Id = sid }) end)
		end
		if ok then
			lastError = nil
			flash(BtnCancel, CLR.ok)
		else
			lastError = "отмена: " .. tostring(err)
			flash(BtnCancel, CLR.bad)
		end
		updateStatus()
	end)
end

local function addSelected(manual)
	if not TradeAddItem or not session then
		if manual then flash(BtnAdd, CLR.bad) end
		return 0
	end
	if session.Status ~= "Sent" and session.Status ~= "Accepted" then
		if manual then
			lastError = "в сессии нельзя добавлять"
			flash(BtnAdd, CLR.bad)
		end
		return 0
	end
	local pending = {}
	for petId, on in pairs(selectedPets) do
		if on and not itemInSession(petId) then
			pending[#pending + 1] = petId
		end
	end
	if #pending == 0 then
		if manual then
			lastError = "нечего добавлять"
			flash(BtnAdd, CLR.ok)
			updateStatus()
		end
		return 0
	end
	local before = ourItemCount()
	local sid = session.Id
	local fired, failures = 0, 0
	for _, petId in ipairs(pending) do
		rateLimit()
		local ok = pcall(function()
			return TradeAddItem:InvokeServer({ Id = sid }, { Id = petId, Category = "Pets" })
		end)
		if ok then fired = fired + 1 else failures = failures + 1 end
		if ADD_GAP > 0 then task.wait(ADD_GAP) end
	end
	local t0 = os.clock()
	while os.clock() - t0 < 2 do
		task.wait(0.1)
		if ourItemCount() >= before + fired then break end
	end
	local added = math.max(0, ourItemCount() - before)
	lastError = (failures > 0) and ("ошибок: " .. failures) or nil
	if manual then flash(BtnAdd, added > 0 and CLR.ok or CLR.bad) end
	pcall(print, ("[OPTrade] отправлено %d, в сессии прибавилось %d"):format(fired, added))
	updateStatus()
	return added
end

local function removeSelected()
	if not TradeRemoveItem or not session then
		flash(BtnRemove, CLR.bad)
		return 0
	end
	local sid = session.Id
	local targets = {}
	for petId, on in pairs(selectedPets) do
		if on and itemInSession(petId) then targets[#targets + 1] = petId end
	end
	if #targets == 0 then
		flash(BtnRemove, CLR.bad)
		return 0
	end
	local removed = 0
	for _, petId in ipairs(targets) do
		rateLimit()
		local ok = pcall(function()
			return TradeRemoveItem:InvokeServer({ Id = sid }, { Id = petId })
		end)
		if ok then removed = removed + 1 end
		task.wait(ADD_GAP)
	end
	flash(BtnRemove, removed > 0 and CLR.ok or CLR.bad)
	updateStatus()
	return removed
end

local function confirmTrade()
	if not TradeConfirm or not session then
		flash(BtnConfirm, CLR.bad)
		return
	end
	if session.Status ~= "Sent" and session.Status ~= "Accepted" then
		flash(BtnConfirm, CLR.bad)
		return
	end
	local sid = session.Id
	task.spawn(function()
		rateLimit()
		local ok, err = pcall(function() return TradeConfirm:InvokeServer({ Id = sid }) end)
		if ok then
			lastError = nil
			flash(BtnConfirm, CLR.ok)
		else
			lastError = "подтвердить: " .. tostring(err)
			flash(BtnConfirm, CLR.bad)
		end
		updateStatus()
	end)
end

-- авто-режим
task.spawn(function()
	while not unloaded do
		task.wait(0.5)
		if session and cfg.autoAdd and session.Status == "Accepted" then
			local any = false
			for _, on in pairs(selectedPets) do
				if on then any = true break end
			end
			if any then
				addSelected(false)
			end
		end
		if session and cfg.autoConfirm and session.Status == "Accepted"
			and not ourFlag() and ourItemCount() > 0 then
			confirmTrade()
		end
	end
end)

-- рендер-цикл (чистый поток, до создания GUI ничего не require-илось)
local renderedVersion = -1
local renderedStatusVersion = -1
task.spawn(function()
	while not unloaded do
		task.wait(0.2)
		if petsVersion ~= renderedVersion or statusVersion ~= renderedStatusVersion then
			renderedVersion = petsVersion
			renderedStatusVersion = statusVersion
			pcall(renderPets)
			pcall(updateStatus)
		end
	end
end)

--====================================================================
-- ПОДКЛЮЧЕНИЯ
--====================================================================
if TradeSessionUpdated then
	track(TradeSessionUpdated.OnClientEvent:Connect(function(sess)
		if type(sess) == "table" and sess.Id then
			local wasConfirmed = session and session.Status == "Confirmed"
			session = sess
			if sess.Status == "Confirmed" and not wasConfirmed then
				fetchPets()
			end
			if sess.Status == "Cancelled" then
				selectedPets = {}
				pcall(renderPets)
			end
			updateStatus()
		end
	end))
end

track(Players.PlayerAdded:Connect(function() task.defer(refreshPlayers) end))
track(plr.CharacterAdded:Connect(function()
	task.delay(1.5, function()
		if not unloaded then fetchPets() end
	end)
end))
track(Players.PlayerRemoving:Connect(function(p)
	if selectedPlayer == p then selectedPlayer = nil end
	task.defer(refreshPlayers)
	updateStatus()
end))

track(BtnRefreshPlayers.MouseButton1Click:Connect(function() pcall(refreshPlayers) end))
track(BtnRequest.MouseButton1Click:Connect(function() pcall(requestTrade) end))
track(BtnAccept.MouseButton1Click:Connect(function() pcall(acceptIncoming) end))
track(BtnCancel.MouseButton1Click:Connect(function() pcall(cancelSession) end))
track(BtnAdd.MouseButton1Click:Connect(function() pcall(function() addSelected(true) end) end))
track(BtnConfirm.MouseButton1Click:Connect(function() pcall(confirmTrade) end))
track(BtnRemove.MouseButton1Click:Connect(function() pcall(removeSelected) end))
track(BtnRefreshPets.MouseButton1Click:Connect(function() pcall(fetchPets) end))
track(BtnClearSel.MouseButton1Click:Connect(function()
	selectedPets = {}
	pcall(renderPets)
	updateStatus()
end))
track(BtnSelectOP.MouseButton1Click:Connect(function()
	for _, item in ipairs(petsData) do
		if item.op then selectedPets[item.id] = true end
	end
	pcall(renderPets)
	updateStatus()
end))

--====================================================================
-- UNLOAD
--====================================================================
local function unload()
	if unloaded then return end
	unloaded = true
	pcall(function()
		cfg.x = math.floor(Window.AbsolutePosition.X)
		cfg.y = math.floor(Window.AbsolutePosition.Y)
	end)
	saveConfig()
	for i = 1, #conns do pcall(function() conns[i]:Disconnect() end) end
	conns = {}
	pcall(function() ScreenGui:Destroy() end)
	if getgenv then getgenv().__SM_OPTRADE = nil end
end

track(BtnUnload.MouseButton1Click:Connect(function() unload() end))

track(UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	pcall(function()
		if input.KeyCode == EnumC.KeyCode.RightShift then
			Window.Visible = not Window.Visible
			cfg.visible = Window.Visible
			saveConfig()
		elseif input.KeyCode == EnumC.KeyCode.X then
			unload()
		end
	end)
end))

if getgenv then
	getgenv().__SM_OPTRADE = {
		Unload = unload,
		requestTrade = requestTrade,
		acceptIncoming = acceptIncoming,
		addSelected = addSelected,
		removeSelected = removeSelected,
		confirmTrade = confirmTrade,
		cancelSession = cancelSession,
		refreshPets = fetchPets,
		getSession = function() return session end,
		getPets = function() return petsData end,
	}
end

--====================================================================
-- СТАРТ
--====================================================================
if game.PlaceId ~= TARGET_PLACE then
	pcall(print, ("[OPTrade] не тот плейс: %d (скрипт для %d)"):format(game.PlaceId, TARGET_PLACE))
else
	refreshPlayers()
	updateStatus()
	fetchPets()
	pcall(print, "[OPTrade] GUI готов. Выбери игрока → ЗАПРОСИТЬ ТРЕЙД → выбери OP-петов → ДОБАВИТЬ → ПОДТВЕРДИТЬ.")
end

end, function(e)
	local tb = ""
	pcall(function() tb = debug.traceback(tostring(e), 2) end)
	if getgenv then
		pcall(function() getgenv().__SM_OPTRADE_error = tostring(e) end)
		pcall(function() getgenv().__SM_OPTRADE_tb = tb end)
	end
	pcall(print, "[OPTrade] ОШИБКА: " .. tostring(e) .. "\n" .. tb)
end)

if not __ok then
	warn("[OPTrade] скрипт упал: " .. tostring(__err))
end
