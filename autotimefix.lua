local CFG = {
    watchdog      = true,   -- keep re-cleaning while the game is open
    interval      = 0.2,    -- seconds between watchdog passes (fast on mobile)
    verbose       = true,   -- print what it does
    resetTops     = false,  -- keep small learned tops (bounded by topBand)
    resetContest  = false,  -- keep small contest steps (bounded by contestBand)
    wipeLearned   = false,  -- keep per-animation learning, just capped
    cleanNow      = true,   -- clean the files immediately
    useJobId      = true,   -- only clear clockOffset for a DIFFERENT server
    onScreen      = true,   -- show notifications on the Roblox screen
    button        = true,   -- show the one-tap FIX TIMING button
    console       = false,  -- also print to the executor console
    duration      = 8,      -- seconds before a notification fades
    maxMessages   = 6,      -- max notifications on screen at once
    showPaths     = true,   -- show which files were found + their values
    -- two-stage filter: absurd value -> 0 once, plausible value -> clamped.
    -- Each value has an EARLY limit and a LATE limit, because only lateness is bad.
    clockReset    = 0.8,    -- clockOffset above this is garbage -> 0 once
    clockEarly    = 0.30,   -- how far the clock may go toward EARLY
    clockLate     = 0.12,   -- how far the clock may go toward LATE (positive = late)
    climbReset    = 0.12,   -- per-shot value above this is garbage -> 0 once
    climbEarly    = 0.06,   -- how far a climb may go toward EARLY
    climbLate     = 0.02,   -- how far a climb may go toward LATE (positive = late)
    topReset      = 0.12,
    topBand       = 0.04,   -- tops are kept symmetric, direction not proven
    leadReset     = 0.08,
    leadEarly     = 0.06,   -- lead positive = EARLY
    leadLate      = 0.05,   -- lead negative = LATE (magnitude)
    contestBand   = 0.5,
    bias          = 0,      -- shifts both limits: -0.05 = earlier, 0.05 = later
    autoReload    = true,   -- reload SynthHub if late drift is detected
    reloadCooldown= 300,    -- seconds between automatic reloads
    reloadCode    = "",     -- paste SynthHub's loadstring here -> FIX TIMING button
    leadOverride  = nil,    -- force leads hard. nil = auto band check
    clockOverride = nil,    -- force clockOffset hard. nil = auto band check
    topOverride   = nil,    -- force every tops entry hard. nil = 0
    extraPaths    = {},     -- extra file/folder paths for mobile, e.g. {"/sdcard/..."}
    selfTest      = true,   -- verify the write hook actually intercepts writes
    sniff         = true,   -- find files by their content, not just the filename
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

-- executors name these differently; try every common spelling
local function resolve(...)
    for i = 1, select("#", ...) do
        local n = select(i, ...)
        local f = getfn(n)
        if f then return f, n end
    end
    return nil, nil
end

local readfile,  readName  = resolve("readfile", "read_file", "readFile")
local writefile, writeName = resolve("writefile", "write_file", "writeFile")
local isfile,    isfName   = resolve("isfile", "is_file", "file_exists")
local listfiles, listName  = resolve("listfiles", "list_files", "listFiles")
local delfile              = resolve("delfile", "delete_file", "remove_file")
local HS        = game:GetService("HttpService")
local rawIO: {[string]: any} = { readfile = readfile, writefile = writefile }

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
    return not n:find("backup", 1, true) and not n:find("probe", 1, true)
        and (n:match("^autotime.*%.json$") ~= nil
        or n:match("^auto_time.*%.json$") ~= nil
        or n:match("^auto time.*%.json$") ~= nil)
end
local function isContest(n)
    return not n:find("backup", 1, true) and not n:find("probe", 1, true)
        and (n == "contest.json" or n:match("^contest.*%.json$") ~= nil)
end
local function looksAuto(t)
    return type(t) == "table" and (type(t.tops) == "table"
        or type(t.climbs) == "table" or t.clockOffset ~= nil)
end
local function looksContest(t)
    return type(t) == "table" and type(t.steps) == "table"
        and type(t.seen) == "table"
end
local function num(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function clamp(v, lo, hi)
    if not num(v) then return 0 end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
-- Clamp toward EARLY/LATE limits separately, then optionally shift the whole
-- window by `bias`. Shifting the window is idempotent, so repeated watchdog
-- passes can never accumulate into a runaway offset (that caused the bounce).
local function clampBand(v, early, late, lateIsNegative, bias)
    if not num(v) then return 0 end
    local lo, hi
    if lateIsNegative then lo, hi = -late, early else lo, hi = -early, late end
    local b = num(bias) and bias or 0
    if b ~= 0 then lo, hi = lo + b, hi + b end
    if lo > hi then lo = hi end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
local function jobId()
    local ok, j = pcall(function() return game.JobId end)
    return ok and type(j) == "string" and j or ""
end


local lateDrift, lastReload = 0, 0

local function cleanAuto(t, runtime)
    if type(t) ~= "table" then return nil, false end
    if type(t.tops) ~= "table" and type(t.climbs) ~= "table"
        and type(t.leads) ~= "table" and t.clockOffset == nil then
        return nil, false
    end
    local changed = false

    if type(t.tops) ~= "table" then t.tops = {}; changed = true end
    local tb, tr = CFG.topBand or 0.04, CFG.topReset or 0.12
    for k, v in pairs(t.tops) do
        local nv
        if CFG.topOverride ~= nil then nv = CFG.topOverride
        elseif CFG.resetTops then nv = 0
        elseif not num(v) or math.abs(v) > tr then nv = 0
        else nv = clamp(v, -tb, tb) end
        if v ~= nv then t.tops[k] = nv; changed = true end
    end

    local job = CFG.useJobId and jobId() or ""
    local ce, cl = CFG.clockEarly or 0.30, CFG.clockLate or 0.12
    local creset = CFG.clockReset or 0.8
    local function fixClock(v)
        if not num(v) or math.abs(v) > creset then return 0 end
        return clampBand(v, ce, cl, false, CFG.bias)
    end
    if CFG.clockOverride ~= nil then
        if t.clockOffset ~= CFG.clockOverride then
            t.clockOffset = CFG.clockOverride; changed = true
        end
    elseif job ~= "" and t.clockServer ~= nil and t.clockServer ~= ""
        and t.clockServer ~= job then
        -- stored offset was learned on a different server: drop it exactly once
        if t.clockOffset ~= 0 then t.clockOffset = 0; changed = true end
        t.clockServer = job; changed = true
    else
        -- remember the server so we never wipe our own learned offset again
        if job ~= "" and (t.clockServer == nil or t.clockServer == "") then
            t.clockServer = job; changed = true
        end
        if num(t.clockOffset) and t.clockOffset > cl + 0.02 then
            lateDrift = lateDrift + 1
        end
        local nv = fixClock(t.clockOffset)
        if t.clockOffset ~= nv then t.clockOffset = nv; changed = true end
    end
    if t.clockServer == nil then t.clockServer = ""; changed = true end

    if type(t.climbs) == "table" then
        if CFG.wipeLearned then
            if next(t.climbs) ~= nil then
                for k in pairs(t.climbs) do t.climbs[k] = nil end
                changed = true
            end
        else
            local ce2, cl2 = CFG.climbEarly or 0.06, CFG.climbLate or 0.02
            local cr = CFG.climbReset or 0.12
            for k, v in pairs(t.climbs) do
                if num(v) and v > cl2 + 0.01 then lateDrift = lateDrift + 1 end
                local nv
                if not num(v) or math.abs(v) > cr then nv = 0
                else nv = clampBand(v, ce2, cl2, false, CFG.bias) end
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
            local le, ll = CFG.leadEarly or 0.06, CFG.leadLate or 0.05
            local lr = CFG.leadReset or 0.08
            local nv
            if CFG.leadOverride ~= nil then nv = CFG.leadOverride
            elseif CFG.wipeLearned then nv = 0
            elseif not num(v) or math.abs(v) > lr then nv = 0
            else nv = clampBand(v, le, ll, true, CFG.bias) end
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
    local cb = CFG.contestBand or 0.5
    for k, v in pairs(t.steps) do
        local nv
        if CFG.resetContest then nv = 0
        elseif not num(v) or math.abs(v) > 1.0 then nv = 0
        else nv = clamp(v, -cb, cb) end
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
    local t = dec(data)
    if not t then return nil end
    if not auto and not contest then
        if not CFG.sniff then return nil end
        auto, contest = looksAuto(t), looksContest(t)
        if not auto and not contest then return nil end
    end
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
                    "/data/local/tmp", "/storage/emulated/0/Android/data",
                    "/sdcard/Delta", "/sdcard/Fluxus", "/sdcard/Codex",
                    "/sdcard/Arceus X", "/sdcard/Trigon", "/sdcard/Hydrogen",
                    "/storage/emulated/0/Delta", "/storage/emulated/0/Fluxus",
                    "/storage/emulated/0/Codex", "/storage/emulated/0/Arceus X",
                    "/storage/emulated/0/Documents", "/storage/emulated/0/Download" }
    if type(CFG.extraPaths) == "table" then
        for _, p in ipairs(CFG.extraPaths) do
            if type(p) == "string" and p ~= "" then
                local n = base(p)
                if n:find("%.json$") or isAuto(n) or isContest(n) then add(p)
                else roots[#roots + 1] = p end
            end
        end
    end

    local cands = {}
    if listfiles then
        local q, vis, depth = roots, {}, 0
        while #q > 0 and depth < 5 do
            local nq = {}
            for _, d in ipairs(q) do
                if not vis[d] then
                    vis[d] = true
                    local es = listdir(d)
                    if es then
                        for _, e in ipairs(es) do
                            add(e)
                            local n = base(e)
                            if n:find("%.json$") then
                                if #cands < 80 then cands[#cands + 1] = e end
                            elseif n ~= "" and not n:find("%.") then
                                nq[#nq + 1] = e
                            end
                        end
                    end
                end
            end
            q, depth = nq, depth + 1
        end
    end

    -- filename didn't match? identify it by content instead
    if CFG.sniff and readfile then
        local rf = rawIO.readfile or readfile
        for _, p in ipairs(cands) do
            local key = tostring(p):gsub("\\", "/")
            if not found[key] and not key:find("backup", 1, true)
                and not key:find("probe", 1, true) then
                local ok, data = pcall(rf, p)
                local t = ok and dec(data) or nil
                if t and (looksAuto(t) or looksContest(t)) then
                    found[key] = true
                end
            end
        end
    end
    return found
end


local warned = {}
local verified = {}
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
            warnLog("cannot write " .. base(path))
            warnLog("PC: attrib -R " .. base(path))
            warnLog("reason: " .. tostring(err))
        end
        return false
    end
    warned[path] = nil
    log("cleaned " .. path)
    if not verified[path] then
        verified[path] = true
        local vok, vdata = pcall(rf, path)
        if vok and type(vdata) == "string" and vdata ~= out then
            warnLog("save did not stick: " .. base(path))
        end
    end
    return true
end


local function installHook(name, key, factory)
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

    for _, hn in ipairs({ "hookfunction", "replaceclosure", "hookfunc",
                          "detourfunction", "replace_closure", "hook" }) do
        local hf = getfn(hn)
        if hf then
            local ok, ret = pcall(hf, orig, wrapper)
            if ok and type(ret) == "function" then
                callOrig = ret
                rawIO[key] = ret
                log(key .. " hooked via " .. hn)
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
        rawIO[key] = wrapper
        log(key .. " wrapped (no hookfunction)")
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
        local ok, data = pcall(rf, p)
        local t = ok and dec(data) or nil
        if t and looksAuto(t) then
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
                local nClimb, maxClimb, minClimb = 0, 0, 0
                if type(t.climbs) == "table" then
                    for _, v in pairs(t.climbs) do
                        if type(v) == "number" then
                            nClimb = nClimb + 1
                            if v > maxClimb then maxClimb = v end
                            if v < minClimb then minClimb = v end
                        end
                    end
                end
                log(("values: lead=%s clock=%s tops=%d/%.2f climb=%d/%.2f"):format(
                    tostring(lead), tostring(t.clockOffset),
                    nTop, maxTop, nClimb, maxClimb))
                local co = type(t.clockOffset) == "number" and t.clockOffset or 0
                local ce, cl = CFG.clockEarly or 0.30, CFG.clockLate or 0.12
                if co > 0 and co >= cl - 0.002 then
                    log("clock at LATE cap - bias = -0.05")
                elseif co < 0 and co <= -ce + 0.002 then
                    log("clock at EARLY cap - bias = 0.05")
                end
                if maxClimb > (CFG.climbReset or 0.12) then
                    warnLog(("climb stuck at %.2f"):format(maxClimb))
                    warnLog("file not writable? PC: attrib -R")
                elseif maxClimb > 0 and maxClimb >= (CFG.climbLate or 0.02) - 0.002 then
                    log("climb held at LATE cap - anti-late guard working")
                elseif minClimb < 0 and -minClimb >= (CFG.climbEarly or 0.06) - 0.002 then
                    log("climb at EARLY cap - bias = 0.05")
                end
            break
        end
    end
end

local hookOK = false
if writeName then
    hookOK = installHook(writeName, "writefile", function(call)
        return function(path, data, ...)
            local out = cleanData(path, data, true)
            return call(path, out or data, ...)
        end
    end)
end

local function selfTest()
    local function globalFn(n)
        if not n then return nil end
        local f = rawget(genv, n)
        if type(f) ~= "function" then f = rawget(_G, n) end
        return f
    end
    local rf = globalFn(readName) or rawIO.readfile or readfile
    local wf = globalFn(writeName) or rawIO.writefile or writefile
    if not rf or not wf then return false end
    local probe = "autotime_probe.json"
    if not pcall(wf, probe, '{"tops":{"Probe":9},"clockOffset":9}') then
        return nil
    end
    local ok, data = pcall(rf, probe)
    local passed = false
    if ok and type(data) == "string" then
        local t = dec(data)
        if t and type(t.tops) == "table" and t.tops.Probe == 0 then passed = true end
    end
    if delfile then pcall(delfile, probe) else pcall(wf, probe, "{}") end
    return passed
end

--=====================================================================
-- re-run SynthHub (clears the timing held INSIDE its memory)
--=====================================================================
local function reloadSynthHub(quiet)
    local code = tostring(CFG.reloadCode or "")
    if code == "" then
        if not quiet then log("files cleaned - now RE-EXECUTE SynthHub") end
        return false
    end
    local f = loadstring or load
    if not f then
        warnLog("loadstring blocked - re-execute SynthHub by hand")
        return false
    end
    local chunk, err = f(code)
    if not chunk then
        warnLog("reloadCode error: " .. tostring(err))
        return false
    end
    local ok, rerr = pcall(chunk)
    if not ok then
        warnLog("reload failed: " .. tostring(rerr))
        return false
    end
    lateDrift = 0
    lastReload = os.clock()
    log("SynthHub reloaded - timing reset")
    return true
end

--=====================================================================
-- one-tap FIX TIMING button (mobile friendly)
-- Cleans every file, then re-runs SynthHub if reloadCode is filled in.
-- This is the only way to reset the timing held INSIDE SynthHub's memory.
--=====================================================================
local function makeReloadButton()
    if CFG.onScreen == false or CFG.button == false then return end
    local ok = pcall(function()
        local parent = getGuiParent()
        if not parent then return end
        for _, v in ipairs(parent:GetChildren()) do
            if v.Name == "AutoTimeFixButton" then v:Destroy() end
        end

        local gui = Instance.new("ScreenGui")
        gui.Name = "AutoTimeFixButton"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = true
        gui.DisplayOrder = 2147483646
        gui.Parent = parent

        local btn = Instance.new("TextButton")
        btn.Name = "Fix"
        btn.AnchorPoint = Vector2.new(1, 1)
        btn.Position = UDim2.new(1, -14, 1, -14)
        btn.Size = UDim2.new(0, 132, 0, 44)
        btn.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
        btn.BackgroundTransparency = 0.1
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = true
        btn.Text = "FIX TIMING"
        btn.TextColor3 = Color3.fromRGB(120, 255, 150)
        btn.TextSize = 17
        btn.Font = Enum.Font.GothamBold
        btn.Parent = gui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = btn

        local busy = false
        btn.MouseButton1Click:Connect(function()
            if busy then return end
            busy = true
            btn.Text = "FIXING..."
            local n = 0
            for p in pairs(paths) do
                if cleanFile(p, true) then n = n + 1 end
            end
            log(("FIX TIMING: %d file(s) cleaned"):format(n))
            reloadSynthHub(false)
            task.wait(1.2)
            btn.Text = "FIX TIMING"
            busy = false
        end)
    end)
    return ok
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
    if hookOK and CFG.selfTest and CFG.sniff then
        local st = selfTest()
        if st == true then
            log("hook verified - saves are being cleaned")
        elseif st == false then
            hookOK = false
            warnLog("hook NOT verified - file watchdog only")
            warnLog("re-execute SynthHub then run this again")
        else
            log("hook installed (cannot self-test here)")
        end
    elseif not hookOK then
        log("no write hook - using file watchdog only")
    end
else
    warnLog("executor has no readfile/writefile - file fix disabled")
end

lastReload = os.clock()

if CFG.button ~= false then makeReloadButton() end

if CFG.watchdog and readfile and writefile then
    task.spawn(function()
        local tick = 0
        while true do
            for p in pairs(paths) do cleanFile(p, true) end
            if CFG.autoReload and lateDrift > 0
                and (os.clock() - lastReload) > (CFG.reloadCooldown or 300) then
                lastReload = os.clock()
                reloadSynthHub(false)
            end
            tick = tick + 1
            if tick % 25 == 0 then
                for p in pairs(discover()) do paths[p] = true end
            end
            task.wait(CFG.interval)
        end
    end)
end

log("DONE - tap FIX TIMING or RE-EXECUTE SynthHub")
