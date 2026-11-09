--[[
    Prensado Camlock — v4
    Teclas: CONFIG.KEY (toggle) | INSERT (panel) | DELETE (unload)

    NUEVO v4
      - Lista de exclusión: los jugadores en la lista no son lockeados
        (pestaña LISTA, persiste entre ejecuciones)
      - ESP / Chams por Highlight, color, transparencia, contorno,
        nombres, distancia y modo de profundidad desde la pestaña ESP
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")

local LP     = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- ===================== CONFIG =====================
local CONFIG = {
    KEY         = Enum.KeyCode.F,
    UNLOAD_KEY  = Enum.KeyCode.Delete,
    PANEL_KEY   = Enum.KeyCode.Insert,

    AIM_PART    = "Head",
    MODE        = "Smooth",
    FOV         = 220,
    SMOOTHNESS  = 0.55,
    PREDICTION  = 0.10,
    MAX_DISTANCE= 2000,
    MAX_PREDICT = 45,

    TEAM_CHECK  = true,
    WALL_CHECK  = false,
    SHOW_FOV    = true,
    FOV_AT_MOUSE= false,
    HIGHLIGHT   = true,
    AUTO_ENABLE = false,
    MOBILE_BUTTON = true,

    STICKY      = true,
    SNAP_ON_LOCK= true,
    REACQUIRE   = true,

    -- ESP
    ESP_ENABLED      = false,
    ESP_FILL_COLOR   = Color3.fromRGB(0, 255, 140),
    ESP_OUTLINE_COLOR= Color3.fromRGB(0, 255, 140),
    ESP_FILL_TRANSP  = 0.55,
    ESP_OUTLINE_TRANSP = 0,
    ESP_DEPTH_TOP    = true,
    ESP_SHOW_NAMES   = true,
    ESP_SHOW_DIST    = true,
    ESP_TEAM_CHECK   = true,
    ESP_INCLUDE_IGNORED = false,
    ESP_TEAM_COLOR   = false,
    ESP_MAX_DIST     = 600,

    -- lista de exclusión
    IGNORE_FRIENDS   = false,
    SAVE_CONFIG      = true,
}
-- ==================================================

local SAVE_FILE = "Prensado_cfg.json"

local enabled, unloaded = CONFIG.AUTO_ENABLE, false
local locked, needRelock = nil, true
local highlight
local Connections = {}

local ignored = {}          -- [userId] = true
local nameCache = {}        -- [userId] = nombre

local function conn(c) table.insert(Connections, c); return c end

local function isAlive(plr)
    local char = plr and plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return (hum and hum.Health > 0) and true or false
end

local function isFriend(plr)
    local ok, res = pcall(function() return LP:IsFriendsWith(plr.UserId) end)
    return ok and res
end

local function isIgnored(plr)
    if not plr then return false end
    if ignored[plr.UserId] then return true end
    if CONFIG.IGNORE_FRIENDS and plr ~= LP and isFriend(plr) then return true end
    return false
end

-- ---------- persistencia ----------
local function saveConfig()
    if not CONFIG.SAVE_CONFIG then return end
    pcall(function()
        local data = {
            ignored = {},
            esp = {
                fill = tostring(CONFIG.ESP_FILL_COLOR),
                outline = tostring(CONFIG.ESP_OUTLINE_COLOR),
                fillT = CONFIG.ESP_FILL_TRANSP,
                outlineT = CONFIG.ESP_OUTLINE_TRANSP,
                depth = CONFIG.ESP_DEPTH_TOP,
                names = CONFIG.ESP_SHOW_NAMES,
                dist = CONFIG.ESP_SHOW_DIST,
                team = CONFIG.ESP_TEAM_CHECK,
                teamColor = CONFIG.ESP_TEAM_COLOR,
                maxDist = CONFIG.ESP_MAX_DIST,
            },
        }
        for id in pairs(ignored) do table.insert(data.ignored, id) end
        writefile(SAVE_FILE, HttpService:JSONEncode(data))
    end)
end

local function loadConfig()
    if not CONFIG.SAVE_CONFIG then return end
    pcall(function()
        if not (isfile and isfile(SAVE_FILE)) then return end
        local data = HttpService:JSONDecode(readfile(SAVE_FILE))
        for _, id in ipairs(data.ignored or {}) do ignored[tonumber(id)] = true end
        local e = data.esp or {}
        local function col(s, def)
            if type(s) ~= "string" then return def end
            local r, g, b = s:match("(%d+), (%d+), (%d+)")
            if r then return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b)) end
            return def
        end
        CONFIG.ESP_FILL_COLOR = col(e.fill, CONFIG.ESP_FILL_COLOR)
        CONFIG.ESP_OUTLINE_COLOR = col(e.outline, CONFIG.ESP_OUTLINE_COLOR)
        CONFIG.ESP_FILL_TRANSP = e.fillT or CONFIG.ESP_FILL_TRANSP
        CONFIG.ESP_OUTLINE_TRANSP = e.outlineT or CONFIG.ESP_OUTLINE_TRANSP
        CONFIG.ESP_DEPTH_TOP = (e.depth ~= false)
        CONFIG.ESP_SHOW_NAMES = (e.names ~= false)
        CONFIG.ESP_SHOW_DIST = (e.dist ~= false)
        CONFIG.ESP_TEAM_CHECK = (e.team ~= false)
        CONFIG.ESP_TEAM_COLOR = (e.teamColor == true)
        CONFIG.ESP_MAX_DIST = e.maxDist or CONFIG.ESP_MAX_DIST
    end)
end
loadConfig()

-- ---------- apuntado ----------
local function getPart(char)
    if not char then return nil end
    local name = CONFIG.AIM_PART
    if name == "Torso" then
        return char:FindFirstChild("UpperTorso")
            or char:FindFirstChild("Torso")
            or char:FindFirstChild("HumanoidRootPart")
    elseif name == "Random" then
        name = (math.random() < 0.5) and "Head" or "HumanoidRootPart"
    end
    if name ~= "Closest" then
        return char:FindFirstChild(name) or char:FindFirstChild("HumanoidRootPart")
    end
    local best, bestD
    local camPos = Camera.CFrame.Position
    for _, v in ipairs(char:GetChildren()) do
        if v:IsA("BasePart") then
            local d = (v.Position - camPos).Magnitude
            if not bestD or d < bestD then best, bestD = v, d end
        end
    end
    return best
end

local function aimCenter()
    if CONFIG.FOV_AT_MOUSE then
        return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
    end
    return Camera.ViewportSize / 2
end

local function predict(pos, vel)
    local p = vel * CONFIG.PREDICTION
    if p.Magnitude > CONFIG.MAX_PREDICT then p = p.Unit * CONFIG.MAX_PREDICT end
    return pos + p
end

local function findTarget()
    local best, bestScore
    local center = aimCenter()
    local camPos = Camera.CFrame.Position
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and not isIgnored(plr) then
            local char = plr.Character
            if char and isAlive(plr) then
                local ok = not (CONFIG.TEAM_CHECK and LP.Team and plr.Team == LP.Team)
                if ok then
                    local part = getPart(char)
                    if part then
                        local worldPos = predict(part.Position, part.AssemblyLinearVelocity)
                        local sp, onScreen = Camera:WorldToViewportPoint(worldPos)
                        if onScreen and sp.Z > 0 then
                            local off = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                            if off <= CONFIG.FOV / 2 then
                                local dist = (part.Position - camPos).Magnitude
                                if dist <= CONFIG.MAX_DISTANCE then
                                    if CONFIG.WALL_CHECK then
                                        local rp = RaycastParams.new()
                                        rp.FilterType = Enum.RaycastFilterType.Exclude
                                        rp.FilterDescendantsInstances = { LP.Character, char }
                                        if Workspace:Raycast(camPos, worldPos - camPos, rp) then
                                            ok = false
                                        end
                                    end
                                    if ok then
                                        local score = off + dist * 0.05
                                        if not bestScore or score < bestScore then
                                            best, bestScore = plr, score
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local circle
pcall(function()
    circle = Drawing.new("Circle")
    circle.Thickness = 1.5
    circle.NumSides = 64
    circle.Filled = false
    circle.Transparency = 0.65
end)

local hlFolder
local function ensureFolder()
    if not hlFolder or not hlFolder.Parent then
        hlFolder = Instance.new("Folder")
        hlFolder.Name = "PrensadoVisuals"
        hlFolder.Parent = Workspace
    end
    return hlFolder
end

local function setHighlight(plr)
    if highlight then highlight:Destroy(); highlight = nil end
    if not CONFIG.HIGHLIGHT then return end
    local char = plr and plr.Character
    if not char then return end
    highlight = Instance.new("Highlight")
    highlight.Adornee = char
    highlight.FillColor = Color3.fromRGB(0, 255, 140)
    highlight.FillTransparency = 0.6
    highlight.OutlineColor = Color3.fromRGB(0, 255, 140)
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = ensureFolder()
end

local function snapTo(plr)
    local char = plr and plr.Character
    local part = char and getPart(char)
    if not part then return end
    Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, part.Position)
end

local function acquire()
    local t = findTarget()
    if not t then return end
    locked = t
    setHighlight(t)
    if CONFIG.SNAP_ON_LOCK then snapTo(t) end
end

local function release()
    locked = nil
    setHighlight(nil)
end

-- ===================== ESP =====================
local espData = {}   -- [player] = { hl = , bb = , label = }

local function espColorFor(plr)
    if CONFIG.ESP_TEAM_COLOR and plr.Team then
        return plr.Team.TeamColor.Color
    end
    return nil
end

local function buildESP(plr)
    if not CONFIG.ESP_ENABLED or plr == LP then return end
    local char = plr.Character
    if not char then return end
    local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    if not head then return end

    local entry = {}
    local hl = Instance.new("Highlight")
    hl.Adornee = char
    hl.Parent = ensureFolder()
    entry.hl = hl

    if CONFIG.ESP_SHOW_NAMES or CONFIG.ESP_SHOW_DIST then
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(180, 34)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
        bb.AlwaysOnTop = CONFIG.ESP_DEPTH_TOP
        bb.MaxDistance = 400
        bb.Adornee = head
        bb.Parent = head

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.4
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        label.Text = plr.Name
        label.Parent = bb

        entry.bb, entry.label = bb, label
    end

    espData[plr] = entry
end

local function destroyESP(plr)
    local e = espData[plr]
    if not e then return end
    if e.hl then e.hl:Destroy() end
    if e.bb then e.bb:Destroy() end
    espData[plr] = nil
end

local function clearESP()
    for plr in pairs(espData) do destroyESP(plr) end
    table.clear(espData)
end

local function refreshESP()
    clearESP()
    if not CONFIG.ESP_ENABLED then return end
    for _, plr in ipairs(Players:GetPlayers()) do buildESP(plr) end
end

local function applyESP()
    local camPos = Camera.CFrame.Position
    for plr, e in pairs(espData) do
        local char = plr.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local ok = char and hrp and isAlive(plr)
            and (not CONFIG.ESP_TEAM_CHECK or not (LP.Team and plr.Team == LP.Team))
            and (CONFIG.ESP_INCLUDE_IGNORED or not isIgnored(plr))
        local dist = ok and (hrp.Position - camPos).Magnitude or 0
        if ok and dist > CONFIG.ESP_MAX_DIST then ok = false end

        if e.hl then
            e.hl.Enabled = ok and true or false
            local c = espColorFor(plr)
            e.hl.FillColor = c or CONFIG.ESP_FILL_COLOR
            e.hl.OutlineColor = c or CONFIG.ESP_OUTLINE_COLOR
            e.hl.FillTransparency = CONFIG.ESP_FILL_TRANSP
            e.hl.OutlineTransparency = CONFIG.ESP_OUTLINE_TRANSP
            e.hl.DepthMode = CONFIG.ESP_DEPTH_TOP
                and Enum.HighlightDepthMode.AlwaysOnTop
                or Enum.HighlightDepthMode.Occluded
        end
        if e.bb then
            e.bb.Enabled = ok and true or false
            e.bb.AlwaysOnTop = CONFIG.ESP_DEPTH_TOP
            local parts = {}
            if CONFIG.ESP_SHOW_NAMES then table.insert(parts, plr.Name) end
            if CONFIG.ESP_SHOW_DIST then
                table.insert(parts, string.format("[%dm]", math.floor(dist)))
            end
            e.label.Text = table.concat(parts, "  ")
            e.label.TextColor3 = espColorFor(plr) or CONFIG.ESP_FILL_COLOR
        end
    end
end
-- ==============================================

-- ---------- bucle de cámara ----------
conn(RunService:BindToRenderStep("PrensadoCamlock",
    Enum.RenderPriority.Camera.Value + 1, function(dt)
    if unloaded then return end
    Camera = Workspace.CurrentCamera
    if not Camera then return end

    if circle then
        circle.Position = aimCenter()
        circle.Radius = CONFIG.FOV / 2
        circle.Visible = CONFIG.SHOW_FOV and enabled
        circle.Color = locked and Color3.fromRGB(0, 255, 140)
            or (enabled and Color3.fromRGB(255, 200, 60)
                         or Color3.fromRGB(120, 120, 130))
    end

    if not enabled then return end

    if locked and (not isAlive(locked) or not getPart(locked.Character)
    or isIgnored(locked)) then
        release()
        needRelock = CONFIG.REACQUIRE
    end

    if needRelock and not locked then
        acquire()
        if locked then needRelock = false end
    end

    if not locked then return end

    local part = getPart(locked.Character)
    if not part then return end

    if not CONFIG.STICKY then
        local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
        if not onScreen or sp.Z <= 0
        or (Vector2.new(sp.X, sp.Y) - aimCenter()).Magnitude > CONFIG.FOV / 2 then
            release()
            needRelock = true
            return
        end
    end

    local goal = predict(part.Position, part.AssemblyLinearVelocity)
    local goalCF = CFrame.lookAt(Camera.CFrame.Position, goal)

    if CONFIG.MODE == "Snap" then
        Camera.CFrame = goalCF
    elseif CONFIG.MODE == "Silent" then
        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
            Camera.CFrame = goalCF
        end
    else
        local alpha = 1 - (1 - CONFIG.SMOOTHNESS) ^ (math.min(dt, 0.05) * 60)
        Camera.CFrame = Camera.CFrame:Lerp(goalCF, math.clamp(alpha, 0, 1))
    end
end))

-- hilo del ESP
conn(RunService.Heartbeat:Connect(function(dt)
    if unloaded then return end
    espAcc = (espAcc or 0) + dt
    if espAcc < 0.2 then return end
    espAcc = 0
    applyESP()
end))

-- ---------- GUI ----------
local gui = Instance.new("ScreenGui")
gui.Name = "PrensadoUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = game:GetService("CoreGui")

local function mkBtn(parent, text, w, h, x, y)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w, h)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
    b.TextColor3 = Color3.fromRGB(232, 232, 238)
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.Text = text
    b.BorderSizePixel = 0
    b.AutoButtonColor = true
    b.Parent = parent
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(268, 452)
panel.Position = UDim2.fromOffset(30, 70)
panel.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
local ps = Instance.new("UIStroke", panel)
ps.Color = Color3.fromRGB(60, 60, 68); ps.Thickness = 1

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 30)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "  PRENSADO v4"
title.Parent = panel

mkBtn(panel, "X", 24, 22, 236, 4).MouseButton1Click:Connect(function()
    panel.Visible = false
end)

-- pestañas
local pages, tabBtns = {}, {}
local tabRow = { { "AIM", 14 }, { "ESP", 104 }, { "LISTA", 194 } }
local function showTab(name)
    for n, f in pairs(pages) do f.Visible = (n == name) end
    for n, b in pairs(tabBtns) do
        b.BackgroundColor3 = (n == name) and Color3.fromRGB(40, 74, 58)
                                            or Color3.fromRGB(30, 30, 34)
    end
    if name == "LISTA" then rebuildList() end
end
for _, t in ipairs(tabRow) do
    local b = mkBtn(panel, t[1], 60, 22, t[2], 32)
    tabBtns[t[1]] = b
    b.MouseButton1Click:Connect(function() showTab(t[1]) end)
end

local function mkPage(name)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -16, 1, -66)
    f.Position = UDim2.fromOffset(8, 60)
    f.BackgroundTransparency = 1
    f.Visible = false
    f.Parent = panel
    pages[name] = f
    return f
end
local aimPage, espPage, listPage = mkPage("AIM"), mkPage("ESP"), mkPage("LISTA")

-- ---------- pestaña AIM ----------
local toggleBtn = mkBtn(aimPage, "", 240, 28, 4, 2)
toggleBtn.TextSize = 13
local function refreshToggle()
    toggleBtn.Text = (enabled and "ACTIVADO  [" or "DESACTIVADO  [") .. CONFIG.KEY.Name .. "]"
    toggleBtn.BackgroundColor3 = enabled and Color3.fromRGB(24, 74, 48)
                                       or Color3.fromRGB(52, 34, 34)
end

local function setEnabled(v)
    enabled = v
    release()
    needRelock = v
    refreshToggle()
    if mobileBtn then
        mobileBtn.BackgroundColor3 = v and Color3.fromRGB(24, 74, 48)
                                       or Color3.fromRGB(52, 34, 34)
    end
end
toggleBtn.MouseButton1Click:Connect(function() setEnabled(not enabled) end)

mkBtn(aimPage, "RE-LOCK (cambiar objetivo)", 240, 22, 4, 34)
    .MouseButton1Click:Connect(function()
        if enabled then release(); needRelock = true end
    end)

local function mkGroup(parent, labels, y, w, step, get, set)
    local btns = {}
    for i, name in ipairs(labels) do
        local b = mkBtn(parent, name, w, 22, 4 + (i - 1) * step, y)
        btns[name] = b
        b.MouseButton1Click:Connect(function()
            set(name)
            for n, bb in pairs(btns) do
                bb.BackgroundColor3 = (n == name) and Color3.fromRGB(24, 74, 48)
                                                   or Color3.fromRGB(30, 30, 34)
            end
        end)
    end
    if btns[get()] then btns[get()].BackgroundColor3 = Color3.fromRGB(24, 74, 48) end
end

mkGroup(aimPage, { "Head", "Torso", "Random", "Closest" }, 62, 56, 59,
    function() return CONFIG.AIM_PART end,
    function(v) CONFIG.AIM_PART = v end)
mkGroup(aimPage, { "Smooth", "Snap", "Silent" }, 90, 76, 80,
    function() return CONFIG.MODE end,
    function(v) CONFIG.MODE = v end)

local function mkStepper(parent, label, y, get, set, step, min, max, fmt, cb)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(104, 22)
    l.Position = UDim2.fromOffset(4, y)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.Gotham
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = Color3.fromRGB(190, 190, 200)
    l.Text = label
    l.Parent = parent

    local minus = mkBtn(parent, "-", 24, 22, 138, y)
    local val = Instance.new("TextLabel")
    val.Size = UDim2.fromOffset(56, 22)
    val.Position = UDim2.fromOffset(166, y)
    val.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
    val.Font = Enum.Font.GothamMedium
    val.TextSize = 11
    val.TextColor3 = Color3.fromRGB(240, 240, 245)
    val.Parent = parent
    Instance.new("UICorner", val).CornerRadius = UDim.new(0, 6)
    local plus = mkBtn(parent, "+", 24, 22, 226, y)

    local function upd() val.Text = string.format(fmt, get()) end
    upd()
    minus.MouseButton1Click:Connect(function()
        set(math.max(min, get() - step)); upd(); if cb then cb() end
    end)
    plus.MouseButton1Click:Connect(function()
        set(math.min(max, get() + step)); upd(); if cb then cb() end
    end)
end

mkStepper(aimPage, "FOV (px)", 118,
    function() return CONFIG.FOV end,
    function(v) CONFIG.FOV = v end, 25, 50, 900, "%d")
mkStepper(aimPage, "Suavizado", 146,
    function() return CONFIG.SMOOTHNESS end,
    function(v) CONFIG.SMOOTHNESS = v end, 0.05, 0.05, 1, "%.2f")
mkStepper(aimPage, "Predicción", 174,
    function() return CONFIG.PREDICTION end,
    function(v) CONFIG.PREDICTION = v end, 0.02, 0, 1, "%.2f")
mkStepper(aimPage, "Distancia", 202,
    function() return CONFIG.MAX_DISTANCE end,
    function(v) CONFIG.MAX_DISTANCE = v end, 100, 200, 10000, "%d")

local function mkCheck(parent, label, y, get, set, cb)
    local b = mkBtn(parent, "  " .. label, 240, 22, 4, y)
    b.TextXAlignment = Enum.TextXAlignment.Left
    local function paint()
        b.BackgroundColor3 = get() and Color3.fromRGB(24, 74, 48)
                                      or Color3.fromRGB(30, 30, 34)
    end
    paint()
    b.MouseButton1Click:Connect(function()
        set(not get()); paint(); if cb then cb() end
    end)
end

mkCheck(aimPage, "Team check", 230,
    function() return CONFIG.TEAM_CHECK end,
    function(v) CONFIG.TEAM_CHECK = v end)
mkCheck(aimPage, "Wall check", 256,
    function() return CONFIG.WALL_CHECK end,
    function(v) CONFIG.WALL_CHECK = v end)
mkCheck(aimPage, "Círculo de FOV", 282,
    function() return CONFIG.SHOW_FOV end,
    function(v) CONFIG.SHOW_FOV = v end)
mkCheck(aimPage, "FOV en el cursor", 308,
    function() return CONFIG.FOV_AT_MOUSE end,
    function(v) CONFIG.FOV_AT_MOUSE = v end)
mkCheck(aimPage, "Resaltar objetivo", 334,
    function() return CONFIG.HIGHLIGHT end,
    function(v)
        CONFIG.HIGHLIGHT = v
        if v then setHighlight(locked) else setHighlight(nil) end
    end)

mkBtn(aimPage, "IGNORAR OBJETIVO ACTUAL", 240, 22, 4, 364)
    .MouseButton1Click:Connect(function()
        if locked then
            ignored[locked.UserId] = true
            nameCache[locked.UserId] = locked.Name
            release(); needRelock = true
            saveConfig(); rebuildList()
        end
    end)

-- ---------- pestaña ESP ----------
local espToggle = mkBtn(espPage, "", 240, 26, 4, 2)
espToggle.TextSize = 13
local function refreshEspToggle()
    espToggle.Text = CONFIG.ESP_ENABLED and "ESP ACTIVADO" or "ESP DESACTIVADO"
    espToggle.BackgroundColor3 = CONFIG.ESP_ENABLED and Color3.fromRGB(24, 74, 48)
                                                  or Color3.fromRGB(52, 34, 34)
end
espToggle.MouseButton1Click:Connect(function()
    CONFIG.ESP_ENABLED = not CONFIG.ESP_ENABLED
    refreshEspToggle()
    refreshESP()
    saveConfig()
end)

local function mkSwatches(label, y, colors, get, set)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(240, 14)
    l.Position = UDim2.fromOffset(4, y)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.Gotham
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = Color3.fromRGB(190, 190, 200)
    l.Text = label
    l.Parent = espPage

    for i, c in ipairs(colors) do
        local b = mkBtn(espPage, "", 18, 18, 4 + (i - 1) * 20, y + 15)
        b.BackgroundColor3 = c
        b.MouseButton1Click:Connect(function()
            set(c)
            refreshESP()
            saveConfig()
        end)
    end
end

local PALETTE = {
    Color3.fromRGB(0, 255, 140), Color3.fromRGB(0, 220, 255),
    Color3.fromRGB(60, 130, 255), Color3.fromRGB(180, 80, 255),
    Color3.fromRGB(255, 70, 200), Color3.fromRGB(255, 60, 60),
    Color3.fromRGB(255, 140, 40), Color3.fromRGB(255, 230, 60),
    Color3.fromRGB(140, 255, 60), Color3.fromRGB(255, 255, 255),
    Color3.fromRGB(160, 160, 170), Color3.fromRGB(25, 25, 28),
}

mkSwatches("Color de relleno", 32, PALETTE,
    function() return CONFIG.ESP_FILL_COLOR end,
    function(c) CONFIG.ESP_FILL_COLOR = c end)
mkSwatches("Color de contorno", 68, PALETTE,
    function() return CONFIG.ESP_OUTLINE_COLOR end,
    function(c) CONFIG.ESP_OUTLINE_COLOR = c end)

mkStepper(espPage, "Transp. relleno", 104,
    function() return CONFIG.ESP_FILL_TRANSP end,
    function(v) CONFIG.ESP_FILL_TRANSP = v end, 0.05, 0, 1, "%.2f",
    function() saveConfig() end)
mkStepper(espPage, "Transp. contorno", 132,
    function() return CONFIG.ESP_OUTLINE_TRANSP end,
    function(v) CONFIG.ESP_OUTLINE_TRANSP = v end, 0.05, 0, 1, "%.2f",
    function() saveConfig() end)
mkStepper(espPage, "Dist. máxima ESP", 160,
    function() return CONFIG.ESP_MAX_DIST end,
    function(v) CONFIG.ESP_MAX_DIST = v end, 50, 50, 5000, "%d",
    function() saveConfig() end)

mkCheck(espPage, "Siempre visible (a través de paredes)", 188,
    function() return CONFIG.ESP_DEPTH_TOP end,
    function(v) CONFIG.ESP_DEPTH_TOP = v end, function() saveConfig() end)
mkCheck(espPage, "Mostrar nombres", 214,
    function() return CONFIG.ESP_SHOW_NAMES end,
    function(v) CONFIG.ESP_SHOW_NAMES = v; refreshESP(); saveConfig() end)
mkCheck(espPage, "Mostrar distancia", 240,
    function() return CONFIG.ESP_SHOW_DIST end,
    function(v) CONFIG.ESP_SHOW_DIST = v; refreshESP(); saveConfig() end)
mkCheck(espPage, "Filtrar compañeros de equipo", 266,
    function() return CONFIG.ESP_TEAM_CHECK end,
    function(v) CONFIG.ESP_TEAM_CHECK = v end, function() saveConfig() end)
mkCheck(espPage, "Color por equipo", 292,
    function() return CONFIG.ESP_TEAM_COLOR end,
    function(v) CONFIG.ESP_TEAM_COLOR = v end, function() saveConfig() end)
mkCheck(espPage, "Mostrar también los ignorados", 318,
    function() return CONFIG.ESP_INCLUDE_IGNORED end,
    function(v) CONFIG.ESP_INCLUDE_IGNORED = v end, function() saveConfig() end)

-- ---------- pestaña LISTA ----------
local listInfo = Instance.new("TextLabel")
listInfo.Size = UDim2.fromOffset(240, 16)
listInfo.Position = UDim2.fromOffset(4, 0)
listInfo.BackgroundTransparency = 1
listInfo.Font = Enum.Font.Gotham
listInfo.TextSize = 11
listInfo.TextXAlignment = Enum.TextXAlignment.Left
listInfo.TextColor3 = Color3.fromRGB(160, 160, 175)
listInfo.Text = "Click para ignorar / dejar de ignorar"
listInfo.Parent = listPage

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -8, 1, -84)
scroll.Position = UDim2.fromOffset(4, 20)
scroll.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.CanvasSize = UDim2.new()
scroll.Parent = listPage
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)
local layout = Instance.new("UIListLayout", scroll)
layout.Padding = UDim.new(0, 3)
layout.SortOrder = Enum.SortOrder.Name
layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 6)
end)

local function rebuildList()
    if not scroll.Parent then return end
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    local players = Players:GetPlayers()
    table.sort(players, function(a, b) return a.Name:lower() < b.Name:lower() end)
    local count = 0
    for _, plr in ipairs(players) do
        if plr ~= LP then
            local ig = ignored[plr.UserId] and true or false
            if ig then count = count + 1 end
            local b = mkBtn(scroll, "", 1, 22, 0, 0)
            b.Size = UDim2.new(1, -6, 0, 22)
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Text = (ig and "  [X] " or "  [ ] ") .. plr.Name
            b.BackgroundColor3 = ig and Color3.fromRGB(60, 30, 34)
                                       or Color3.fromRGB(30, 30, 34)
            b.MouseButton1Click:Connect(function()
                if ignored[plr.UserId] then
                    ignored[plr.UserId] = nil
                else
                    ignored[plr.UserId] = true
                    nameCache[plr.UserId] = plr.Name
                end
                if plr == locked and ignored[plr.UserId] then
                    release(); needRelock = true
                end
                saveConfig()
                rebuildList()
            end)
        end
    end
    listInfo.Text = ("Ignorados: %d / %d jugadores"):format(count, math.max(#players - 1, 0))
end

mkBtn(listPage, "LIMPIAR", 76, 22, 4, 376).MouseButton1Click:Connect(function()
    table.clear(ignored); saveConfig(); rebuildList()
end)
mkBtn(listPage, "IGNORAR TODOS", 104, 22, 86, 376).MouseButton1Click:Connect(function()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then ignored[plr.UserId] = true; nameCache[plr.UserId] = plr.Name end
    end
    release(); needRelock = true
    saveConfig(); rebuildList()
end)
mkBtn(listPage, "INVERTIR", 64, 22, 180, 376).MouseButton1Click:Connect(function()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            if ignored[plr.UserId] then ignored[plr.UserId] = nil
            else ignored[plr.UserId] = true; nameCache[plr.UserId] = plr.Name end
        end
    end
    saveConfig(); rebuildList()
end)

local friendsCheck = mkBtn(listPage, "  Ignorar amigos", 240, 22, 4, 348)
friendsCheck.TextXAlignment = Enum.TextXAlignment.Left
local function paintFriends()
    friendsCheck.BackgroundColor3 = CONFIG.IGNORE_FRIENDS
        and Color3.fromRGB(24, 74, 48) or Color3.fromRGB(30, 30, 34)
end
paintFriends()
friendsCheck.MouseButton1Click:Connect(function()
    CONFIG.IGNORE_FRIENDS = not CONFIG.IGNORE_FRIENDS
    paintFriends(); saveConfig()
    if locked and isIgnored(locked) then release(); needRelock = true end
end)

-- ---------- arrastre ----------
local dragging, dragStart, startPos
conn(panel.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, startPos = true, i.Position, panel.Position
    end
end))
conn(UserInputService.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
    or i.UserInputType == Enum.UserInputType.Touch) then
        panel.Position = UDim2.fromOffset(
            startPos.X.Offset + (i.Position.X - dragStart.X),
            startPos.Y.Offset + (i.Position.Y - dragStart.Y))
    end
end))
conn(UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
end))

local menuBtn = mkBtn(gui, "MENU", 64, 26, 24, 0)
menuBtn.Position = UDim2.new(0, 24, 1, -46)
menuBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
menuBtn.MouseButton1Click:Connect(function() panel.Visible = not panel.Visible end)

local mobileBtn
if CONFIG.MOBILE_BUTTON then
    mobileBtn = mkBtn(gui, "LOCK", 62, 62, 24, 24)
    mobileBtn.BackgroundColor3 = Color3.fromRGB(52, 34, 34)
    mobileBtn.TextSize = 13
    mobileBtn.MouseButton1Click:Connect(function() setEnabled(not enabled) end)
end

-- ---------- eventos de jugadores ----------
local function onPlayerAdded(plr)
    nameCache[plr.UserId] = plr.Name
    if CONFIG.ESP_ENABLED then buildESP(plr) end
    if panel.Visible and listPage.Visible then rebuildList() end
    conn(plr.CharacterAdded:Connect(function()
        if CONFIG.ESP_ENABLED then
            destroyESP(plr)
            task.wait(0.3)
            if plr.Parent then buildESP(plr) end
        end
    end))
end
for _, p in ipairs(Players:GetPlayers()) do onPlayerAdded(p) end
conn(Players.PlayerAdded:Connect(onPlayerAdded))
conn(Players.PlayerRemoving:Connect(function(p)
    destroyESP(p)
    if p == locked then release(); needRelock = CONFIG.REACQUIRE end
    if panel.Visible and listPage.Visible then rebuildList() end
end))

-- ---------- teclado ----------
conn(UserInputService.InputBegan:Connect(function(input, gp)
    if gp or unloaded then return end
    if input.KeyCode == CONFIG.KEY then
        setEnabled(not enabled)
    elseif input.KeyCode == CONFIG.PANEL_KEY then
        panel.Visible = not panel.Visible
    elseif input.KeyCode == CONFIG.UNLOAD_KEY then
        unload()
    end
end))

local function unload()
    if unloaded then return end
    unloaded = true
    pcall(function() RunService:UnbindFromRenderStep("PrensadoCamlock") end)
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)
    clearESP()
    if circle then pcall(function() circle:Remove() end) end
    if highlight then highlight:Destroy() end
    if hlFolder then hlFolder:Destroy() end
    gui:Destroy()
    getgenv().PrensadoCamlock = nil
end

getgenv().PrensadoCamlock = {
    Config = CONFIG,
    Toggle = function() setEnabled(not enabled) end,
    Enable = function() setEnabled(true) end,
    Disable = function() setEnabled(false) end,
    Relock = function() release(); needRelock = true end,
    GetTarget = function() return locked end,
    Ignore = function(x)
        local plr = type(x) == "number" and Players:GetPlayerByUserId(x)
            or (type(x) == "string" and Players:FindFirstChild(x)) or x
        if plr then ignored[plr.UserId] = true; saveConfig() end
    end,
    Unignore = function(x)
        local plr = type(x) == "number" and Players:GetPlayerByUserId(x)
            or (type(x) == "string" and Players:FindFirstChild(x)) or x
        if plr then ignored[plr.UserId] = nil; saveConfig() end
    end,
    IsIgnored = isIgnored,
    RefreshESP = refreshESP,
    Unload = unload,
}

refreshToggle()
refreshEspToggle()
showTab("AIM")
print("[Prensado] v4 cargado. Tecla: " .. CONFIG.KEY.Name)