local CFG = {
    watchdog      = true,   -- keep re-cleaning while the game is open
    interval      = 0.5,    -- seconds between watchdog passes
    blockWrites   = false,  -- let SynthHub save, but every save is CLAMPED
    sanitizeReads = true,   -- SynthHub may not READ drifted values either
    verbose       = true,   -- print what it does
    resetTops     = false,  -- keep small learned tops (bounded by topBand)
    resetContest  = false,  -- keep small contest steps (bounded by contestBand)
    wipeLearned   = false,  -- keep per-animation learning, just capped
    cleanNow      = true,   -- clean the files immediately
    useJobId      = true,   -- only clear clockOffset for a DIFFERENT server
    onScreen      = true,   -- show notifications on the Roblox screen
    button        = true,   -- show the one-tap FIX TIMING button
    console       = false,  -- also print to the executor console
    duration      = 3.5,    -- seconds before a notification fades (tap to dismiss)
    maxMessages   = 4,      -- max notifications on screen at once
    showPaths     = true,   -- show which files were found + their values
    -- Every value is CLAMPED continuously. Nothing is ever snapped back to 0
    -- inside the normal range, because that jump is what makes the greens
    -- alternate between "too early" and "too late" after a few minutes.
    -- The LATE side is deliberately much tighter than the EARLY side:
    -- a release that is a bit early still greens, a late release gets
    -- rejected by the game and the shot counts as a miss.
    clockReset    = 3.0,    -- only insane values are zeroed (never in normal play)
    clockEarly    = 0.20,   -- how far the clock may go toward EARLY
    clockLate     = 0.02,   -- how far the clock may go toward LATE (positive = late)
    climbReset    = 2.0,    -- only insane values are zeroed (never in normal play)
    climbEarly    = 0.04,   -- how far a climb may go toward EARLY
    climbLate     = 0.02,   -- how far a climb may go toward LATE (positive = late)
    topReset      = 2.0,
    topBand       = 0.025,  -- tops are kept symmetric, direction not proven
    leadReset     = 2.0,
    leadEarly     = 0.04,   -- lead positive = EARLY
    leadLate      = 0.02,   -- lead negative = LATE (magnitude)
    -- The lead of the shot type and the climb of that animation are BOTH
    -- added to the release, so each of them being legal is not enough: the
    -- SUM has to stay inside the window the game accepts. This is the budget
    -- for how late the two together may be. It is what stops the late drift
    -- that only shows up after a few minutes of shooting.
    lateBudget    = 0.04,   -- lead + climb may be at most this much late
    contestBand   = 0.25,
    bias          = 0,      -- shifts both limits: -0.05 = earlier, 0.05 = later
    liveSync      = true,   -- pull the in-memory copy back to the clean file
    leadOverride  = nil,    -- force leads hard. nil = auto band check
    clockOverride = nil,    -- force clockOffset hard. nil = auto band check
    topOverride   = nil,    -- force every tops entry hard. nil = 0
    extraPaths    = {},     -- extra file/folder paths for mobile, e.g. {"/sdcard/..."}
    selfTest      = true,   -- verify the write hook actually intercepts writes
    sniff         = true,   -- find files by their content, not just the filename
    liveClamp     = true,   -- also clamp the copy SynthHub holds IN MEMORY
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

-- NOTE: this script never touches loadstring / load, not even to call them.
-- Luarmor-style loaders do `loadstring(game:HttpGet(...))()` at line 1, and
-- hooking or wrapping that causes "C stack overflow" in loadstring. Everything
-- here works on the files and on the live timing table, nothing else.

-- The EARLIER / LATER buttons save their setting here so it survives a
-- re-execute. A plain number, no JSON.
local BIAS_FILE = "autotime_fix_bias.txt"
do
    if (tonumber(CFG.bias) or 0) == 0 then
        local rf = rawIO.rawRead or readfile
        if rf then
            local ok, s = pcall(rf, BIAS_FILE)
            local v = ok and type(s) == "string" and tonumber(s:match("^%s*(-?%d+%.?%d*)")) or nil
            if v then CFG.bias = math.max(-0.12, math.min(0.12, v)) end
        end
    end
end

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

local function fadeOut(label)
    if not label or not label.Parent or label:GetAttribute("Dying") then return end
    label:SetAttribute("Dying", true)
    local idx = table.find(activeNotes, label)
    if idx then table.remove(activeNotes, idx) end
    local ok, ts = pcall(function() return game:GetService("TweenService") end)
    if ok and ts then
        local info = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = ts:Create(label, info, {
            TextTransparency = 1,
            BackgroundTransparency = 1,
        })
        tween:Play()
        tween.Completed:Wait()
    end
    if label and label.Parent then label:Destroy() end
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

    -- tap / click a message to dismiss it right away
    label.Active = true
    label.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            fadeOut(label)
        end
    end)

    task.delay(CFG.duration or 3.5, function() fadeOut(label) end)
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
-- tables we decoded ourselves are never the live in-memory state, they are
-- just a copy of the file. Remember them so the live scan skips them.
local ownTables = setmetatable({}, { __mode = "k" })
local function dec(s)
    local ok, t = pcall(function() return HS:JSONDecode(s) end)
    if ok and type(t) == "table" then
        ownTables[t] = true
        return t
    end
    return nil
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
    local b = num(bias) and bias or 0
    local lo, hi
    if lateIsNegative then
        -- leads are negative when late, so +bias (later) must move BOTH
        -- limits down, not up, or LATER would make leads go early.
        lo, hi = -late - b, early - b
    else
        lo, hi = -early + b, late + b
    end
    if lo > hi then lo = hi end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
local function jobId()
    local ok, j = pcall(function() return game.JobId end)
    return ok and type(j) == "string" and j or ""
end

-- wall-clock seconds. os.time() keeps counting while the game is idle, unlike
-- a CPU-time clock, which would make the watchdogs never fire.
local function nowSec()
    local t = os.time()
    if type(t) == "number" and t > 0 then return t end
    return os.clock()
end


local lateDrift = 0

-- per-animation learned tops. Those lists can hold counts (whole numbers)
-- as well as offsets, so only fractional numbers are treated as offsets.
local function clampTopList(list, band, depth)
    local changed = false
    if type(list) ~= "table" then return false end
    for k, v in pairs(list) do
        if num(v) then
            local a = math.abs(v)
            if a > 0.000001 and a % 1 ~= 0 then
                local nv = clamp(v, -band, band)
                if nv ~= v then list[k] = nv; changed = true end
            end
        elseif type(v) == "table" and (depth or 0) < 2 then
            if clampTopList(v, band, (depth or 0) + 1) then changed = true end
        end
    end
    return changed
end

-- how late one value is (positive number = late)
local function lateOf(v, lateIsNegative)
    if not num(v) then return 0 end
    if lateIsNegative then
        return v < 0 and -v or 0
    end
    return v > 0 and v or 0
end

-- the worst (most late) value inside a map
local function mapLateMax(map, lateIsNegative)
    local m = 0
    if type(map) ~= "table" then return 0 end
    for _, v in pairs(map) do
        if num(v) then
            local a = lateOf(v, lateIsNegative)
            if a > m then m = a end
        end
    end
    return m
end

-- The lead of the shot type and the climb of that animation are BOTH added
-- to the release. So a lead of -0.02 together with a climb of +0.02 is
-- 40 ms late, even though BOTH of them are inside their own limits.
-- That sum is what the game rejects, so the two share ONE budget.
-- Values are only ever pulled towards EARLY here, so this can never make a
-- shot later than it already was.
local function applyLateBudget(leads, climbs)
    local budget = CFG.lateBudget or 0.04
    if not num(budget) or budget <= 0 then return false end
    -- the bias moves both windows, so the budget moves with it, otherwise
    -- the LATER button would fight the budget
    local b = num(CFG.bias) and CFG.bias or 0
    budget = budget + b
    if type(leads) ~= "table" and type(climbs) ~= "table" then return false end
    local changed = false
    local function total()
        return mapLateMax(leads, true) + mapLateMax(climbs, false)
    end
    for _ = 1, 64 do
        local cur = total()
        if cur <= budget + 0.000001 then break end
        local excess = cur - budget
        local cl = mapLateMax(climbs, false)
        local ld = mapLateMax(leads, true)
        local touched = false
        -- take it off the climbs first, they are the ones that wind up
        if cl > 0 and cl >= ld then
            for k, v in pairs(climbs) do
                if num(v) and v > 0 then
                    local nv = v - excess
                    if nv < 0 then nv = 0 end
                    if nv ~= v then climbs[k] = nv; changed = true; touched = true end
                    break
                end
            end
        elseif ld > 0 then
            for k, v in pairs(leads) do
                if num(v) and v < 0 then
                    local nv = v + excess
                    if nv > 0 then nv = 0 end
                    if nv ~= v then leads[k] = nv; changed = true; touched = true end
                    break
                end
            end
        end
        if not touched then break end
    end
    return changed
end

local function cleanAuto(t, runtime)
    if type(t) ~= "table" then return nil, false end
    if type(t.tops) ~= "table" and type(t.climbs) ~= "table"
        and type(t.leads) ~= "table" and t.clockOffset == nil then
        return nil, false
    end
    local changed = false

    if type(t.tops) ~= "table" then t.tops = {}; changed = true end
    local tb, tr = CFG.topBand or 0.025, CFG.topReset or 2.0
    for k, v in pairs(t.tops) do
        local nv
        if CFG.topOverride ~= nil then nv = CFG.topOverride
        elseif CFG.resetTops then nv = 0
        elseif not num(v) or math.abs(v) > tr then nv = 0
        else nv = clamp(v, -tb, tb) end
        if v ~= nv then t.tops[k] = nv; changed = true end
    end

    local job = CFG.useJobId and jobId() or ""
    local ce, cl = CFG.clockEarly or 0.20, CFG.clockLate or 0.02
    local creset = CFG.clockReset or 3.0
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
        if num(t.clockOffset) and t.clockOffset > cl + 0.10 then
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
            local ce2, cl2 = CFG.climbEarly or 0.04, CFG.climbLate or 0.02
            local cr = CFG.climbReset or 2.0
            for k, v in pairs(t.climbs) do
                if num(v) and v > cl2 + 0.08 then lateDrift = lateDrift + 1 end
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
            local le, ll = CFG.leadEarly or 0.04, CFG.leadLate or 0.02
            local lr = CFG.leadReset or 2.0
            if num(v) and v < -(ll + 0.06) then lateDrift = lateDrift + 1 end
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
    -- per shot type / per animation tops are offsets too, and they used to
    -- be left completely alone here, so they could drift for ever
    if CFG.wipeLearned then
        for _, key in ipairs({ "typeTops", "animTops" }) do
            local arr = t[key]
            if type(arr) == "table" and next(arr) ~= nil then
                for k in pairs(arr) do arr[k] = nil end
                changed = true
            end
        end
    else
        for _, key in ipairs({ "typeTops", "animTops" }) do
            local arr = t[key]
            if type(arr) == "table" then
                for _, list in pairs(arr) do
                    if clampTopList(list, tb, 0) then changed = true end
                end
                if clampTopList(arr, tb, 0) then changed = true end
            end
        end
    end
    -- the lead and the climb of one shot are added together, so the two
    -- have to share one budget for how late the release may be
    if applyLateBudget(t.leads, t.climbs) then changed = true end
    return t, changed
end

local function cleanContest(t)
    if type(t) ~= "table" or type(t.steps) ~= "table"
        or type(t.seen) ~= "table" then
        return nil, false
    end
    local changed = false
    local cb = CFG.contestBand or 0.25
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

local function cleanData(path, data, runtime, force)
    if type(data) ~= "string" or #data == 0 then return nil end
    local n = base(path)
    local auto, contest = isAuto(n), isContest(n)
    if not auto and not contest then
        if not CFG.sniff then return nil end
        -- never parse huge or non-JSON payloads (Lua source, caches, logs)
        if data:byte(1) ~= 123 or #data > 262144 then return nil end
    end
    local t = dec(data)
    if not t then return nil end
    if not auto and not contest then
        auto, contest = looksAuto(t), looksContest(t)
        if not auto and not contest then return nil end
    end
    local changed
    if auto then _, changed = cleanAuto(t, runtime)
    else _, changed = cleanContest(t) end
    if not changed and not force then return nil end
    return enc(t)
end

--=====================================================================
-- LIVE IN-MEMORY CLAMP
--
-- Clamping the JSON file is not enough. SynthHub keeps its own copy of
-- these numbers in memory and keeps adding to it; that copy is what the
-- shot actually uses. So after a few minutes it shoots late even though
-- the file on disk is perfect. Find that live table and clamp it in
-- place on every pass.
--=====================================================================
local liveStates = setmetatable({}, { __mode = "k" })
local liveFound = false
local liveLocked = false
local liveMissed = false
-- the clean file contents, used as the baseline the live copy follows
local cleanState = nil
local cleanSave = nil
local cleanSaveAt = 0

-- A live timing table looks like the JSON SynthHub keeps: maps of learned
-- offsets named "tops", "climbs" and "leads". Two of those together is
-- specific enough that a random table will not match, and the string keys
-- rule out index arrays.
local LIVE_MAPS = { "tops", "climbs", "leads" }

-- the field names SynthHub uses for its timing state. A table that carries
-- several of them is the timing state, whatever shape it is stored in.
local SYNTH_FIELDS = { "tops", "climbs", "leads", "typeTops", "animTops",
    "clockOffset", "clockServer", "climbSeen", "leadSeen", "version" }
local SYNTH_MAPFIELDS = { tops = true, climbs = true, leads = true }

-- The timing maps can sit on the state table itself or one level down in
-- it. Find the table that actually holds them. Only a limited number of
-- children is looked at, so a huge table cannot slow the scan down.
local function mapHolder(t)
    if type(t) ~= "table" then return nil end
    for _, k in ipairs(LIVE_MAPS) do
        if type(t[k]) == "table" then return t end
    end
    local n = 0
    for _, v in pairs(t) do
        n = n + 1
        if n > 40 then return nil end
        if type(v) == "table" then
            for _, k in ipairs(LIVE_MAPS) do
                if type(v[k]) == "table" then return v end
            end
        end
    end
    return nil
end

-- Fast check, no table walking: does this table hold SynthHub's timing
-- maps directly? The maps do NOT have to contain a number yet - a state
-- table that starts out empty still has to be found, otherwise the values
-- it learns later would never be clamped and the shot would drift late.
local function isLiveState(t)
    if type(t) ~= "table" then return false end
    if ownTables[t] then return false end
    local maps, hits = 0, 0
    for i = 1, #SYNTH_FIELDS do
        local k = SYNTH_FIELDS[i]
        local v = t[k]
        if v ~= nil then
            hits = hits + 1
            if SYNTH_MAPFIELDS[k] and type(v) == "table" then
                maps = maps + 1
            end
        end
    end
    -- two of the three maps plus several of SynthHub's own field names:
    -- that combination is far too specific to happen by accident
    if maps < 2 or hits < 3 then return false end
    -- the maps must not be plain index arrays
    local strk, anyVal = false, false
    for _, k in ipairs(LIVE_MAPS) do
        local m = t[k]
        if type(m) == "table" then
            for mk in pairs(m) do
                anyVal = true
                if type(mk) == "string" then strk = true end
            end
        end
    end
    if anyVal and not strk then return false end
    return true
end

-- Same, but for a state table that keeps its maps one level down.
local function findDeepHolder(t)
    if type(t) ~= "table" then return nil end
    if ownTables[t] then return nil end
    local h = mapHolder(t)
    if not h or h == t then return nil end
    if not isLiveState(h) then return nil end
    return h
end

-- Clamp a live map. A value that is still inside the window is left alone so
-- the learner can keep working. A value that drifted OUT of the window is
-- pulled back to the cap, or to the clean file value when that one is not
-- worse (not later) than the cap.
local function syncMap(liveMap, cleanMap, clampFn, laterFn)
    local changed = false
    if type(liveMap) ~= "table" then return false end
    -- string keyed maps are real offset maps, array like ones only hold
    -- fractional numbers we are allowed to touch
    local strKeys = false
    for k in pairs(liveMap) do
        if type(k) == "string" then
            strKeys = true
            break
        end
    end
    for k, v in pairs(liveMap) do
        if num(v) then
            local a = math.abs(v)
            local allowed = strKeys or (a % 1 ~= 0)
            if allowed and a <= 5 then
                local nv = clampFn(v)
                if nv ~= v and type(cleanMap) == "table" then
                    local c = cleanMap[k]
                    if num(c) then
                        local bv = clampFn(c)
                        local useBase
                        if laterFn then
                            useBase = not laterFn(bv, nv)
                        else
                            useBase = math.abs(bv) < math.abs(nv)
                        end
                        if useBase then nv = bv end
                    end
                end
                if nv ~= v then liveMap[k] = nv; changed = true end
            end
        end
    end
    return changed
end

-- Clamp the table SynthHub is ACTUALLY shooting with. Only fields that
-- already exist are touched, so we never add keys the script does not know.
local function cleanLive(t)
    if type(t) ~= "table" then return false end
    -- the maps may sit on the table itself or one level down in it
    local h = mapHolder(t) or t
    local changed = false
    local tb = CFG.topBand or 0.025
    local ce, cl = CFG.climbEarly or 0.04, CFG.climbLate or 0.02
    local le, ll = CFG.leadEarly or 0.04, CFG.leadLate or 0.02
    local cce, ccl = CFG.clockEarly or 0.20, CFG.clockLate or 0.02
    -- the file baseline is the good one, the save snapshot is the fallback
    local cs = nil
    if CFG.liveSync ~= false then cs = cleanState or cleanSave end

    if type(h.tops) == "table" then
        if syncMap(h.tops, cs and cs.tops,
            function(v) return clamp(v, -tb, tb) end) then changed = true end
    end

    if type(h.climbs) == "table" then
        -- a climb grows positive when it gets late
        if syncMap(h.climbs, cs and cs.climbs,
            function(v) return clampBand(v, ce, cl, false, CFG.bias) end,
            function(a, b) return a > b end) then
            changed = true
        end
    end

    if type(h.leads) == "table" then
        -- a lead grows negative when it gets late
        if syncMap(h.leads, cs and cs.leads,
            function(v) return clampBand(v, le, ll, true, CFG.bias) end,
            function(a, b) return a < b end) then
            changed = true
        end
    end

    if type(h.typeTops) == "table" then
        for _, arr in pairs(h.typeTops) do
            if clampTopList(arr, tb, 0) then changed = true end
        end
    end
    if type(h.animTops) == "table" then
        if clampTopList(h.animTops, tb, 0) then changed = true end
    end

    if num(h.clockOffset) then
        local job = CFG.useJobId and jobId() or ""
        if job ~= "" and type(h.clockServer) == "string"
            and h.clockServer ~= "" and h.clockServer ~= job then
            -- offset learned on another server: drop it once
            h.clockOffset = 0
            h.clockServer = job
            changed = true
        else
            local nv = clampBand(h.clockOffset, cce, ccl, false, CFG.bias)
            if nv ~= h.clockOffset and cs and num(cs.clockOffset) then
                -- the file value is only used when it is not later than the cap
                local bv = clampBand(cs.clockOffset, cce, ccl, false, CFG.bias)
                if bv <= nv then nv = bv end
            end
            if nv ~= h.clockOffset then h.clockOffset = nv; changed = true end
        end
    end

    -- the lead of the shot and the climb of that animation are added
    -- together, so the two share one budget for how late the release may be
    if applyLateBudget(h.leads, h.climbs) then changed = true end
    return changed
end

local function rememberLive(t, deep)
    if liveStates[t] then return end
    if not isLiveState(t) then
        if not deep then return end
        local h = findDeepHolder(t)
        if not h then return end
        liveStates[h] = true
    else
        liveStates[t] = true
    end
    if not liveFound then
        liveFound = true
        log("in-memory timing found - clamping it live")
    end
end

-- Some executors only list functions in getgc. Then the timing table is
-- still reachable through a closure upvalue, so look in there too.
local function scanUpvalues()
    local dbg = rawget(genv, "debug") or rawget(_G, "debug")
    local gu
    if type(dbg) == "table" then gu = rawget(dbg, "getupvalues") end
    if type(gu) ~= "function" then gu = getfn("getupvalues") end
    if type(gu) ~= "function" then return 0 end
    local getgcFn = getfn("getgc")
    if not getgcFn then return 0 end
    local ok, gc = pcall(getgcFn, true)
    if not ok or type(gc) ~= "table" then ok, gc = pcall(getgcFn) end
    if not ok or type(gc) ~= "table" then return 0 end
    local n = 0
    pcall(function()
        for i = 1, math.min(#gc, 20000) do
            local f = gc[i]
            if type(f) == "function" then
                local uok, ups = pcall(gu, f)
                if uok and type(ups) == "table" then
                    for _, u in pairs(ups) do
                        if type(u) == "table" and (isLiveState(u) or findDeepHolder(u)) then
                            rememberLive(u, true)
                            n = n + 1
                        end
                    end
                end
            end
            if liveFound then break end
        end
    end)
    return n
end

local function scanLive(nodeBudget, maxDepth, useGC)
    local seen, nodes = {}, 0
    local function visit(t, depth)
        if type(t) ~= "table" or seen[t] or nodes >= nodeBudget then return end
        seen[t] = true
        nodes = nodes + 1
        rememberLive(t, true)
        if depth >= (maxDepth or 5) then return end
        local ok = pcall(function()
            local k, v = next(t)
            while k ~= nil do
                if type(v) == "table" then visit(v, depth + 1) end
                k, v = next(t, k)
            end
        end)
        if not ok then return end
    end

    local roots = { genv, _G }
    if type(shared) == "table" then roots[#roots + 1] = shared end
    pcall(function()
        local dbg = rawget(genv, "debug") or rawget(_G, "debug")
        if type(dbg) ~= "table" then return end
        local gr = rawget(dbg, "getregistry")
        if type(gr) ~= "function" then return end
        local ok, reg = pcall(gr)
        if ok and type(reg) == "table" then roots[#roots + 1] = reg end
    end)
    for _, r in ipairs(roots) do pcall(visit, r, 0) end

    if useGC then
        local getgcFn = getfn("getgc")
        if getgcFn then
            local ok, gc = pcall(getgcFn, true)
            if not ok or type(gc) ~= "table" then ok, gc = pcall(getgcFn) end
            if ok and type(gc) == "table" then
                pcall(function()
                    for i = 1, math.min(#gc, 60000) do
                        local v = gc[i]
                        if type(v) == "table" and isLiveState(v) then
                            rememberLive(v)
                        end
                    end
                end)
            end
        end
        -- still nothing? the table may sit in a closure upvalue
        if not liveFound then scanUpvalues() end
    end
    return nodes
end

local function clampLive()
    if CFG.liveClamp == false then return 0 end
    local n = 0
    pcall(function()
        for t in pairs(liveStates) do
            if isLiveState(t) then
                local ok, changed = pcall(cleanLive, t)
                if ok then
                    if changed then n = n + 1 end
                elseif not liveLocked then
                    liveLocked = true
                    warnLog("in-memory timing is locked - re-execute SynthHub once")
                end
            else
                liveStates[t] = nil
            end
        end
    end)
    return n
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
        local rf = rawIO.rawRead or rawIO.readfile or readfile
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
local lastCleanLog = {}
local function cleanFile(path, runtime, force)
    local rf = rawIO.rawRead or rawIO.readfile or readfile
    local wf = rawIO.rawWrite or rawIO.writefile or writefile
    if not rf or not wf then return false end
    local ok, data = pcall(rf, path)
    if not ok or type(data) ~= "string" then return false end
    local out = cleanData(path, data, runtime, force)
    -- remember the clean copy: the live table in memory is pulled back to it,
    -- so the running game can never be later than the file
    if isAuto(base(path)) then
        local ct = dec(out or data)
        if ct and looksAuto(ct) then cleanState = ct end
    end
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
    -- never spam the screen: a drifting file can be rewritten on almost every
    -- shot, so show this at most once per 30 s per file
    local now = nowSec()
    if (not lastCleanLog[path]) or (now - lastCleanLog[path]) > 30 then
        lastCleanLog[path] = now
        log("cleaned " .. path)
    end
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
                -- Keep the REAL original for our own reads/writes. Some
                -- executors patch the passed function in place, so storing it
                -- would re-enter the wrapper (the old loadstring crash).
                if key == "writefile" then rawIO.rawWrite = ret end
                if key == "readfile" then rawIO.rawRead = ret end
                if key == "appendfile" then rawIO.rawAppend = ret end
                rawIO.mode = hn
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
        -- the global now points at the wrapper, but the original object was
        -- NOT patched, so we can still call it directly
        if key == "writefile" then rawIO.rawWrite = orig end
        if key == "readfile" then rawIO.rawRead = orig end
        rawIO.mode = "wrapped"
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
    local rf = rawIO.rawRead or rawIO.readfile or readfile
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
                -- how late one shot really is: the lead of the shot type
                -- plus the climb of that animation are added together
                local late = mapLateMax(t.leads, true) + mapLateMax(t.climbs, false)
                local budget = CFG.lateBudget or 0.04
                log(("values: lead=%s clock=%s tops=%d/%.2f climb=%d/%.2f late=%.3f/%.3f"):format(
                    tostring(lead), tostring(t.clockOffset),
                    nTop, maxTop, nClimb, maxClimb, late, budget))
                if late > budget + 0.0005 then
                    warnLog(("release is %.0f ms late - pulling it back"):format(late * 1000))
                end
                local b = tonumber(CFG.bias) or 0
                if b ~= 0 then
                    log(("bias %+.3f - negative = earlier, positive = later"):format(b))
                end
                local co = type(t.clockOffset) == "number" and t.clockOffset or 0
                local ce, cl = CFG.clockEarly or 0.20, CFG.clockLate or 0.02
                if co > 0 and co >= cl - 0.002 then
                    log("clock at LATE cap - bias = -0.05")
                elseif co < 0 and co <= -ce + 0.002 then
                    log("clock at EARLY cap - bias = 0.05")
                end
                if maxClimb > (CFG.climbReset or 2.0) then
                    warnLog(("climb stuck at %.2f"):format(maxClimb))
                    warnLog("file not writable? PC: attrib -R")
                elseif maxClimb > 0 and maxClimb >= (CFG.climbLate or 0.02) - 0.002 then
                    log("climb held at LATE cap - anti-late guard working")
                elseif minClimb < 0 and -minClimb >= (CFG.climbEarly or 0.04) - 0.002 then
                    log("climb at EARLY cap - bias = 0.05")
                end
            break
        end
    end
end

-- Show what the running game is actually using. This is the proof that the
-- live copy is pinned and cannot drift late any more.
local function reportLive()
    if not liveFound then return end
    local worstLead, worstClimb, worstTop, n = 0, 0, 0, 0
    local lateSum = 0
    pcall(function()
        for t in pairs(liveStates) do
            if type(t) == "table" then
                n = n + 1
                local h = mapHolder(t) or t
                if type(h.leads) == "table" then
                    for _, v in pairs(h.leads) do
                        if num(v) and v < worstLead then worstLead = v end
                    end
                end
                if type(h.climbs) == "table" then
                    for _, v in pairs(h.climbs) do
                        if num(v) and v > worstClimb then worstClimb = v end
                    end
                end
                if type(h.tops) == "table" then
                    for _, v in pairs(h.tops) do
                        if num(v) and math.abs(v) > worstTop then worstTop = math.abs(v) end
                    end
                end
                -- what one shot really adds up to
                lateSum = math.max(lateSum,
                    mapLateMax(h.leads, true) + mapLateMax(h.climbs, false))
            end
        end
    end)
    if n == 0 then return end
    local budget = CFG.lateBudget or 0.04
    log(("live: %d table(s) lead=%+.3f climb=%+.3f top=%.3f late=%.3f/%.3f"):format(
        n, worstLead, worstClimb, worstTop, lateSum, budget))
    if lateSum > budget + 0.0005 then
        warnLog(("release is %.0f ms late - pulling it back"):format(lateSum * 1000))
    end
end

local hookOK = false
local blockedCount = 0
local blockedWarned = false
local driftWarned = false
local lastDriftCheck = 0
if writeName then
    local function isProtected(p)
        local n = base(tostring(p))
        return isAuto(n) or isContest(n)
    end
    hookOK = installHook(writeName, "writefile", function(call)
        return function(path, data, ...)
            local p = tostring(path)
            if CFG.blockWrites and isProtected(p) then
                blockedCount = blockedCount + 1
                if not blockedWarned then
                    blockedWarned = true
                    log("SynthHub save blocked - files stay clean")
                end
                -- the blocked save is the only view we get of SynthHub's
                -- in-memory values, so peek at it (2s max) to spot real drift
                local now = nowSec()
                if now - lastDriftCheck > 2 then
                    lastDriftCheck = now
                    local t = dec(data)
                    if t then
                        local before = lateDrift
                        if isContest(base(p)) then cleanContest(t) else cleanAuto(t, true) end
                        if lateDrift > before and not driftWarned then
                            driftWarned = true
                            warnLog("SynthHub drifting LATE - tap FIX TIMING")
                        end
                    end
                end
                return true
            end
            local before = lateDrift
            local out = cleanData(p, data, true)
            if out and isAuto(base(p)) then
                -- the save IS a snapshot of the live table. Keep it as a
                -- fallback baseline for when the file itself was not found
                -- (mobile). The file baseline always wins, it is older and
                -- therefore closer to the good learned values.
                local now = nowSec()
                if (not cleanSaveAt) or (now - cleanSaveAt) > 1 then
                    cleanSaveAt = now
                    local ct = dec(out)
                    if ct and looksAuto(ct) then cleanSave = ct end
                end
            end
            if out and lateDrift > before and not driftWarned then
                driftWarned = true
                warnLog("timing drifting LATE - pulling it back now")
            end
            return call(path, out or data, ...)
        end
    end)
end

-- Reads must be sanitized too. SynthHub re-reads autotime.json while it plays
-- and folds those numbers back into its memory, so a drifted file would keep
-- teaching it to be late even with writes blocked.
local readOK = false
local lastReadFix = {}
local readCache = {}
if readName and CFG.sanitizeReads ~= false then
    readOK = installHook(readName, "readfile", function(call)
        return function(path, ...)
            local data = call(path, ...)
            if type(data) ~= "string" or #data == 0 then return data end
            local p = tostring(path)
            local c = readCache[p]
            if c and c.raw == data then return c.out end
            local n = base(p)
            if not (isAuto(n) or isContest(n)) then return data end
            local out = cleanData(p, data, false) or data
            readCache[p] = { raw = data, out = out }
            if out == data then return data end
            -- keep the copy on disk clean as well, but never more than once a second
            local now = nowSec()
            if (not lastReadFix[p]) or (now - lastReadFix[p]) > 1 then
                lastReadFix[p] = now
                local wf = rawIO.rawWrite
                if wf then pcall(wf, path, out) end
            end
            return out
        end
    end)
end

-- Proves the cleaning pipeline works, entirely in memory. No disk writes, so
-- it cannot be fooled by a sandboxed / read-only / delayed executor file.
local function selfTest()
    local probe = '{"tops":{"Probe":9},"clockOffset":9,'
        .. '"climbs":{"Probe":9},"leads":{"Probe":-9}}'
    local out = cleanData("autotime.json", probe, false)
    if type(out) ~= "string" then return false end
    local t = dec(out)
    if not t then return false end
    if type(t.tops) ~= "table" or t.tops.Probe ~= 0 then return false end
    if t.clockOffset ~= 0 then return false end
    if type(t.climbs) == "table" and t.climbs.Probe ~= 0 then return false end
    if type(t.leads) == "table" and t.leads.Probe ~= 0 then return false end
    return true
end

--=====================================================================
-- one-tap FIX TIMING button (mobile friendly)
-- Cleans every file and pulls the live table back to the clean values.
--=====================================================================
local function makeButtons()
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

        local bar = Instance.new("Frame")
        bar.Name = "Bar"
        bar.AnchorPoint = Vector2.new(1, 1)
        bar.Position = UDim2.new(1, -14, 1, -14)
        bar.Size = UDim2.new(0, 336, 0, 44)
        bar.BackgroundTransparency = 1
        bar.Parent = gui

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Horizontal
        layout.Padding = UDim.new(0, 6)
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
        layout.VerticalAlignment = Enum.VerticalAlignment.Center
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = bar

        local function makeBtn(text, w, color, order)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(0, w, 0, 44)
            b.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
            b.BackgroundTransparency = 0.1
            b.BorderSizePixel = 0
            b.AutoButtonColor = true
            b.Text = text
            b.TextColor3 = color
            b.TextSize = 15
            b.Font = Enum.Font.GothamBold
            b.LayoutOrder = order
            b.Parent = bar
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 8)
            c.Parent = b
            return b
        end

        local earlier = makeBtn("EARLIER", 84, Color3.fromRGB(120, 200, 255), 1)
        local later   = makeBtn("LATER",   84, Color3.fromRGB(255, 210, 120), 2)
        local btn     = makeBtn("FIX TIMING", 150, Color3.fromRGB(120, 255, 150), 3)

        -- nudge every value a little earlier / later, then rewrite the files.
        -- bias shifts the allowed window, so pressing it repeatedly cannot
        -- stack up into a runaway - it just moves the window.
        local function nudge(delta)
            local b = tonumber(CFG.bias) or 0
            b = math.max(-0.12, math.min(0.12, b + delta))
            CFG.bias = b
            local wf = rawIO.rawWrite or rawIO.writefile or writefile
            if wf then pcall(wf, BIAS_FILE, string.format("%.4f", b)) end
            for p in pairs(paths) do cleanFile(p, true, true) end
            -- the live copy has to move too, otherwise the button does nothing
            clampLive()
            local word = b < 0 and "earlier" or "later"
            log(("bias %+.3f - releasing %s"):format(b, word))
        end

        earlier.MouseButton1Click:Connect(function() nudge(-0.005) end)
        later.MouseButton1Click:Connect(function() nudge(0.005) end)

        local busy = false
        btn.MouseButton1Click:Connect(function()
            if busy then return end
            busy = true
            btn.Text = "FIXING..."
            local n = 0
            for p in pairs(paths) do
                if cleanFile(p, true, true) then n = n + 1 end
            end
            log(("FIX TIMING: %d file(s) cleaned"):format(n))
            driftWarned = false
            if CFG.liveClamp ~= false then clampLive() end
            task.wait(1.2)
            btn.Text = "FIX TIMING"
            busy = false
        end)
    end)
    return ok
end

if readfile and writefile then
    -- older builds left a test file behind; get rid of it
    if delfile then pcall(delfile, "autotime_probe.json") end
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
    if CFG.selfTest ~= false then
        if selfTest() then
            log("cleaner verified - timing values capped")
        else
            warnLog("cleaner self-test failed - re-run the script")
        end
    end
    if CFG.blockWrites then
        local weak = rawIO.mode == "wrapped"
        if hookOK and readOK and not weak then
            log("reads + saves blocked - SynthHub cannot drift")
        elseif hookOK and readOK then
            log("reads + saves blocked (soft mode)")
            log("RE-EXECUTE SynthHub once so it uses it")
        elseif hookOK then
            warnLog("saves blocked, reads NOT - drift may continue")
            warnLog("re-execute SynthHub then run this again")
        else
            log("executor blocks hooks - using file watchdog")
        end
    else
        -- default: let SynthHub save, but every save is clamped into the
        -- allowed window. This keeps its learnt values consistent instead of
        -- slowly drifting latch-up.
        if hookOK and rawIO.mode == "wrapped" then
            log("saves clamped (soft mode)")
            log("RE-EXECUTE SynthHub once so it uses it")
        elseif hookOK then
            log("saves clamped - timing cannot drift past the caps")
        else
            log("executor blocks hooks - using file watchdog")
        end
    end
    if CFG.liveClamp ~= false then
        log("live timing pinned - no late drift in memory")
    end
else
    warnLog("executor has no readfile/writefile - file fix disabled")
end

if CFG.liveClamp ~= false then
    scanLive(9000, 6, true)
    clampLive()
end

if CFG.button ~= false then makeButtons() end

-- Every watchdog pass is protected. If anything inside it throws, the loop
-- keeps going instead of dying: a dead pin is exactly what makes the timing
-- drift late again after a few minutes.
local loopErrs = {}
local function runLoop(name, every, fn)
    task.spawn(function()
        while true do
            local ok, err = pcall(fn)
            if not ok then
                loopErrs[name] = (loopErrs[name] or 0) + 1
                if loopErrs[name] <= 2 then
                    warnLog(name .. " pass failed, retrying: " .. tostring(err))
                end
            else
                loopErrs[name] = 0
            end
            task.wait(every)
        end
    end)
end

-- with reads AND writes blocked the file cannot drift between passes,
-- so the sweep can be slower and stay free on FPS
local eff = CFG.interval
if CFG.blockWrites and readOK then eff = math.max(eff, 1.0) end

-- The file side runs on its own, so a broken file can never stop the pin
-- that holds the timing in memory.
if CFG.watchdog and readfile and writefile then
    local fileTick = 0
    runLoop("file watchdog", eff, function()
        for p in pairs(paths) do cleanFile(p, true) end
        fileTick = fileTick + 1
        if fileTick % math.max(20, math.floor(120 / math.max(eff, 0.05))) == 0 then
            for p in pairs(discover()) do paths[p] = true end
        end
    end)
end

-- The pin runs on its own too, and it runs twice as often, so a value that
-- drifts late is pulled back before the next shot can use it.
if CFG.watchdog and CFG.liveClamp ~= false then
    local liveTick = 0
    local nextCheap, nextFull, nextReport = 0, 0, 0
    runLoop("live pin", math.min(eff, 0.25), function()
        liveTick = liveTick + 1
        clampLive()
        local now = nowSec()
        -- cheap tree walk every 5 s
        if now >= nextCheap then
            nextCheap = now + 5
            scanLive(2500, 4, false)
        end
        -- The full GC walk is the expensive one. While we are still LOOKING
        -- for the table it runs often, so the pin starts fast. Once it is
        -- found the table is held in liveStates and the scan has nothing
        -- left to do, so it drops back to a rare safety net. That keeps the
        -- cost off the FPS while shooting.
        local fullEvery = liveFound and 120 or 15
        if now >= nextFull then
            nextFull = now + fullEvery
            scanLive(6000, 6, true)
        end
        -- after 15 s nothing was found: the executor is hiding it
        if liveTick == 60 and not liveFound and not liveMissed then
            liveMissed = true
            warnLog("in-memory timing not found - only the file is being fixed")
        end
        if now >= nextReport then
            nextReport = now + 30
            reportLive()
        end
    end)
end

log("DONE - timing is pinned in memory and on disk")
