local CFG = {
    watchdog      = true,   -- keep re-cleaning while the game is open
    interval      = 1.0,    -- seconds between watchdog passes
    verbose       = true,   -- print what it does
    resetTops     = true,   -- force learned Tops to 0
    resetContest  = true,   -- force contest steps to 0
    wipeLearned   = true,   -- wipe ALL learned data (climbs/leads/seen) every save
    cleanNow      = true,   -- clean the files immediately
    useJobId      = true,   -- only clear clockOffset for a DIFFERENT server
    onScreen      = true,   -- show notifications on the Roblox screen
    console       = false,  -- also print to the executor console
    duration      = 8,      -- seconds before a notification fades
    maxMessages   = 6,      -- max notifications on screen at once
    showPaths     = true,   -- show which files were found + their values
    leadBand      = 0.06,   -- leads outside +/-this snap to 0 (drift guard)
    clockBand     = 0.5,    -- clockOffset outside +/-this snaps to 0
    climbBand     = 0.05,   -- climbs outside +/-this snap to 0 (when wipe is off)
    leadOverride  = nil,    -- force leads hard. nil = auto band check
    clockOverride = nil,    -- force clockOffset hard. nil = auto band check
    topOverride   = nil,    -- force every tops entry hard. nil = 0
    extraPaths    = {},     -- extra file/folder paths for mobile, e.g. {"/sdcard/..."}
}


local genv = _G
pcall(function()
    if type(getgenv) == "function" then
        local g = getgenv()
        if type(g) == "table" then genv = g end
    end
end)

local function getfn(n)
    local f = rawget(genv, n)
    if type(f) ~= "function" then f = rawget(_G, n) end
    return type(f) == "function" and f or nil
end

local readfile  = getfn("readfile")
local writefile = getfn("writefile")
local isfile    = getfn("isfile")
local listfiles = getfn("listfiles")
local HS        = game:GetService("HttpService")
local rawIO: {[string]: any} = {}

--=====================================================================
-- on-screen notifications (no console spam)
--=====================================================================
local notifyGui, notifyStack, notifyCount = nil, nil, 0
local activeNotes = {}

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local players = game:GetService("Players")
    local lp = players and players.LocalPlayer
    if lp then
        local ok, pg = pcall(function() return lp:WaitForChild("PlayerGui", 10) end)
        if ok and pg then return pg end
    end
    return nil
end

local function ensureNotifyGui()
    if notifyGui and notifyGui.Parent then return true end
    local ok = pcall(function()
        local parent = getGuiParent()
        if not parent then error("no gui parent") end
        for _, v in ipairs(parent:GetChildren()) do
            if v.Name == "AutoTimeFixNotify" then v:Destroy() end
        end

        local gui = Instance.new("ScreenGui")
        gui.Name = "AutoTimeFixNotify"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = false
        gui.DisplayOrder = 2147483647
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = parent

        local frame = Instance.new("Frame")
        frame.Name = "Stack"
        frame.BackgroundTransparency = 1
        frame.AnchorPoint = Vector2.new(0.5, 0)
        frame.Position = UDim2.new(0.5, 0, 0, 24)
        frame.Size = UDim2.new(0.9, 0, 0, 0)
        frame.AutomaticSize = Enum.AutomaticSize.Y
        frame.Parent = gui

        local constraint = Instance.new("UISizeConstraint")
        constraint.MaxSize = Vector2.new(520, 10000)
        constraint.Parent = frame

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 6)
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = frame

        notifyGui, notifyStack = gui, frame
    end)
    return ok and notifyGui ~= nil
end

local function showNote(text, isError)
    if not ensureNotifyGui() then
        print("[AutoTimeFix]", text)
        return
    end

    local label = Instance.new("TextLabel")
    label.Name = "Note"
    label.BackgroundColor3 = isError and Color3.fromRGB(90, 10, 10) or Color3.fromRGB(0, 0, 0)
    label.BackgroundTransparency = isError and 0.2 or 0.35
    label.BorderSizePixel = 0
    label.Size = UDim2.new(1, 0, 0, 0)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Text = text
    label.TextColor3 = isError and Color3.fromRGB(255, 150, 150) or Color3.fromRGB(255, 255, 255)
    label.TextSize = 15
    label.Font = Enum.Font.Gotham
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.LayoutOrder = notifyCount
    label.Parent = notifyStack
    notifyCount = notifyCount + 1

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingRight = UDim.new(0, 10)
    padding.Parent = label

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = label

    activeNotes[#activeNotes + 1] = label
    while #activeNotes > (CFG.maxMessages or 6) do
        local old = table.remove(activeNotes, 1)
        if old and old.Parent then old:Destroy() end
    end

    task.delay(CFG.duration or 4, function()
        if not label or not label.Parent then return end
        local ok, ts = pcall(function() return game:GetService("TweenService") end)
        if ok and ts then
            local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local tween = ts:Create(label, info, {
                TextTransparency = 1,
                BackgroundTransparency = 1,
            })
            tween:Play()
            tween.Completed:Wait()
        end
        if label and label.Parent then label:Destroy() end
    end)
end

local function flatten(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

local function log(...)
    if not CFG.verbose then return end
    local text = flatten(...)
    if CFG.console then print("[AutoTimeFix]", text) end
    if CFG.onScreen then showNote(text, false) end
end

local function warnLog(...)
    if not CFG.verbose then return end
    local text = flatten(...)
    if CFG.console then print("[AutoTimeFix]", text) end
    if CFG.onScreen then showNote(text, true) end
end
local function enc(t)
    local ok, s = pcall(function() return HS:JSONEncode(t) end)
    return ok and type(s) == "string" and s or nil
end
local function dec(s)
    local ok, t = pcall(function() return HS:JSONDecode(s) end)
    return ok and type(t) == "table" and t or nil
end
local function base(p)
    p = tostring(p):gsub("\\", "/")
    return (p:match("([^/]+)$") or p):lower()
end
local function isAuto(n)
    return not n:find("backup", 1, true)
        and (n == "autotime.json" or n:match("^autotime.%.json$") ~= nil
        or n:match("^auto_time.*%.json$") ~= nil)
end
local function isContest(n)
    return not n:find("backup", 1, true)
        and (n == "contest.json" or n:match("^contest.*%.json$") ~= nil)
end
local function num(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function clamp(v, lo, hi)
    if not num(v) then return 0 end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
local function jobId()
    local ok, j = pcall(function() return game.JobId end)
    return ok and type(j) == "string" and j or ""
end


local function cleanAuto(t, runtime)
    if type(t) ~= "table" then return nil, false end
    if type(t.tops) ~= "table" and type(t.climbs) ~= "table"
        and type(t.leads) ~= "table" and t.clockOffset == nil then
        return nil, false
    end
    local changed = false

    if type(t.tops) ~= "table" then t.tops = {}; changed = true end
    for k, v in pairs(t.tops) do
        local nv
        if CFG.topOverride ~= nil then nv = CFG.topOverride
        else nv = CFG.resetTops and 0 or clamp(v, -0.5, 0.5) end
        if v ~= nv then t.tops[k] = nv; changed = true end
    end

    local job = CFG.useJobId and jobId() or ""
    local band = CFG.clockBand or 0.5
    if CFG.clockOverride ~= nil then
        if t.clockOffset ~= CFG.clockOverride then
            t.clockOffset = CFG.clockOverride; changed = true
        end
    elseif job ~= "" then
        if t.clockServer ~= job then
            if t.clockOffset ~= 0 then t.clockOffset = 0; changed = true end
            if t.clockServer ~= nil and t.clockServer ~= "" then
                t.clockServer = ""; changed = true
            end
        else
            local off = t.clockOffset
            if not num(off) or off < -band or off > band then
                t.clockOffset = 0; changed = true
            end
        end
    else
        local off = t.clockOffset
        if off ~= nil and (not num(off) or off < -band or off > band) then
            t.clockOffset = 0; changed = true
        end
    end
    if t.clockServer == nil then t.clockServer = ""; changed = true end

    if type(t.climbs) == "table" then
        if CFG.wipeLearned then
            if next(t.climbs) ~= nil then
                for k in pairs(t.climbs) do t.climbs[k] = nil end
                changed = true
            end
        else
            local cb = CFG.climbBand or 0.05
            for k, v in pairs(t.climbs) do
                local nv = (num(v) and v >= -cb and v <= cb) and v or 0
                if v ~= nv then t.climbs[k] = nv; changed = true end
            end
        end
    end
    if CFG.wipeLearned and type(t.climbSeen) == "table"
        and next(t.climbSeen) ~= nil then
        for k in pairs(t.climbSeen) do t.climbSeen[k] = nil end
        changed = true
    end
    if type(t.leads) == "table" then
        for k, v in pairs(t.leads) do
            local lb = CFG.leadBand or 0.06
            local nv
            if CFG.leadOverride ~= nil then nv = CFG.leadOverride
            elseif CFG.wipeLearned then nv = 0
            elseif num(v) and v >= -lb and v <= lb then nv = v
            else nv = 0 end
            if v ~= nv then t.leads[k] = nv; changed = true end
        end
    end
    if CFG.wipeLearned and type(t.leadSeen) == "table"
        and next(t.leadSeen) ~= nil then
        for k in pairs(t.leadSeen) do t.leadSeen[k] = nil end
        changed = true
    end
    if CFG.wipeLearned then
        for _, key in ipairs({ "typeTops", "animTops" }) do
            local arr = t[key]
            if type(arr) == "table" and next(arr) ~= nil then
                for k in pairs(arr) do arr[k] = nil end
                changed = true
            end
        end
    end
    return t, changed
end

local function cleanContest(t)
    if type(t) ~= "table" or type(t.steps) ~= "table"
        or type(t.seen) ~= "table" then
        return nil, false
    end
    local changed = false
    for k, v in pairs(t.steps) do
        local nv = CFG.resetContest and 0 or clamp(v, -50, 50)
        if v ~= nv then t.steps[k] = nv; changed = true end
    end
    for k, v in pairs(t.seen) do
        local nv = (num(v) and v >= 0) and math.min(math.floor(v), 100000) or 0
        if v ~= nv then t.seen[k] = nv; changed = true end
    end
    return t, changed
end

local function cleanData(path, data, runtime)
    if type(data) ~= "string" or #data == 0 then return nil end
    local n = base(path)
    local auto, contest = isAuto(n), isContest(n)
    if not auto and not contest then return nil end
    local t = dec(data)
    if not t then return nil end
    local changed
    if auto then _, changed = cleanAuto(t, runtime)
    else _, changed = cleanContest(t) end
    if not changed then return nil end
    return enc(t)
end


local function exists(p)
    if isfile then
        local ok, v = pcall(isfile, p)
        if ok then return v == true end
    end
    if readfile then return (pcall(readfile, p)) end
    return false
end

local function listdir(d)
    if not listfiles then return nil end
    local ok, v = pcall(listfiles, d)
    return ok and type(v) == "table" and v or nil
end

local function discover()
    local found, seen = {}, {}
    local function add(p)
        if type(p) ~= "string" or p == "" then return end
        p = p:gsub("\\", "/")
        if seen[p] then return end
        seen[p] = true
        local n = base(p)
        if (isAuto(n) or isContest(n)) and exists(p) then found[p] = true end
    end

    local hints = {
        "SynthHubPracticalBasketball/autotime.json",
        "SynthHubPracticalBasketball/contest.json",
        "workspace/SynthHubPracticalBasketball/autotime.json",
        "workspace/SynthHubPracticalBasketball/contest.json",
        "/storage/emulated/0/SynthHubPracticalBasketball/autotime.json",
        "/storage/emulated/0/SynthHubPracticalBasketball/contest.json",
        "/sdcard/SynthHubPracticalBasketball/autotime.json",
        "/sdcard/SynthHubPracticalBasketball/contest.json",
        "autotime.json", "contest.json",
    }
    for _, p in ipairs(hints) do add(p) end

    local roots = { "", ".", "workspace", "/sdcard", "/storage/emulated/0",
                    "/data/local/tmp", "/storage/emulated/0/Android/data" }
    if type(CFG.extraPaths) == "table" then
        for _, p in ipairs(CFG.extraPaths) do
            if type(p) == "string" and p ~= "" then
                local n = base(p)
                if isAuto(n) or isContest(n) then add(p) else roots[#roots + 1] = p end
            end
        end
    end

    if listfiles then
        local q, vis, depth = roots, {}, 0
        while #q > 0 and depth < 4 do
            local nq = {}
            for _, d in ipairs(q) do
                if not vis[d] then
                    vis[d] = true
                    local es = listdir(d)
                    if es then
                        for _, e in ipairs(es) do
                            add(e)
                            local n = base(e)
                            if n ~= "" and not n:find("%.") then nq[#nq + 1] = e end
                        end
                    end
                end
            end
            q, depth = nq, depth + 1
        end
    end
    return found
end


local warned = {}
local function cleanFile(path, runtime)
    local rf = rawIO.readfile or readfile
    local wf = rawIO.writefile or writefile
    if not rf or not wf then return false end
    local ok, data = pcall(rf, path)
    if not ok or type(data) ~= "string" then return false end
    local out = cleanData(path, data, runtime)
    if not out then return false end
    local wok, err = pcall(wf, path, out)
    if not wok then
        if not warned[path] then
            warned[path] = true
            warnLog("cannot write " .. path .. " (read-only?) - unlock it and rerun")
            warnLog("reason: " .. tostring(err))
        end
        return false
    end
    warned[path] = nil
    log("cleaned " .. path)
    return true
end


local function installHook(name, factory)
    local orig = getfn(name)
    if not orig then return false end
    local callOrig, active = orig, {}
    local function call(...)
        local co = coroutine.running() or "main"
        if active[co] then return nil end
        active[co] = true
        local r = table.pack(pcall(callOrig, ...))
        active[co] = nil
        if not r[1] then error(r[2], 0) end
        return table.unpack(r, 2, r.n)
    end
    local wrapper = factory(call)

    for _, hn in ipairs({ "hookfunction", "replaceclosure" }) do
        local hf = getfn(hn)
        if hf then
            local ok, ret = pcall(hf, orig, wrapper)
            if ok and type(ret) == "function" then
                callOrig = ret
                rawIO[name] = ret
                log(name .. " hooked via " .. hn)
                return true
            end
        end
    end

    local function assign(tbl)
        if type(tbl) ~= "table" then return false end
        local ok = pcall(function() tbl[name] = wrapper end)
        return ok and rawget(tbl, name) == wrapper
    end
    if assign(genv) or assign(_G) then
        rawIO[name] = wrapper
        log(name .. " wrapped")
        return true
    end
    log("could not hook " .. name)
    return false
end


local paths = discover()

local function reportPaths()
    local list = {}
    for p in pairs(paths) do list[#list + 1] = p end
    table.sort(list)
    if #list == 0 then
        warnLog("0 files found. put your folder in extraPaths (top of script)")
        return
    end
    for i = 1, math.min(#list, 4) do log("file: " .. list[i]) end
    if #list > 4 then log(("... +%d more"):format(#list - 4)) end
end

local function reportValues()
    local rf = rawIO.readfile or readfile
    if not rf then return end
    for p in pairs(paths) do
        if isAuto(base(p)) then
            local ok, data = pcall(rf, p)
            local t = ok and dec(data) or nil
            if t then
                local nTop, maxTop = 0, 0
                if type(t.tops) == "table" then
                    for _, v in pairs(t.tops) do
                        if type(v) == "number" and v ~= 0 then
                            nTop = nTop + 1
                            if math.abs(v) > maxTop then maxTop = math.abs(v) end
                        end
                    end
                end
                local lead = t.leads and t.leads.jumper
                local nClimb, maxClimb = 0, 0
                if type(t.climbs) == "table" then
                    for _, v in pairs(t.climbs) do
                        if type(v) == "number" then
                            nClimb = nClimb + 1
                            if math.abs(v) > maxClimb then maxClimb = math.abs(v) end
                        end
                    end
                end
                log(("values: lead=%s clock=%s tops=%d climb=%d/%.2f"):format(
                    tostring(lead), tostring(t.clockOffset), nTop, nClimb, maxClimb))
            end
            break
        end
    end
end

if readfile and writefile then
    if CFG.cleanNow then
        local found, cleaned = 0, 0
        for p in pairs(paths) do
            found = found + 1
            if cleanFile(p, false) then cleaned = cleaned + 1 end
        end
        log(("startup: %d file(s) found, %d cleaned"):format(found, cleaned))
    end
    if CFG.showPaths then
        reportPaths()
        reportValues()
    end
else
    warnLog("executor has no readfile/writefile - file fix disabled")
end

installHook("writefile", function(call)
    return function(path, data, ...)
        local out = cleanData(path, data, true)
        return call(path, out or data, ...)
    end
end)

if CFG.watchdog and readfile and writefile then
    task.spawn(function()
        local tick = 0
        while true do
            for p in pairs(paths) do cleanFile(p, true) end
            tick = tick + 1
            if tick % 10 == 0 then
                for p in pairs(discover()) do paths[p] = true end
            end
            task.wait(CFG.interval)
        end
    end)
end

log("active - re-execute SynthHub so it loads the cleaned state")