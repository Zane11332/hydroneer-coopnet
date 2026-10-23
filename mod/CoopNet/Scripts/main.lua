-- CoopNet (phase 4 prototype): host-authoritative co-op over two copies of Hydroneer.
--   client -> host: the client's inputs (move axes, control rotation, action key down/up), replayed
--                   by the host on a hidden player 2 (P2)
--   host -> client: P1/P2 transforms, velocities, what each carries, shovel dirt (~20 Hz), moved
--                   items (spread over ticks), voxel digs, test markers
--   client: world-changing actions do NOT run locally (their key mappings are removed; keys are
--           polled and only sent). The client shows host P1 as a puppet, reconciles its own player
--           with host P2, and mirrors items, carrying, shovel dirt and digging from the host.
-- Transport is files + relays (UE4SS Lua has no sockets): the game appends lines to an outbox,
-- the relay sends them by UDP; received datagrams are appended to an inbox the game reads.
--
-- client line: seq|fwd|right|pitch|yaw|events   events = "id,T,name;..." (last 8)
--   T: C = controller event, P = pawn event, M = marker, D = debug (TP_x_y_z_yaw, m = minus)
-- host lines:  S|seq|p1 xyz|p1yaw|p2 xyz|p2yaw|p1 vel xyz|ack_seq|ack_ev|p1item|p2item|p1dirt|p2dirt|session|caps|p1pitch
--              I|seq|name,x,y,z,pitch,yaw,roll;...
--              A|name,classpath,x,y,z,pitch,yaw,roll;...  (items with game-made names; the client pairs them)
--              W|id|fn|world|x|y|z|radius|extra|b1|b2|b3|b4  (a Voxel terrain edit; the client repeats it)
--              V|id|pickup(1/0)|x|y|z|radius        (a dig; sent 3 times; applied only by hosts without W)
--              J|text                                 (late join progress, shown to the friend)
--              N|id|classpath|x|y|z|pitch|yaw|roll|name  (name: the host's own; a late joiner has it already)
-- client events: J,late (send me your world), L,loaded (the host's world is loaded here)
--              Z|id|surfaceZ                          (host ground height at that dig, after it)
--              M|id|name|p1x,p1y,p1z|p2x,p2y,p2z|item@x,y,z;...
-- Relays prefix "recv_ns|send_ns|" (inbox lines on both sides).

local TAG = "[CoopNet] "
local MOD_VERSION = "fix6"   -- both players need the same; each side checks the other's
-- every line also goes to <run>/coopnet-game.log once the run folder is known (one file to send)
local logfile
local function log(s)
    print(TAG .. tostring(s) .. "\n")
    if logfile then pcall(function() logfile:write(os.date("%H:%M:%S ") .. tostring(s) .. "\n") logfile:flush() end) end
end

-- Modes:
--   play      installed for players: coopnet_config.lua (written by the installer) names the folder
--             shared with the relay; the relay writes role.txt; the player presses F7 in a world.
--   playtest  harness, test copies: the play-mode paths, but New Game and F7 happen by themselves;
--             bots only with HYDRO_COOP_BOT=1
--   test      harness, older layout: role and file paths from environment variables, bots on
local ENV_ROLE = os.getenv("HYDRO_COOP_ROLE")
local has_cfg, user_cfg = pcall(require, "coopnet_config")
local cfg = {}
if (ENV_ROLE == "host" or ENV_ROLE == "client") and os.getenv("HYDRO_COOP_PLAYTEST") ~= "1" then
    if not os.getenv("HYDRO_COOP_APPDATA") then
        log("refusing to run: SaveRedirect target (HYDRO_COOP_APPDATA) not set")
        return
    end
    cfg = { mode = "test", role = ENV_ROLE, bot = true,
            client_out = os.getenv("HYDRO_COOP_OUTBOX"), client_in = os.getenv("HYDRO_COOP_INBOX_CLIENT"),
            host_in = os.getenv("HYDRO_COOP_INBOX"), host_out = os.getenv("HYDRO_COOP_OUTBOX_HOST"),
            run = os.getenv("HYDRO_COOP_RUN_DIR"), ready = os.getenv("HYDRO_COOP_READY_FILE") }
elseif has_cfg and type(user_cfg) == "table" and user_cfg.run_dir then
    local run = user_cfg.run_dir
    local playtest = os.getenv("HYDRO_COOP_PLAYTEST") == "1"
    if playtest and not os.getenv("HYDRO_COOP_APPDATA") then
        log("refusing to run playtest: SaveRedirect target (HYDRO_COOP_APPDATA) not set")
        return
    end
    cfg = { mode = playtest and "playtest" or "play", role = nil, bot = playtest and os.getenv("HYDRO_COOP_BOT") == "1",
            client_out = run .. "/to_net.txt", client_in = run .. "/from_net.txt",
            host_in = run .. "/from_net.txt", host_out = run .. "/to_net.txt",
            run = run, ready = run .. "/ready.txt" }
else
    return   -- not configured: the mod does nothing
end
local ROLE = cfg.role
if cfg.run then
    logfile = io.open(cfg.run .. "/coopnet-game.log", "a")
    if logfile then logfile:write("\n==== " .. os.date("%Y-%m-%d %H:%M:%S") .. " game started\n") end
end
log("mode " .. cfg.mode .. (ROLE and (", role " .. ROLE) or "") .. ", CoopNet " .. MOD_VERSION)

-- one-line status for the relay window (it prints it every few seconds)
local function game_status(msg)
    log("status: " .. msg)
    if not cfg.run then return end
    local f = io.open(cfg.run .. "/status-game.txt", "w")
    if f then f:write(msg .. "\n") f:close() end
end

-- ---------------------------------------------------------------- late join helpers
-- In a world: the game mode's InGame? flag. The main menu runs inside the world level and has a
-- player pawn too, so a pawn says nothing (SaveProbe, NOTES "late join, step 1").
local function in_game()
    local v = false
    pcall(function() local gm = FindFirstOf("GM_Hydroneer_C") v = gm and gm:IsValid() and gm["InGame?"] == true end)
    return v
end
local JOIN_SLOT = "CoopNetHost"                    -- where a late joiner keeps the host's world
local SAVE_FILES = { "Level.sav", "Player.sav", "SaveData.sav" }
local function saved_dir()                         -- the game's Saved folder, with a trailing slash
    local d
    pcall(function() d = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString() end)
    return d
end
local function copy_file(src, dst)
    local i = io.open(src, "rb")
    if not i then return nil end
    local data = i:read("a")
    i:close()
    local o = io.open(dst, "wb")
    if not o then return nil end
    o:write(data)
    o:close()
    return #data
end
local function make_dir(path)                      -- cmd's mkdir (also there under Proton)
    os.execute('mkdir "' .. (path:gsub("/", "\\")) .. '" 2>nul')
end
local function current_slot(ctx)                   -- EasyMultiSave's current slot name
    local name = nil
    pcall(function()
        local out = {}
        StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):GetSlotInfoSaveGame(ctx, out)
        local v = out.SaveGameName or out[1]
        if v then name = v:ToString() end
    end)
    return name
end
-- client line counters, shared by the late-join request and the normal client loop (the host
-- drops lines and events that do not count up)
local client_seq, client_ev = 0, 1
local client_out_file = nil
local function client_outbox()
    if not client_out_file then client_out_file = io.open(cfg.client_out, "a") end
    return client_out_file
end
local late_joined = false

-- ---------------------------------------------------------------- helpers
local function name_of(o) if o and o:IsValid() then return o:GetFullName() end return "<none>" end
local function short(o) return o:GetFName():ToString() end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end
local function loc_of(a) local l = a:K2_GetActorLocation() return vec(l.X, l.Y, l.Z) end
local function rot_of(a) local r = a:K2_GetActorRotation() return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function fmt(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function dist2d(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function key(name) return { KeyName = FName(name) } end
-- Game-thread timers. UE4SS v3.0.1-1181 has LoopInGameThreadWithDelay / ExecuteInGameThreadWithDelay.
-- With that build, the old pattern (a fresh ExecuteInGameThread callback every tick from LoopAsync,
-- plus generational GC) logged "Ref was not function" and once crashed inside UE4SS; which of the two
-- caused it is not known. 3.0.1 only has the LoopAsync pattern, which ran fine there.
local NEW_TIMERS = (LoopInGameThreadWithDelay ~= nil and CancelDelayedAction ~= nil and ExecuteInGameThreadWithDelay ~= nil)
local function later(ms, fn)
    local function run() local ok, err = pcall(fn) if not ok then log("error: " .. tostring(err)) end end
    if NEW_TIMERS then ExecuteInGameThreadWithDelay(ms, run)
    else ExecuteWithDelay(ms, function() ExecuteInGameThread(run) end) end
end
-- Call fn on the game thread every ms milliseconds until it returns true.
local function game_loop(ms, fn)
    if NEW_TIMERS then
        local handle, stopped = nil, false
        handle = LoopInGameThreadWithDelay(ms, function()
            if stopped then return end
            local ok, stop = pcall(fn)
            if not ok then log("loop error: " .. tostring(stop)) end
            if ok and stop then
                stopped = true
                if handle then CancelDelayedAction(handle) end
            end
        end)
        return
    end
    local stopped = false
    LoopAsync(ms, function()
        if stopped then return true end
        ExecuteInGameThread(function()
            local ok, stop = pcall(fn)
            if not ok then log("loop error: " .. tostring(stop)) end
            if ok and stop then stopped = true end
        end)
        return stopped
    end)
end
local function kml() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
local function parse_vec(s) local x, y, z = (s or ""):match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
    if x then return vec(tonumber(x), tonumber(y), tonumber(z)) end end

local function set_loc(actor, l)
    local ok = pcall(function() actor:K2_SetActorLocation(l, false, {}, true) end)
    if not ok then actor:K2_TeleportTo(l, rot_of(actor)) end
end
local function set_loc_rot(actor, l, r)
    local ok = pcall(function() actor:K2_SetActorLocationAndRotation(l, r, false, {}, true) end)
    if not ok then actor:K2_TeleportTo(l, r) end
end

local function key_for(fname)
    for pat, k in pairs({ Pickup = "E", LMB = "LeftMouseButton", RMB = "RightMouseButton", Jump = "SpaceBar",
                          Crouch = "C", Sprint = "LeftShift", Rotate3 = "Y", Rotate2 = "T", Rotate = "R",
                          VehicleKey = "Q", RotationMod = "LeftControl", BuildPlaceCloser = "MouseScrollDown",
                          BuildPlaceFurther = "MouseScrollUp" }) do
        if fname:find(pat, 1, true) then return k end
    end
    return "None"
end

local CTRL = "/Game/BP_GameController.BP_GameController_C:"
local CHAR = "/Game/BP_GameCharacter.BP_GameCharacter_C:"
-- Pawn-only actions still run locally on the client (they only move the client's own player,
-- which the host reconciles) and are forwarded by hooking their events.
local PAWN_ACTIONS = {
    "InpActEvt_Jump_K2Node_InputActionEvent_4", "InpActEvt_Jump_K2Node_InputActionEvent_5",
    "InpActEvt_Crouch_K2Node_InputActionEvent_2", "InpActEvt_Crouch_K2Node_InputActionEvent_3",
    "InpActEvt_Sprint_K2Node_InputActionEvent_0", "InpActEvt_Sprint_K2Node_InputActionEvent_1",
}
-- World-changing actions: removed from the client's input mappings, polled as keys, only sent.
-- Generated event pairs: the lower index is key-down (observed for Pickup 12/13 and LMB 5/6).
local WORLD_ACTIONS = { "Pickup", "LMB", "RMB", "Rotate", "Rotate2", "Rotate3", "VehicleKey",
                        "VehicleMode", "RotationMod", "BuildPlaceCloser", "BuildPlaceFurther" }
local POLL_KEYS = {
    { "E", "InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13" },
    { "Gamepad_FaceButton_Left", "InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13" },
    { "LeftMouseButton", "InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6" },
    { "Gamepad_RightTrigger", "InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6" },
    { "RightMouseButton", "InpActEvt_RMB_K2Node_InputActionEvent_7", "InpActEvt_RMB_K2Node_InputActionEvent_8" },
    { "Gamepad_LeftTrigger", "InpActEvt_RMB_K2Node_InputActionEvent_7", "InpActEvt_RMB_K2Node_InputActionEvent_8" },
    { "R", "InpActEvt_Rotate_K2Node_InputActionEvent_15", nil },
    { "T", "InpActEvt_Rotate2_K2Node_InputActionEvent_14", nil },
    { "Y", "InpActEvt_Rotate3_K2Node_InputActionEvent_10", nil },
    { "Q", "InpActEvt_VehicleKey_K2Node_InputActionEvent_11", nil },
    { "LeftControl", "InpActEvt_RotationMod_K2Node_InputActionEvent_2", "InpActEvt_RotationMod_K2Node_InputActionEvent_3" },
}

local function controllers()
    local pcs = FindAllOf("BP_GameController_C") or {}
    table.sort(pcs, function(a, b) return a:GetFullName() > b:GetFullName() end) -- P1 first (older, larger id)
    return pcs
end

-- Reads lines appended to path. The first open skips what is already there: those lines are
-- from before F7, possibly from an earlier game or session (seen: a client applied a quit host
-- game's item ids); everything the other side needs is repeated every few seconds.
local function line_reader(path)
    local f, buf = nil, ""
    return function(handle)
        if not f then
            f = io.open(path, "r")
            if not f then return end
            local skipped = f:seek("end") or 0
            log(string.format("inbox %s: skipped %d bytes from before co-op started", path, skipped))
        end
        -- Wine's CRT (Proton) marks a file "at EOF" after one empty read and returns nothing until
        -- a seek, so a file read while still empty never yields data again. Seeking in place clears
        -- that (wine dlls/msvcrt/file.c, WX_ATEOF); on Windows it changes nothing.
        f:seek("cur", 0)
        local chunk = f:read("a")
        if chunk and #chunk > 0 then
            buf = buf .. chunk
            while true do
                local nl = buf:find("\n", 1, true)
                if not nl then break end
                handle(buf:sub(1, nl - 1))
                buf = buf:sub(nl + 1)
            end
        end
    end
end

local function aim_pc(pc, target)
    local p = loc_of(pc.Pawn)
    local r = kml():FindLookAtRotation(vec(p.X, p.Y, p.Z + 64), target)
    pc:SetControlRotation({ Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 })
end

local function drive(ms, fn, after)
    -- every frame where the build allows it (real input arrives every frame; a 30 Hz timer made
    -- bot walks slow), else on the game-thread timer
    local t0 = os.clock()
    if LoopInGameThreadAfterFrames and CancelDelayedAction then
        local handle, done = nil, false
        handle = LoopInGameThreadAfterFrames(1, function()
            if done then return end
            if (os.clock() - t0) * 1000 >= ms then
                done = true
                if handle then CancelDelayedAction(handle) end
                later(50, after)
                return
            end
            pcall(fn)
        end)
        return
    end
    game_loop(16, function()
        if (os.clock() - t0) * 1000 >= ms then
            later(50, after)
            return true
        end
        pcall(fn)
        return false
    end)
end

local function nearest_item(class, from)
    local best, bd = nil, 1e12
    for _, it in ipairs(FindAllOf(class) or {}) do
        local d = dist2d(loc_of(it), from)
        if d < bd then best, bd = it, d end
    end
    return best
end

-- Ground height under (x, y): first blocking hit of a downward trace.
local function surface_z(ctx, x, y, ztop, zbot)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    local ok = pcall(function()
        ksl:LineTraceSingle(ctx, vec(x, y, ztop), vec(x, y, zbot), 0, true, {}, 0, out, true,
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    end)
    if not ok then return nil, "trace error" end
    local h = out.OutHit or out
    if not (h and h.Location) then return nil, "no hit" end
    return h.Location.Z, name_of(h.Actor and h.Actor:Get())
end

local function str_mws(pawn)
    local v = "?"
    pcall(function() v = string.format("%.0f", pawn.CharacterMovement.MaxWalkSpeed) end)
    return v
end

local function carried_name(pc)
    local it = nil
    pcall(function() it = pc.CarryingItem end)
    if it and it:IsValid() then return short(it), it end
    return "-", nil
end
local function dirt_flag(it)
    if not it then return -1 end
    local v = -1
    pcall(function() v = it.Dirt:IsVisible() and 1 or 0 end)
    return v
end

-- ---------------------------------------------------------------- action trace (diagnostic)
-- Logs calls of the game's own action functions on the controller and on the classes of items
-- players pick up, with simple arguments: "act <Class:Function> on <who> (args)". The first 12
-- calls of each are logged, then every 50th; every 30 s a count summary. Only names that look like
-- actions are hooked: hooking all 104 controller functions (per-frame traces, highlighting,
-- HitResult out parameters) crashed the game inside UE4SS (access violation at 0x10).
-- A function called more than 300 times in 10 s stops being logged. Both sides log.
local trace = { counts = {}, since = {}, window = {}, hooked = {}, ids = {}, off = {}, unhook = {},
                label = function(o) return short(o) end, t_window = 0, t_summary = 0 }
local TRACE_WANT = { "^InpActEvt_", "Pick", "Drop", "Dirt", "Place", "LMB", "RMB", "UseAnim", "Water", "Liquid",
                     "Empty", "^Add", "^Remove", "Hit", "Dig", "Mine", "Paid", "Stored", "Store", "Crane", "Vehicle",
                     "FX", "Tip", "Scrub", "Generate", "Spawn", "Ice", "Fill", "Pour", "Sell", "Buy", "Freeplac",
                     "PlayAnimation" }
local TRACE_SKIP = { "Tick", "Ubergraph", "UserConstructionScript", "BndEvt", "Receive", "Highlight", "Crosshair",
                     "Trace", "HUD", "Timer", "Timeline", "Lerp", "Positioning", "PositionItem", "Collision", "Physic",
                     "Velocity", "Save", "Cloud", "Menu", "AnyKey", "Mouse", "Get", "Can", "Bounds", "Mat", "Held",
                     "Load", "__", "Delegate" }
local function trace_wanted(fname)
    for _, sk in ipairs(TRACE_SKIP) do if fname:find(sk, 1, true) then return false end end
    for _, w in ipairs(TRACE_WANT) do if fname:find(w) then return true end end
    return false
end
local function trace_val(p)
    local s = "?"
    pcall(function()
        local v = p:get()
        local tv = type(v)
        if tv == "number" then s = (math.floor(v) == v) and tostring(v) or string.format("%.2f", v)
        elseif tv == "boolean" or tv == "string" then s = tostring(v)
        else
            s = "obj"
            pcall(function() if v:IsValid() then s = trace.label(v) end end)
        end
    end)
    return s
end
local function trace_call(key, self, ...)
    if trace.off[key] then return end
    local c = (trace.counts[key] or 0) + 1
    trace.counts[key] = c
    trace.since[key] = (trace.since[key] or 0) + 1
    local w = (trace.window[key] or 0) + 1
    trace.window[key] = w
    if w > 300 then
        trace.off[key] = true
        log("trace: " .. key .. " runs very often, no longer logged")
        return
    end
    if c <= 12 or c % 50 == 0 then
        local who = "?"
        pcall(function() who = trace.label(self:get()) end)
        local parts, args = {}, { ... }
        for i = 1, math.min(#args, 5) do parts[#parts + 1] = trace_val(args[i]) end
        log(string.format("act %s on %s (%s)%s", key, who, table.concat(parts, ", "), c > 12 and (" #" .. c) or ""))
    end
end
local function trace_class(cls)
    local path
    pcall(function() path = cls:GetFullName():match("^%S+%s+(.+)$") end)
    if not path or trace.hooked[path] or not path:find("^/Game/") then return end
    trace.hooked[path] = true
    local short_cls = path:match("%.([%w_]+)$") or path
    local n = 0
    local ok, err = pcall(function()
        cls:ForEachFunction(function(f)
            local fname = f:GetFName():ToString()
            if not trace_wanted(fname) then return end
            local key = short_cls .. ":" .. fname
            local ok2, pre, post = pcall(RegisterHook, path .. ":" .. fname, function(self, ...) trace_call(key, self, ...) end)
            if ok2 then n = n + 1 trace.ids[key] = { path .. ":" .. fname, pre, post } end
        end)
    end)
    log(string.format("trace: hooked %d functions of %s%s", n, short_cls, ok and "" or (" (" .. tostring(err) .. ")")))
end
-- the item's class and its parents up to BP_ParentItem_C
local function trace_item_class(it)
    local c, depth = nil, 0
    pcall(function() c = it:GetClass() end)
    while c and depth < 8 do
        trace_class(c)
        local cname = ""
        pcall(function() cname = c:GetFName():ToString() end)
        if cname == "BP_ParentItem_C" or cname == "" then break end
        local sup
        pcall(function() sup = c:GetSuperStruct() end)
        c, depth = sup, depth + 1
    end
end
-- call from a game loop: unhooks, 10 s windows, 30 s summary
local function trace_tick()
    local now = os.clock()
    if now - trace.t_window > 10 then trace.window, trace.t_window = {}, now end
    if now - trace.t_summary > 30 then
        trace.t_summary = now
        local t = {}
        for k, v in pairs(trace.since) do t[#t + 1] = { k, v } end
        table.sort(t, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(20, #t) do parts[#parts + 1] = t[i][1] .. "=" .. t[i][2] end
        if #parts > 0 then log("actions in the last 30 s: " .. table.concat(parts, " ")) end
        trace.since = {}
    end
end

-- ---------------------------------------------------------------- item state (water, dirt loads, meshes)
-- Per class: its own number/bool fields and mesh components, up to BP_ParentItem_C, read by
-- reflection. Carry/hover/physics bookkeeping is left out (each side runs its own).
local state_props = {}
local STATE_SKIP = { "time", "timer", "delta", "speed", "alpha", "rate", "velocity", "distance", "angle",
                     "carr", "hover", "look", "highlight", "pick", "proxy", "physic", "simulat", "outline" }
local function state_list(it)
    local cls = it:GetClass()
    local key = cls:GetFullName()
    if state_props[key] then return state_props[key] end
    log("reading state fields of " .. (key:match("%.([%w_]+)$") or key))
    local list, names = {}, {}
    local c, depth = cls, 0
    while c and depth < 8 do
        local cname = ""
        pcall(function() cname = c:GetFName():ToString() end)
        if cname == "" or cname == "Actor" then break end
        pcall(function()
            c:ForEachProperty(function(prop)
                local pn = prop:GetFName():ToString()
                if names[pn] then return end
                local low = pn:lower()
                for _, sk in ipairs(STATE_SKIP) do if low:find(sk, 1, true) then return end end
                local pt = prop:GetClass():GetFName():ToString()
                local kind
                if pt == "IntProperty" or pt == "ByteProperty" or pt == "EnumProperty" then kind = "n"
                elseif pt == "BoolProperty" then kind = "b"
                elseif pt == "FloatProperty" then kind = "f"
                elseif pt == "ObjectProperty" and (pn:find("Mesh", 1, true) or pn == "Dirt") then
                    local vc = ""
                    pcall(function()
                        local v = it[pn]
                        if v and v:IsValid() then vc = v:GetClass():GetFName():ToString() end
                    end)
                    if vc:find("MeshComponent", 1, true) then kind = "m" end
                end
                if kind then names[pn] = true list[#list + 1] = { pn, kind } end
            end)
        end)
        if cname == "BP_ParentItem_C" then break end
        local sup
        pcall(function() sup = c:GetSuperStruct() end)
        c, depth = sup, depth + 1
    end
    state_props[key] = list
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = e[1] .. ":" .. e[2] end
    log(string.format("state fields of %s: %s", key:match("%.([%w_]+)$") or key, table.concat(t, " "):sub(1, 700)))
    return list
end
-- "name=value;..." (m: v1 visible / v0 hidden)
local function item_state(it)
    local parts = {}
    for _, e in ipairs(state_list(it)) do
        local v
        pcall(function()
            local x = it[e[1]]
            if e[2] == "m" then
                if x and x:IsValid() then v = x:IsVisible() and "v1" or "v0" end
            elseif e[2] == "b" then v = x and "t" or "f"
            elseif e[2] == "f" then v = string.format("%.1f", x)
            else v = tostring(math.floor(x)) end
        end)
        if v then parts[#parts + 1] = e[1] .. "=" .. v end
    end
    return table.concat(parts, ";")
end
-- apply a host state to our copy; returns the changes as text
local function apply_state(it, st)
    local changed = {}
    local list = state_list(it)
    local kinds = {}
    for _, e in ipairs(list) do kinds[e[1]] = e[2] end
    for k, v in st:gmatch("([^;=]+)=([^;]+)") do
        local kind = kinds[k]
        if kind then
            pcall(function()
                if kind == "m" then
                    local comp = it[k]
                    local want = v == "v1"
                    if comp and comp:IsValid() and comp:IsVisible() ~= want then comp:SetVisibility(want, false) changed[#changed + 1] = k .. (want and " shown" or " hidden") end
                elseif kind == "b" then
                    local want = v == "t"
                    if it[k] ~= want then it[k] = want changed[#changed + 1] = k .. "=" .. v end
                elseif kind == "f" then
                    local want = tonumber(v)
                    if math.abs((it[k] or 0) - want) > 0.05 then it[k] = want changed[#changed + 1] = k .. "=" .. v end
                else
                    local want = tonumber(v)
                    if math.floor(it[k]) ~= want then it[k] = want changed[#changed + 1] = k .. "=" .. v end
                end
            end)
        end
    end
    return table.concat(changed, ", ")
end

-- ================================================================ client
local function run_client()
    local OUTBOX, INBOX = cfg.client_out, cfg.client_in
    local RUN = cfg.run
    local out = client_outbox()
    if not out then log("cannot open outbox " .. tostring(OUTBOX)) return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")

    -- 1) world-changing actions no longer run locally: remove their key mappings
    local is = StaticFindObject("/Script/Engine.Default__InputSettings")
    local world = {}
    for _, a in ipairs(WORLD_ACTIONS) do world[a] = true end
    local function live_world_mappings()
        local n = 0
        is.ActionMappings:ForEach(function(i, e)
            local m = e:get()
            if world[m.ActionName:ToString()] and m.Key.KeyName:ToString() ~= "None" then n = n + 1 end
        end)
        return n
    end
    local before = live_world_mappings()
    -- attempt 1: RemoveActionMapping (modifier flags as booleans)
    local list = {}
    is.ActionMappings:ForEach(function(i, e)
        local m = e:get()
        if world[m.ActionName:ToString()] then
            list[#list + 1] = { a = m.ActionName:ToString(), k = m.Key.KeyName:ToString(), s = m.bShift, c = m.bCtrl, al = m.bAlt, cm = m.bCmd }
        end
    end)
    for _, m in ipairs(list) do
        pcall(function()
            is:RemoveActionMapping({ ActionName = FName(m.a), bShift = m.s and true or false, bCtrl = m.c and true or false,
                bAlt = m.al and true or false, bCmd = m.cm and true or false, Key = { KeyName = FName(m.k) } }, false)
        end)
    end
    local after1 = live_world_mappings()
    -- attempt 2: blank the key of each remaining world-action mapping in place
    if after1 > 0 then
        is.ActionMappings:ForEach(function(i, e)
            local m = e:get()
            if world[m.ActionName:ToString()] then
                pcall(function() m.Key.KeyName = FName("None") end)
            end
        end)
    end
    local after2 = live_world_mappings()
    pcall(function() is:ForceRebuildKeymaps() end)
    log(string.format("client input: world-action mappings %d before, %d after RemoveActionMapping, %d after blanking keys; keymaps rebuilt",
        before, after1, after2))

    pcall(function() trace_class(StaticFindObject("/Game/BP_GameController.BP_GameController_C")) end)
    pcall(function() local a = FindFirstOf("AC_Animator_C") if a then trace_class(a:GetClass()) end end)

    -- count every local call of the world-changing game functions (should only be our mirrors)
    local local_calls = {}
    for _, f in ipairs({ "TryPickupItem", "PickUpItem", "DropItem", "MoveDirt", "RemoveDirtByLocation", "StartFreeplacing" }) do
        pcall(function() RegisterHook(CTRL .. f, function()
            local_calls[f] = (local_calls[f] or 0) + 1
        end) end)
    end
    local function local_calls_str()
        local t = {}
        for k, v in pairs(local_calls) do t[#t + 1] = k .. "=" .. v end
        return #t > 0 and table.concat(t, " ") or "none"
    end

    -- test only: two copies on one PC give their starter items the same game-made names, which
    -- hid the name mismatch two real PCs have. Remake ours under new names to get that case.
    if cfg.mode ~= "play" and os.getenv("HYDRO_COOP_TEST_RENAME") == "1" then
        local n = 0
        local pc0 = controllers()[1]
        for _, cls in ipairs({ "BP_ShovelT1_C", "BP_Pan_C", "BP_Brush_C", "BP_Bucket_C", "BP_Lantern_C", "BP_WorldMap_C" }) do
            for _, it in ipairs(FindAllOf(cls) or {}) do
                local ok = short(it):match("_C_%d+$") ~= nil
                pcall(function() local r = it:K2_GetRootComponent() ok = ok and r and r:IsValid() end)
                if ok then
                    local l, r, c = loc_of(it), rot_of(it), it:GetClass()
                    local old = short(it)
                    it:K2_DestroyActor()
                    local a
                    pcall(function() a = pc0:GetWorld():SpawnActor(c, l, r) end)
                    if a and a:IsValid() then
                        set_loc_rot(a, l, r)
                        n = n + 1
                        log("test rename: " .. old .. " -> " .. short(a))
                    end
                end
            end
        end
        log("test rename: remade " .. n .. " items under new names")
    end

    -- puppet for host P1
    FindFirstOf("GM_Hydroneer_C"):AddLocalPlayer()
    local pc, puppet, puppet_pc
    later(3000, function()
        local pcs = controllers()
        pc = pcs[1]
        gs:SetForceDisableSplitscreen(pc, true)
        puppet_pc = pcs[2]
        puppet = pcs[2] and pcs[2].Pawn
        if puppet and puppet:IsValid() then
            pcall(function() puppet.CharacterMovement:SetMovementMode(0, 0) end)
            log("puppet = " .. name_of(puppet))
        end
    end)

    local acc = { fwd = 0, right = 0 }
    local events, next_id, seq = {}, client_ev, client_seq
    local function push(T, name)
        events[#events + 1] = string.format("%d,%s,%s", next_id, T, name)
        next_id = next_id + 1
        if #events > 8 then table.remove(events, 1) end
    end
    -- one-off events that must arrive go into every line for ~10 s (a burst of other events once
    -- pushed the "loaded" event out of the last 8 before it was ever sent)
    local sticky = {}
    local function push_sticky(T, name)
        sticky[#sticky + 1] = { s = string.format("%d,%s,%s", next_id, T, name), left = 300 }
        next_id = next_id + 1
    end
    function client_events_line()
        local t = {}
        for i = #sticky, 1, -1 do
            sticky[i].left = sticky[i].left - 1
            if sticky[i].left < 0 then table.remove(sticky, i) end
        end
        for _, e in ipairs(sticky) do t[#t + 1] = e.s end
        for _, e in ipairs(events) do t[#t + 1] = e end
        return table.concat(t, ";")
    end
    -- input hooks fire for every character, the puppet too: count only our own pawn's
    -- (after a late join the puppet's jump/crouch events filled the event list)
    local others = 0
    local own_name, own_name_t = nil, -1
    local function mine(self)
        -- by full name (a GetAddress comparison failed silently and dropped all our own input)
        local ok, yes = pcall(function()
            if not (pc and pc.Pawn and pc.Pawn:IsValid()) then return false end
            if os.clock() - own_name_t > 0.5 then own_name, own_name_t = pc.Pawn:GetFullName(), os.clock() end
            return self:get():GetFullName() == own_name
        end)
        if ok and yes then return true end
        others = others + 1
        if others <= 3 or others % 2000 == 0 then
            local who = "?"
            pcall(function() who = self:get():GetFullName():match("[^.]+$") end)
            log(string.format("input from another character ignored (%d so far): %s, ours %s%s", others, who,
                tostring(own_name and own_name:match("[^.]+$")), ok and "" or (" (check failed: " .. tostring(yes) .. ")")))
        end
        return false
    end
    local function axis_hook(field)
        return function(self, v)
            if not mine(self) then return end
            local x = v:get()
            if math.abs(x) > math.abs(acc[field]) then acc[field] = x end
        end
    end
    push_sticky("V", MOD_VERSION)   -- our version for the host
    if late_joined then push_sticky("L", "loaded") end   -- the host then repeats terrain edits made after its save
    RegisterHook(CHAR .. "InpAxisEvt_MoveForward_K2Node_InputAxisEvent_0", axis_hook("fwd"))
    RegisterHook(CHAR .. "InpAxisEvt_MoveRight_K2Node_InputAxisEvent_1", axis_hook("right"))
    for _, fname in ipairs(PAWN_ACTIONS) do
        pcall(function() RegisterHook(CHAR .. fname, function(self) if mine(self) then push("P", fname) end end) end)
    end

    -- 2) poll world-action keys (edges -> down/up events that are only sent)
    local key_down, polled = {}, {}
    local function poll_keys()
        for _, k in ipairs(POLL_KEYS) do
            local down = false
            pcall(function() down = pc:IsInputKeyDown(key(k[1])) end)
            if down and not key_down[k[1]] then
                push("C", k[2])
                polled[k[1]] = (polled[k[1]] or 0) + 1
                log("polled key down " .. k[1])
            elseif not down and key_down[k[1]] and k[3] then
                push("C", k[3])
                log("polled key up " .. k[1])
            end
            key_down[k[1]] = down
        end
    end

    -- host state as last received
    local host = { p1 = nil, p1yaw = 0, p2 = nil, seen_seq = 0, items = 0, applied = 0, unknown = 0,
                   p1item = "-", p2item = "-", p1dirt = -1, p2dirt = -1, session = nil, caps = "-" }
    local unknown_names = {}          -- host item names we could not find here, with counts (diagnostic)
    local carry_miss = { name = nil, n = 0 }
    local item_by_name, item_map_time = {}, -1e9
    local function rebuild_items()
        item_by_name = {}
        for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do item_by_name[short(it)] = it end
        item_map_time = os.clock()
    end
    -- runtime items spawned on the host's say-so, by net id; and their FName -> id
    local spawned, id_by_fname, spawn_stats = {}, {}, { spawned = 0, failed = 0, destroyed = 0 }
    -- a destroyed actor stays IsValid() for a while; its root component does not
    local function live(it)
        if not (it and it:IsValid()) then return false end
        local ok = false
        pcall(function() local r = it:K2_GetRootComponent() ok = r and r:IsValid() or false end)
        return ok
    end
    local function find_item(name)
        local s = spawned[name]
        if s then
            if live(s) then return s end
            return nil
        end
        local it = item_by_name[name]
        if not live(it) and os.clock() - item_map_time > 2 then
            rebuild_items()
            it = item_by_name[name]
        end
        if live(it) then return it end
    end
    local corr = { snaps = 0, blends = 0, max_err = 0, sum_err = 0, n = 0 }
    local hist = {}
    local last_axes = { fwd = 0, right = 0 }
    -- own.last is reset after each correction, so own speed counts only our own movement
    local own = { last = nil, last_t = nil, sum = 0, n = 0 }
    function own_speed_take()
        local s = own.n > 0 and own.sum / own.n or 0
        own.sum, own.n = 0, 0
        return s
    end
    local seen_markers, seen_digs, my_dig_z, seen_z, seen_anims = {}, {}, {}, {}, {}
    local anim_stats = { played = 0, missing = 0 }
    local seen_sounds, sound_cache, snd_stats = {}, {}, { played = 0 }
    local host_named, pair_pending, seen_edits, apply_terrain_edit, reset_host_state, resolve_pairs_tick
    local waiting_for = {}
    local mirror = { pickups = 0, drops = 0, dirt_sets = 0, digs = 0 }

    -- 3) mirror carrying from the host: run the game's own carry logic locally on its decision
    -- our carried item's name as the host knows it (net id for spawned runtime items)
    local function my_carried()
        local n, it = carried_name(pc)
        return id_by_fname[n] or n, it
    end
    local last_carry_try = -1e9
    local function mirror_carry()
        if not pc then return end
        local mine, it_mine = my_carried()
        local due = os.clock() - last_carry_try > 0.5   -- at most two carry attempts per second
        if due and (host.p2item ~= "-" and mine ~= host.p2item or host.p2item == "-" and mine ~= "-") then
            last_carry_try = os.clock()
        else
            due = false
        end
        if due and host.p2item ~= "-" and mine ~= host.p2item then
            local it = find_item(host.p2item)
            if not it then
                if carry_miss.name ~= host.p2item then carry_miss.name, carry_miss.n = host.p2item, 0 end
                carry_miss.n = carry_miss.n + 1
                if carry_miss.n == 1 or carry_miss.n % 20 == 0 then
                    log(string.format("mirror: host says we carry %s, but no such item here (%d tries)", host.p2item, carry_miss.n))
                end
            end
            if it then
                pc:PickUpItem(it)
                mirror.pickups = mirror.pickups + 1
                log("mirror: host P2 carries " .. host.p2item .. " -> PickUpItem locally")
            end
        elseif due and host.p2item == "-" and mine ~= "-" then
            pcall(function() pc:DropItem({}) end)
            local after = my_carried()
            mirror.drops = mirror.drops + 1
            log("mirror: host P2 dropped -> DropItem locally, now carrying " .. after)
        end
        -- shovel dirt as the host has it (own carried item and host P1's)
        for _, pair in ipairs({ { host.p2item, host.p2dirt }, { host.p1item, host.p1dirt } }) do
            if pair[1] ~= "-" and pair[2] >= 0 then
                local it = find_item(pair[1])
                if it then
                    local cur = dirt_flag(it)
                    if cur >= 0 and cur ~= pair[2] then
                        it.Dirt:SetVisibility(pair[2] == 1, false)
                        mirror.dirt_sets = mirror.dirt_sets + 1
                        log(string.format("mirror: %s dirt -> %s", pair[1], pair[2] == 1 and "full" or "empty"))
                    end
                end
            end
        end
    end

    local function compare(name, hp1, hp2, items)
        local me = loc_of(pc.Pawn)
        local s = string.format("cmp %s: self-hostP2 %.0f cm", name, dist(me, hp2))
        if puppet and puppet:IsValid() then s = s .. string.format(", puppet-hostP1 %.0f cm", dist(loc_of(puppet), hp1)) end
        for iname, hl in pairs(items) do
            local it = find_item(iname)
            s = s .. (it and string.format(", %s client-host %.0f cm", iname, dist(loc_of(it), hl)) or (", " .. iname .. " missing"))
        end
        s = s .. string.format(" | carry host P2=%s client=%s | local game calls: %s", host.p2item, (my_carried()), local_calls_str())
        log(s)
    end

    -- spawn a copy of a host runtime item (class path from the host)
    local local_spawning = false
    local function spawn_copy(id, cp, l, r)
        local cls = StaticFindObject(cp)
        if not (cls and cls:IsValid()) then
            pcall(function() LoadAsset(cp:match("^(.-)%.[^%.]+$") or cp) end)
            cls = StaticFindObject(cp)
        end
        if not (cls and cls:IsValid()) then
            spawn_stats.failed = spawn_stats.failed + 1
            log("spawn " .. id .. ": class not found " .. cp)
            return
        end
        -- UWorld:SpawnActor(class, location, rotation) exists in UE4SS v3.0.1-1181 (not in 3.0.1)
        local actor
        local_spawning = true
        local ok, err = pcall(function()
            actor = pc:GetWorld():SpawnActor(cls, l, r)
        end)
        local_spawning = false
        if not (ok and actor and actor:IsValid()) then
            spawn_stats.failed = spawn_stats.failed + 1
            log("spawn " .. id .. " failed: " .. tostring(err))
            return
        end
        set_loc_rot(actor, l, r)
        pcall(function()
            local root = actor:K2_GetRootComponent()
            if root:IsSimulatingPhysics() then root:SetSimulatePhysics(false) end
        end)
        spawned[id] = actor
        id_by_fname[short(actor)] = id
        if guard_add_hook then guard_add_hook(actor) end
        spawn_stats.spawned = spawn_stats.spawned + 1
        log(string.format("spawned copy %s = %s (%s) at %s", id, short(actor), cp, fmt(loc_of(actor))))
    end

    -- anything our own game creates that we did not spawn (expected: only proxies of our carries)
    local local_new = {}
    pcall(function()
        NotifyOnNewObject("/Game/WorldObj/Items/BP_ParentItem.BP_ParentItem_C", function(obj)
            if not local_spawning then local_new[#local_new + 1] = obj end
        end)
    end)
    local function local_new_str()
        local t = {}
        for _, o in ipairs(local_new) do
            if o:IsValid() then
                local n = short(o)
                local is_proxy = false
                pcall(function()
                    local _, ci = carried_name(pc)
                    if ci and ci.ProxyItem and ci.ProxyItem:IsValid() and short(ci.ProxyItem) == n then is_proxy = true end
                end)
                t[#t + 1] = n .. (is_proxy and " (proxy of our carried item)" or "")
            else
                t[#t + 1] = "<destroyed>"
            end
        end
        return #t > 0 and table.concat(t, ", ") or "none"
    end

    -- pairing: host items with game-made names -> our own item of the same class, else a copy
    host_named, pair_pending = {}, {}
    local claimed = {}                -- our own items already paired (their names here)
    local pair_stats = { paired = 0, copies = 0 }
    local function resolve_pairs()
        local any = false
        for name, e in pairs(pair_pending) do
            any = true
            pair_pending[name] = nil
            if find_item(name) then
                -- same name here too (same save on both PCs): nothing to pair
            else
                local cls = name:match("^(.+_C)_%d+$")
                local own_proxy
                pcall(function() local _, ci = carried_name(pc) if ci and ci.ProxyItem and ci.ProxyItem:IsValid() then own_proxy = short(ci.ProxyItem) end end)
                local best, bd = nil, 1e12
                for _, it in ipairs((cls and FindAllOf(cls)) or {}) do
                    local n = short(it)
                    local ok = n:match("_C_%d+$") and not claimed[n] and not host_named[n] and n ~= own_proxy and not id_by_fname[n]
                    if ok then
                        pcall(function() local r = it:K2_GetRootComponent() ok = r and r:IsValid() end)
                    end
                    if ok then
                        local d = dist(loc_of(it), e.l)
                        if d < bd then best, bd = it, d end
                    end
                end
                if best then
                    local n = short(best)
                    claimed[n] = true
                    spawned[name] = best
                    id_by_fname[n] = name
                    pcall(function()
                        local root = best:K2_GetRootComponent()
                        if root:IsSimulatingPhysics() then root:SetSimulatePhysics(false) end
                    end)
                    set_loc_rot(best, e.l, e.r)
                    pair_stats.paired = pair_stats.paired + 1
                    log(string.format("paired host %s with our %s (%.0f cm apart)", name, n, bd))
                else
                    spawn_copy(name, e.cp, e.l, e.r)
                    pair_stats.copies = pair_stats.copies + 1
                    log("no item of that class here for host " .. name .. ": spawned a copy")
                end
            end
        end
        return any
    end
    resolve_pairs_tick = function()
        if resolve_pairs() then
            -- our own game-made items the host has not got (a duplicate the host never had)
            local extra = {}
            for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
                local n = short(it)
                if n:match("_C_%d+$") and not claimed[n] and not host_named[n] and not id_by_fname[n] then extra[#extra + 1] = n end
            end
            log(string.format("pairing: %d paired, %d copies spawned; our own game-made items the host does not know: %d %s",
                pair_stats.paired, pair_stats.copies, #extra, table.concat(extra, " "):sub(1, 400)))
        end
    end

    -- terrain edits from the host: the same Voxel plugin call on the same voxel world
    seen_edits = {}
    local sphere_tools, voxel_worlds = nil, {}
    local edit_stats = { ok = 0, failed = 0 }
    apply_terrain_edit = function(id, fn, wname, pos, rad, extra, bs)
        sphere_tools = sphere_tools or StaticFindObject("/Script/Voxel.Default__VoxelSphereTools")
        local w = voxel_worlds[wname]
        if not (w and w:IsValid()) then
            for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do if short(v) == wname then w = v end end
            voxel_worlds[wname] = w
        end
        if not (sphere_tools and sphere_tools:IsValid() and w) then
            edit_stats.failed = edit_stats.failed + 1
            log(string.format("terrain edit %s: cannot apply (%s)", id, not w and ("no voxel world " .. wname) or "no VoxelSphereTools"))
            return
        end
        local before = surface_z(pc, pos.X, pos.Y, pos.Z + 1000, pos.Z - 1000)
        local ok, err = pcall(function()
            if fn == "SetValueSphere" then
                sphere_tools:SetValueSphere({}, {}, w, pos, rad, tonumber(extra), bs[1], bs[2], bs[3], bs[4])
            elseif fn == "RemoveSphereWithDurability" then
                local mn, mx = extra:match("^(%-?%d+):(%-?%d+)$")
                sphere_tools:RemoveSphereWithDurability({}, {}, w, pos, rad, { Min = tonumber(mn), Max = tonumber(mx) }, bs[1], bs[2], bs[3], bs[4])
            else
                sphere_tools[fn](sphere_tools, {}, {}, w, pos, rad, bs[1], bs[2], bs[3], bs[4])
            end
        end)
        if ok then edit_stats.ok = edit_stats.ok + 1 else edit_stats.failed = edit_stats.failed + 1 end
        later(400, function()
            local after = surface_z(pc, pos.X, pos.Y, pos.Z + 1000, pos.Z - 1000)
            log(string.format("terrain edit %s: %s %s at %s r=%.1f -> %s; ground %s -> %s", id, fn, wname, fmt(pos), rad,
                ok and "applied" or ("FAILED " .. tostring(err)),
                tostring(before and string.format("%.1f", before)), tostring(after and string.format("%.1f", after))))
        end)
    end

    -- a restarted host: drop what we made for the old session (its ids mean other items now)
    reset_host_state = function()
        local n = 0
        for id, a in pairs(spawned) do
            if a and a:IsValid() and not claimed[short(a)] then pcall(function() a:K2_DestroyActor() end) n = n + 1 end
        end
        for k in pairs(spawned) do spawned[k] = nil end
        for k in pairs(id_by_fname) do id_by_fname[k] = nil end
        for k in pairs(claimed) do claimed[k] = nil end
        for k in pairs(seen_digs) do seen_digs[k] = nil end
        for k in pairs(seen_edits) do seen_edits[k] = nil end
        log("reset after host restart: removed " .. n .. " copies from the old session")
    end

    local function handle(line)
        local kind, rest = line:match("^%d+|%d+|(%a)|(.*)$")
        if kind == "S" then
            local f = {}
            for v in rest:gmatch("[^|]+") do f[#f + 1] = v end
            local n = {}
            for i = 1, 14 do n[i] = tonumber(f[i]) end
            if #f < 18 then return end
            if f[19] and f[19] ~= host.session then
                if host.session then
                    log("host session changed " .. host.session .. " -> " .. f[19] .. ": the host restarted co-op")
                    game_status("client: the host restarted co-op. Both of you: start a NEW game and press F7 again")
                    reset_host_state()
                else
                    log("host session " .. f[19] .. ", host capabilities " .. tostring(f[20]))
                end
                host.session, host.caps = f[19], f[20] or "-"
                local hv = f[22] or "older than fix5"
                log("host CoopNet version: " .. hv .. " (ours " .. MOD_VERSION .. ")")
                if hv ~= MOD_VERSION then
                    game_status("client: the host runs CoopNet " .. hv .. ", you run " .. MOD_VERSION .. ". Both need the same fix")
                end
                host.seen_seq = 0
            end
            if n[1] <= host.seen_seq then return end
            if host.seen_seq == 0 then game_status("client: connected, the host's world is in charge") end
            host.seen_seq = n[1]
            host.p1, host.p1yaw = vec(n[2], n[3], n[4]), n[5]
            host.p1pitch = tonumber(f[21])
            host.p2 = vec(n[6], n[7], n[8])
            host.p1vel = vec(n[10], n[11], n[12])
            host.p1item, host.p2item = f[15], f[16]
            host.p1dirt, host.p2dirt = tonumber(f[17]), tonumber(f[18])
            local ack = n[13]
            if pc and pc.Pawn and pc.Pawn:IsValid() and hist[ack] then
                local h = hist[ack]
                local d = vec(host.p2.X - h.X, host.p2.Y - h.Y, host.p2.Z - h.Z)
                local err = math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2)
                corr.n = corr.n + 1
                corr.sum_err = corr.sum_err + err
                if err > corr.max_err then corr.max_err = err end
                if corr.win_max and err > corr.win_max and err < 400 then corr.win_max = err end
                if err > 30 and (corr.spike_logs or 0) < 60 then
                    corr.spike_logs = (corr.spike_logs or 0) + 1
                    local me = loc_of(pc.Pawn)
                    local v = pc.Pawn:GetVelocity()
                    log(string.format("spike: seq %d ack %d (age %.0f ms) err %.0f cm d=(%.0f,%.0f,%.0f) | hist %s hostP2 %s now %s | my speed %.0f, last axes fwd %.2f right %.2f, carrying %s",
                        seq, ack, (os.clock() - (h.t or os.clock())) * 1000, err, d.X, d.Y, d.Z, fmt(h), fmt(host.p2), fmt(me),
                        math.sqrt(v.X ^ 2 + v.Y ^ 2), last_axes.fwd, last_axes.right, (my_carried())))
                end
                local k = 0
                if err > 400 then k = 1 corr.snaps = corr.snaps + 1 log(string.format("snap own player: reconciled error %.0f cm", err))
                elseif err > 10 then k = 0.3 corr.blends = corr.blends + 1 end
                if k > 0 then
                    local me = loc_of(pc.Pawn)
                    local nl = vec(me.X + d.X * k, me.Y + d.Y * k, me.Z + d.Z * k)
                    set_loc(pc.Pawn, nl)
                    own.last = nl   -- the correction is not our own movement
                    -- shift the acked line too: several state lines can ack the same input line
                    -- (a backlog, a stall), and each would re-apply the same correction (seen:
                    -- 27 snaps in one tick, 25,900 cm, when a late joiner read a backlog)
                    for s, p in pairs(hist) do
                        if s >= ack then p.X, p.Y, p.Z = p.X + d.X * k, p.Y + d.Y * k, p.Z + d.Z * k end
                    end
                end
                for s in pairs(hist) do if s < ack - 5 then hist[s] = nil end end
            end
            mirror_carry()
        elseif kind == "N" then
            local id, cp, x, y, z, p, yw, r = rest:match("^(N%d+)|([^|]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
            local hname = rest:match("^N%d+|[^|]+|[^|]+|[^|]+|[^|]+|[^|]+|[^|]+|[^|]+|([%w_]+)$")
            if id and not spawned[id] and hname then
                -- after a late join the item came with the host's save, under the host's name
                local ex = item_by_name[hname]
                if not (ex and ex:IsValid()) then rebuild_items() ex = item_by_name[hname] end
                if ex and ex:IsValid() and not id_by_fname[hname] then
                    spawned[id] = ex
                    id_by_fname[hname] = id
                    log(string.format("runtime item %s is our %s (from the host's save)", id, hname))
                end
            end
            if id and not spawned[id] and pc then
                spawn_copy(id, cp, vec(tonumber(x), tonumber(y), tonumber(z)),
                    { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) })
            end
        elseif kind == "X" then
            local name = rest:match("^([%w_]+)")
            local it = name and find_item(name)
            if it then
                it:K2_DestroyActor()
                spawn_stats.destroyed = spawn_stats.destroyed + 1
                log("destroyed copy of " .. name .. " (host says it is gone)")
            end
            if name and spawned[name] then spawned[name] = false end
            if name then item_by_name[name] = nil end
        elseif kind == "I" then
            local body = rest:match("^%d+|(.*)$") or ""
            local mine = pc and my_carried() or "-"
            for name, x, y, z, p, yw, r in body:gmatch("([%w_]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
                host.items = host.items + 1
                -- an item we carry locally (mirrored) is placed by our own carry logic
                if name ~= mine then
                    local it = find_item(name)
                    if it then
                        pcall(function()
                            local root = it:K2_GetRootComponent()
                            if root:IsSimulatingPhysics() then root:SetSimulatePhysics(false) end
                        end)
                        set_loc_rot(it, vec(tonumber(x), tonumber(y), tonumber(z)),
                            { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) })
                        host.applied = host.applied + 1
                    else
                        host.unknown = host.unknown + 1
                        unknown_names[name] = (unknown_names[name] or 0) + 1
                    end
                end
            end
        elseif kind == "Y" then
            local id, tgt, fn, a = rest:match("^(%d+)|([^|]+)|([%w_]+)|(.*)$")
            if not id or seen_anims[id] then return end
            seen_anims[id] = true
            local it
            if tgt == "@P2" then
                local _, ci = carried_name(pc)
                it = ci
            elseif tgt == "@P1" then
                it = host.p1item ~= "-" and find_item(host.p1item) or nil
            else
                it = find_item(tgt)
            end
            if it then
                -- the copy shown in a hand plays the animation, if there is one
                local base_it = it
                pcall(function() local px = it.ProxyItem if px and px:IsValid() then it = px end end)
                local ok, err = pcall(function()
                    if fn == "DirtFX" then it:DirtFX(a == "1")
                    elseif fn == "PlayAnimation" then
                        local secs, mname, mov, rot, opt = a:match("^([%d%.]+),([^,]+),([^,]+),([^,]+),(%d)$")
                        local function asset(path)
                            if path == "-" then return nil end
                            local o = StaticFindObject(path)
                            if not (o and o:IsValid()) then pcall(function() LoadAsset(path:match("^(.-)%.[^%.]+$") or path) end) o = StaticFindObject(path) end
                            return o
                        end
                        local mv, rt = asset(mov), asset(rot)
                        -- the item and the copy in the hand: whichever this player sees
                        local targets = { it }
                        if base_it ~= it then targets[#targets + 1] = base_it end
                        for _, t in ipairs(targets) do
                            local anim, mesh = t.AC_Animator, t[mname]
                            if anim and anim:IsValid() and mesh and mesh:IsValid() then
                                anim:PlayAnimation(tonumber(secs), mesh, mv, rt, opt == "1")
                            end
                        end
                    else it[fn](it) end
                end)
                anim_stats.played = anim_stats.played + (ok and 1 or 0)
                if not ok or anim_stats.played <= 12 or anim_stats.played % 50 == 0 then
                    log(string.format("played %s on %s (%s)%s", fn, tgt, short(it), ok and "" or (": FAILED " .. tostring(err))))
                end
            else
                anim_stats.missing = anim_stats.missing + 1
                if anim_stats.missing <= 12 then log(string.format("anim %s for %s: no such item here", fn, tgt)) end
            end
        elseif kind == "U" then
            local id, tag, path, x, y, z, vol, pitch, two = rest:match("^(%d+)|(%w+)|([^|]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%d%.]+)|([%d%.]+)|(%d)")
            if not id or seen_sounds[id] then return end
            seen_sounds[id] = true
            if two == "1" and tag ~= "P2" then return end   -- the host's own 2D sounds (its menus, its hand)
            local snd = sound_cache[path]
            if not (snd and snd:IsValid()) then
                snd = StaticFindObject(path)
                if not (snd and snd:IsValid()) then pcall(function() LoadAsset(path:match("^(.-)%.[^%.]+$") or path) end) snd = StaticFindObject(path) end
                sound_cache[path] = snd
            end
            local ok, err = false, "sound not found"
            if snd and snd:IsValid() then
                ok, err = pcall(function()
                    if two == "1" then gs:PlaySound2D(pc, snd, tonumber(vol), tonumber(pitch), 0, nil, nil, false)
                    else gs:PlaySoundAtLocation(pc, snd, vec(tonumber(x), tonumber(y), tonumber(z)), { Pitch = 0, Yaw = 0, Roll = 0 },
                        tonumber(vol), tonumber(pitch), 0, nil, nil, nil) end
                end)
            end
            snd_stats.played = snd_stats.played + (ok and 1 or 0)
            if not ok or snd_stats.played <= 20 or snd_stats.played % 50 == 0 then
                log(string.format("sound %s for %s: %s%s", id, tag, path:match("([^/]+)$") or path, ok and "" or (" FAILED " .. tostring(err))))
            end
        elseif kind == "P" then
            local x, y, z, hz = rest:match("^([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
            if x then
                local cz = surface_z(pc, tonumber(x), tonumber(y), tonumber(z) + 1000, tonumber(z) - 1000)
                log(string.format("cmp predig (dug on the host before its save): host ground %.1f, client ground %s, diff %s cm",
                    tonumber(hz), tostring(cz and string.format("%.1f", cz)), cz and string.format("%.1f", math.abs(cz - tonumber(hz))) or "?"))
            end
        elseif kind == "T" then
            local name, st = rest:match("^([%w_]+)|(.*)$")
            if not name then return end
            local it = find_item(name)
            if not it then return end
            local ch = apply_state(it, st)
            -- the copy in our hand (carried item) shows its own meshes
            local mine, it_mine = my_carried()
            if mine == name and it_mine then
                pcall(function()
                    local px = it_mine.ProxyItem
                    if px and px:IsValid() then
                        local chp = apply_state(px, st)
                        if chp ~= "" then ch = ch .. (ch ~= "" and "; " or "") .. "in hand: " .. chp end
                    end
                end)
            end
            if ch ~= "" then log("state " .. name .. ": " .. ch) end
        elseif kind == "A" then
            for name, cp, x, y, z, p, yw, r in rest:gmatch("([%w_]+),([^,;]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
                host_named[name] = true
                if spawned[name] == nil and not pair_pending[name] then
                    pair_pending[name] = { cp = cp, l = vec(tonumber(x), tonumber(y), tonumber(z)),
                                           r = { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) } }
                end
            end
        elseif kind == "W" then
            local id, fn, wname, x, y, z, rad, extra, b1, b2, b3, b4 =
                rest:match("^(%d+)|(%a+)|([%w_]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([^|]+)|(%d)|(%d)|(%d)|(%d)")
            if not id or seen_edits[id] then return end
            seen_edits[id] = true
            apply_terrain_edit(id, fn, wname, vec(tonumber(x), tonumber(y), tonumber(z)), tonumber(rad), extra,
                { b1 == "1", b2 == "1", b3 == "1", b4 == "1" })
        elseif kind == "V" then
            local id, pick, x, y, z, r = rest:match("^(%d+)|(%d)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
            if not id or seen_digs[id] then return end
            seen_digs[id] = true
            local l, rad = vec(tonumber(x), tonumber(y), tonumber(z)), tonumber(r)
            local before = surface_z(pc, l.X, l.Y, l.Z + 1000, l.Z - 1000)
            if host.caps == "W" then
                -- the host sends the exact terrain edits (W lines); nothing to do here but measure
                log(string.format("host dig %s (%s) at %s r=%.0f; ground here before %s", id, pick == "1" and "scoop" or "dump",
                    fmt(l), rad, tostring(before and string.format("%.1f", before))))
            elseif pick == "1" then
                pc:RemoveDirtByLocation(l, rad)
                log(string.format("mirror dig %s: RemoveDirtByLocation at %s r=%.0f", id, fmt(l), rad))
            else
                -- no add-by-location function exists: dump with the game's own MoveDirt from our
                -- aim, which equals host P2's aim (our rotation drives P2)
                pc:MoveDirt(false, rad)
                log(string.format("mirror dump %s: MoveDirt(false) r=%.0f (host point %s)", id, rad, fmt(l)))
            end
            mirror.digs = mirror.digs + 1
            later(500, function()
                local z2, who = surface_z(pc, l.X, l.Y, l.Z + 1000, l.Z - 1000)
                my_dig_z[id] = z2
                log(string.format("client ground at dig %s: %s -> %s (%s)", id, tostring(before and string.format("%.1f", before)),
                    tostring(z2 and string.format("%.1f", z2)), tostring(who)))
            end)
        elseif kind == "Z" then
            local id, hz = rest:match("^(%d+)|([%-%d%.]+)")
            if id and not seen_z[id] then
                seen_z[id] = true
                later(800, function()
                    local cz = my_dig_z[id]
                    log(string.format("cmp dig %s: host ground %.1f, client ground %s, diff %s cm", id, tonumber(hz),
                        tostring(cz and string.format("%.1f", cz)), cz and string.format("%.1f", math.abs(cz - tonumber(hz))) or "?"))
                end)
            end
        elseif kind == "M" then
            local id, name, p1s, p2s, items, gone_list = rest:match("^(%d+)|([%w_]+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if not id or seen_markers[id] then return end
            seen_markers[id] = true
            local its = {}
            for iname, x, y, z in (items or ""):gmatch("([%w_]+)@([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
                its[iname] = vec(tonumber(x), tonumber(y), tonumber(z))
            end
            compare(name, parse_vec(p1s), parse_vec(p2s), its)
            if gone_list and #gone_list > 0 then
                for g in gone_list:gmatch("[%w_]+") do
                    local still = spawned[g] and spawned[g]:IsValid()
                    log(string.format("  gone on host: %s -> client copy %s", g, still and "STILL PRESENT" or "removed"))
                end
            end
            log(string.format("  runtime copies: spawned %d failed %d destroyed %d; items our game made itself: %s",
                spawn_stats.spawned, spawn_stats.failed, spawn_stats.destroyed, local_new_str()))
            if waiting_for[name] then local fn = waiting_for[name] waiting_for[name] = nil later(10, fn) end
        end
    end
    local read_inbox = line_reader(INBOX)
    rebuild_items()

    -- Item copies are puppets of the host: keep their physics off, so local collisions cannot
    -- move them (a spawned copy overlapping the client's own starter item drifted 47 cm before).
    -- 8 items per tick round robin; our own carried item is left to the carry logic.
    local guard_list, guard_cursor, guard_stats = {}, 1, { turned_off = 0 }
    for _, it in pairs(item_by_name) do guard_list[#guard_list + 1] = it end
    function physics_guard_tick()
        local mine = select(2, carried_name(pc))
        for _ = 1, math.min(8, #guard_list) do
            if guard_cursor > #guard_list then guard_cursor = 1 end
            local it = guard_list[guard_cursor]
            if it and it:IsValid() then
                if it ~= mine then
                    pcall(function()
                        local root = it:K2_GetRootComponent()
                        if root and root:IsValid() and root:IsSimulatingPhysics() then
                            root:SetSimulatePhysics(false)
                            guard_stats.turned_off = guard_stats.turned_off + 1
                        end
                    end)
                end
                guard_cursor = guard_cursor + 1
            else
                table.remove(guard_list, guard_cursor)
            end
        end
    end
    guard_add_hook = function(it) guard_list[#guard_list + 1] = it end

    local function dump_items(path)
        local f = io.open(path, "w")
        if not f then return end
        local n = 0
        -- leave out our own held copy (the proxy of the item we carry), as the host leaves out its proxies
        local own_proxy = nil
        pcall(function()
            local _, ci = carried_name(pc)
            if ci and ci.ProxyItem and ci.ProxyItem:IsValid() then own_proxy = short(ci.ProxyItem) end
        end)
        for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do
            local alive = false
            pcall(function() local r = it:K2_GetRootComponent() alive = it:IsValid() and r and r:IsValid() end)
            if alive and own_proxy and short(it) == own_proxy then
                alive = false
                log("dump: leaving out our own held proxy " .. own_proxy)
            end
            if alive then
                local fname = short(it)
                local l = loc_of(it)
                f:write(string.format("%s %.1f %.1f %.1f\n", id_by_fname[fname] or fname, l.X, l.Y, l.Z))
                n = n + 1
            end
        end
        f:close()
        log(string.format("dumped %d items to %s (physics turned off by the guard %d times)", n, path, guard_stats.turned_off))
    end

    local tick = 0
    game_loop(16, function()
        do
            if not pc then return false end
            tick = tick + 1
            local ok, err = pcall(function()
                poll_keys()
                local r = pc:GetControlRotation()
                seq = seq + 1
                out:write(string.format("%d|%.3f|%.3f|%.2f|%.2f|%s\n", seq, acc.fwd, acc.right, r.Pitch, r.Yaw,
                    client_events_line()))
                out:flush()
                last_axes.fwd, last_axes.right = acc.fwd, acc.right
                acc.fwd, acc.right = 0, 0
                local hp = loc_of(pc.Pawn)
                hp.t = os.clock()
                -- own movement since the last tick, excluding our corrections (diagnostic)
                if own.last and own.last_t then
                    local dt = hp.t - own.last_t
                    if dt > 0 then
                        local sp = dist2d(hp, own.last) / dt
                        if last_axes.fwd ~= 0 or last_axes.right ~= 0 then
                            own.sum, own.n = own.sum + sp, own.n + 1
                        end
                    end
                end
                own.last, own.last_t = vec(hp.X, hp.Y, hp.Z), hp.t
                hist[seq] = hp
                read_inbox(handle)
                -- physics_guard_tick() is NOT called: with it on, the client's own player barely
                -- moved (17 cm/s instead of ~330) although it never changed anything (runs A-D,
                -- NOTES phase 4 session 8). The full resend from the host fixes drift on its own.
                if os.getenv("HYDRO_COOP_GUARD") == "1" then physics_guard_tick() end
                if puppet and puppet:IsValid() and host.p1 then
                    local c = loc_of(puppet)
                    local k = 0.35
                    set_loc_rot(puppet, vec(c.X + (host.p1.X - c.X) * k, c.Y + (host.p1.Y - c.Y) * k, c.Z + (host.p1.Z - c.Z) * k),
                        { Pitch = 0, Yaw = host.p1yaw, Roll = 0 })
                    -- the puppet is our hidden local P2's pawn: its controller's rotation drives the
                    -- pawn's yaw every frame (seen: the host never turned on the client), so set both
                    if puppet_pc and puppet_pc:IsValid() then
                        pcall(function() puppet_pc:SetControlRotation({ Pitch = host.p1pitch or 0, Yaw = host.p1yaw, Roll = 0 }) end)
                    end
                    if host.p1vel then pcall(function() puppet.CharacterMovement.Velocity = host.p1vel end) end
                end
                if tick % 30 == 0 and resolve_pairs_tick then resolve_pairs_tick() end
                trace_tick()
                if tick % 30 == 15 then
                    local _, ci = carried_name(pc)
                    if ci then trace_item_class(ci) end
                    local h1 = host.p1item ~= "-" and find_item(host.p1item)
                    if h1 then trace_item_class(h1) end
                end
                if tick % 600 == 0 then
                    local t = {}
                    for nm, c in pairs(unknown_names) do t[#t + 1] = { nm, c } end
                    table.sort(t, function(a, b) return a[2] > b[2] end)
                    local s2 = {}
                    for i = 1, math.min(8, #t) do s2[#s2 + 1] = t[i][1] .. "x" .. t[i][2] end
                    if #t > 0 then log(string.format("host items not found here (last ~20 s): %d names, top: %s", #t, table.concat(s2, " "))) end
                    for k in pairs(unknown_names) do unknown_names[k] = nil end
                    if puppet and puppet:IsValid() then
                        log(string.format("puppet: host P1 yaw %.0f, puppet yaw %.0f, distance to host P1 %.0f cm", host.p1yaw or 0,
                            rot_of(puppet).Yaw, host.p1 and dist(loc_of(puppet), host.p1) or -1))
                    end
                end
                if tick % 125 == 0 and corr.n > 0 then
                    log(string.format("sync: reconciled error avg %.1f max %.1f cm, snaps %d blends %d, items applied %d unknown %d, mirror pickups %d drops %d dirt %d digs %d, local game calls: %s",
                        corr.sum_err / corr.n, corr.max_err, corr.snaps, corr.blends, host.applied, host.unknown,
                        mirror.pickups, mirror.drops, mirror.dirt_sets, mirror.digs, local_calls_str()))
                    corr.max_err, corr.sum_err, corr.n = 0, 0, 0
                end
            end)
            if not ok and tick < 5 then log("client tick error: " .. tostring(err)) end
        end
        return false
    end)

    -- -------- client bot: inputs go out as events only (as polled keys would)
    local function marker(name)
        log(string.format("marker %s client P1 at %s", name, fmt(loc_of(pc.Pawn))))
        push("M", name)
    end
    local function send_tap(down, up)
        push("C", down)
        later(100, function() push("C", up) end)
    end
    local function enc(n) n = math.floor(n + 0.5) return (n < 0 and "m" or "") .. tostring(math.abs(n)) end
    local function debug_tp(l, yaw)
        push("D", string.format("TP_%s_%s_%s_%s", enc(l.X), enc(l.Y), enc(l.Z), enc(yaw)))
        pc.Pawn:K2_TeleportTo(l, { Pitch = 0, Yaw = yaw, Roll = 0 })
    end
    local function request_key(k, after)
        -- the orchestrator presses a real key on this window (checks it is in front first)
        local f = io.open(RUN .. "\\keyreq.txt", "w")
        f:write(k .. "\n") f:close()
        log("requested a real key press: " .. k)
        game_loop(200, function()
            local d = io.open(RUN .. "\\keydone.txt", "r")
            if d then
                local res = d:read("l") d:close()
                os.remove(RUN .. "\\keydone.txt")
                log("orchestrator key press result: " .. tostring(res))
                later(10, after)
                return true
            end
            return false
        end)
    end

    local function find_dirt_spot()
        local vw
        for _, v in ipairs(FindAllOf("VoxelWorld") or {}) do
            if v:GetFName():ToString():find("EmberCradle") then vw = v end
        end
        local c, me = loc_of(vw), loc_of(pc.Pawn)
        local spot, best = nil, 1e12
        for dx = -4000, 4000, 250 do
            for dy = -4000, 4000, 250 do
                local z, who = surface_z(pc, c.X + dx, c.Y + dy, c.Z + 5000, c.Z - 5000)
                if z and who:find("EmberCradle") then
                    local p = vec(c.X + dx, c.Y + dy, z)
                    if dist2d(p, me) < best then best = dist2d(p, me) spot = p end
                end
            end
        end
        return spot
    end

    local shovel
    local function step_real_key()
        -- real E press with the shovel on the ground in front of us
        local sl0 = loc_of(shovel)
        debug_tp(vec(sl0.X + 120, sl0.Y, sl0.Z + 60), 180)
        later(1200, function() aim_pc(pc, loc_of(shovel)) end)
        later(1800, function()
            request_key("E", function()
                later(2000, function()
                    marker("c_realkey_pickup")
                    -- real W hold while carrying the shovel we just picked up with the real E
                    later(1500, function() real_walk(function()
                      later(1500, function()
                        marker("c_end")
                        waiting_for["echo_c_end"] = function()
                            log(string.format("final: polled keys %s; mirror pickups %d drops %d dirt %d digs %d; local game calls: %s",
                                (function() local t = {} for k, v in pairs(polled) do t[#t + 1] = k .. "=" .. v end return table.concat(t, " ") end)(),
                                mirror.pickups, mirror.drops, mirror.dirt_sets, mirror.digs, local_calls_str()))
                            later(1500, function()
                                dump_items(RUN .. "\\items-client.txt")
                                log("coopnet client finished")
                            end)
                        end
                      end)
                    end) end)
                end)
            end)
        end)
    end
    local function step_runtime()
        -- carry one of the host's runtime items through the host (we only see our spawned copy)
        local pick_id, copy
        for id, a in pairs(spawned) do
            if a and a:IsValid() and id ~= host.p1item and id:match("^N%d+$") then
                if not pick_id or tonumber(id:sub(2)) > tonumber(pick_id:sub(2)) then pick_id, copy = id, a end
            end
        end
        if not copy then log("no runtime copy to carry") later(10, step_real_key) return end
        local cl = loc_of(copy)
        log("carrying runtime item " .. pick_id .. " (our copy " .. short(copy) .. ") at " .. fmt(cl))
        debug_tp(vec(cl.X + 120, cl.Y, cl.Z + 60), 180)
        later(1200, function()
            aim_pc(pc, loc_of(copy))
            later(600, function()
                send_tap("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                later(2000, function()
                    marker("c_rt_picked")
                    own_speed_take()
                    drive(1500, function() pc.Pawn:InpAxisEvt_MoveForward_K2Node_InputAxisEvent_0(1.0) end, function()
                        log(string.format("walk carrying spawned copy %s: own speed %.0f cm/s, MaxWalkSpeed %s",
                            (my_carried()), own_speed_take(), str_mws(pc.Pawn)))
                        local me = loc_of(pc.Pawn)
                        local yaw = math.rad(pc:GetControlRotation().Yaw)
                        aim_pc(pc, vec(me.X + math.cos(yaw) * 150, me.Y + math.sin(yaw) * 150, me.Z - 120))
                        later(500, function()
                            send_tap("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                            later(3000, function()
                                marker("c_rt_dropped")
                                later(1500, step_real_key)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    local function step_drop()
        local me = loc_of(pc.Pawn)
        local yaw = math.rad(pc:GetControlRotation().Yaw)
        aim_pc(pc, vec(me.X + math.cos(yaw) * 150, me.Y + math.sin(yaw) * 150, me.Z - 120))
        later(500, function()
            send_tap("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
            later(2500, function()
                marker("c_dropped")
                later(1500, step_runtime)
            end)
        end)
    end
    local function step_dig(spot)
        debug_tp(vec(spot.X + 150, spot.Y, spot.Z + 120), 180)
        later(1200, function()
            aim_pc(pc, spot)
            later(600, function()
                send_tap("InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6")
                later(2500, function()
                    marker("c_dug")
                    -- dump the dirt 1.5 m to the side
                    aim_pc(pc, vec(spot.X, spot.Y + 150, spot.Z))
                    later(600, function()
                        send_tap("InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6")
                        later(2500, function()
                            marker("c_dumped")
                            later(1000, step_drop)
                        end)
                    end)
                end)
            end)
        end)
    end
    local function bot()
        -- the ORIGINAL shovel: nearest BP_ShovelT1_C that is not one of our spawned N copies
        -- (a paired item, our own under the host's name, still counts as original)
        local best, bd = nil, 1e12
        for _, s in ipairs(FindAllOf("BP_ShovelT1_C") or {}) do
            local mapped = id_by_fname[short(s)]
            if not (mapped and mapped:match("^N%d+$")) and live(s) then
                local d = dist2d(loc_of(s), loc_of(pc.Pawn))
                if d < bd then best, bd = s, d end
            end
        end
        shovel = best
        local sl = loc_of(shovel)
        log("shovel " .. short(shovel) .. " at " .. fmt(sl))
        local spot = find_dirt_spot()
        log("dirt spot " .. (spot and fmt(spot) or "none"))
        marker("c_start")
        -- diagnostic baseline: walk 1.5 s carrying nothing
        own_speed_take()
        corr.win_max = 0
        local w0 = loc_of(pc.Pawn)
        drive(1500, function() pc.Pawn:InpAxisEvt_MoveForward_K2Node_InputAxisEvent_0(1.0) end, function()
            log(string.format("BOT walk carrying %s: own speed %.0f cm/s, moved %.0f cm, worst correction %.0f cm, MaxWalkSpeed %s",
                (my_carried()), own_speed_take(), dist2d(w0, loc_of(pc.Pawn)), corr.win_max or 0, str_mws(pc.Pawn)))
            -- same walk with a REAL held W key (the orchestrator holds it on this window)
            later(1500, function()
                pc:SetControlRotation({ Pitch = 0, Yaw = pc:GetControlRotation().Yaw + 180, Roll = 0 })
                later(500, function()
                    real_walk(function() later(1500, function() bot_pickup(sl, spot) end) end)
                end)
            end)
        end)
    end
    -- hold a real W for 2 s on this window; report own speed and corrections during the hold
    function real_walk(after)
        own_speed_take()
        corr.win_max = 0
        local w0 = loc_of(pc.Pawn)
        local carrying = (my_carried())
        request_key("HOLD W 2000", function()
            later(300, function()
                log(string.format("REAL W walk carrying %s: own speed %.0f cm/s, moved %.0f cm, worst correction %.0f cm, MaxWalkSpeed %s",
                    carrying, own_speed_take(), dist2d(w0, loc_of(pc.Pawn)), corr.win_max or 0, str_mws(pc.Pawn)))
                later(10, after)
            end)
        end)
    end
    function bot_pickup(sl, spot)
        debug_tp(vec(sl.X + 120, sl.Y, sl.Z + 60), 180)
        later(1200, function()
            aim_pc(pc, sl)
            later(600, function()
                send_tap("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                later(2000, function()
                    marker("c_picked")
                    -- diagnostic: walk 1.5 s carrying the ORIGINAL shovel, measure own speed
                    own_speed_take()
                    drive(1500, function() pc.Pawn:InpAxisEvt_MoveForward_K2Node_InputAxisEvent_0(1.0) end, function()
                        log(string.format("walk carrying original %s: own speed %.0f cm/s, MaxWalkSpeed %s",
                            (my_carried()), own_speed_take(), str_mws(pc.Pawn)))
                        later(1000, function() step_dig(spot) end)
                    end)
                end)
            end)
        end)
    end
    waiting_for["h_done"] = function() later(1500, bot) end
end

-- ================================================================ host
local function run_host()
    local INBOX, OUTBOX = cfg.host_in, cfg.host_out
    local out = io.open(OUTBOX, "w")
    if not out then log("cannot open host outbox " .. tostring(OUTBOX)) return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local pcs = controllers()
    if #pcs < 2 then log("host needs 2 controllers, have " .. #pcs) return end
    local pc1, pc2 = pcs[1], pcs[2]
    gs:SetForceDisableSplitscreen(pc1, true)
    log("P1 = " .. name_of(pc1) .. ", P2 = " .. name_of(pc2))

    local function who(self)
        local s = self:GetFullName()
        return s == pc2:GetFullName() and "P2" or (s == pc1:GetFullName() and "P1" or s)
    end
    for _, f in ipairs({ "TryPickupItem", "DropItem" }) do
        pcall(function() RegisterHook(CTRL .. f, function(self) log("game call " .. f .. " on " .. who(self:get())) end) end)
    end
    -- action trace: P1/P2 for controllers and pawns, item names as sent on the wire
    local wire_of = function(n) return n end
    trace.label = function(o)
        local s = o:GetFullName()
        if s == pc1:GetFullName() or (pc1.Pawn and s == pc1.Pawn:GetFullName()) then return "P1" end
        if s == pc2:GetFullName() or (pc2.Pawn and s == pc2.Pawn:GetFullName()) then return "P2" end
        local n = short(o)
        return wire_of(n) ~= n and (wire_of(n) .. "/" .. n) or n
    end
    pcall(function() trace_class(StaticFindObject("/Game/BP_GameController.BP_GameController_C")) end)
    pcall(function() local a = FindFirstOf("AC_Animator_C") if a then trace_class(a:GetClass()) end end)

    -- use animations and dig effects: the client plays them on its own copy (seen: the friend never
    -- saw or heard his own shovel swing; his dig only runs on the host)
    --   Y|id|target|fn|arg   target: @P1 / @P2 (the item in that player's hand) or an item name
    local anim_id = 0
    local function send_now(line) out:write(line .. "\n") out:flush() end   -- send() is defined further down
    local function anim_target(it)
        for tag, pc in pairs({ ["@P1"] = pc1, ["@P2"] = pc2 }) do
            local _, ci = carried_name(pc)
            if ci then
                if ci:GetFullName() == it:GetFullName() then return tag end
                local px = ci.ProxyItem
                if px and px:IsValid() and px:GetFullName() == it:GetFullName() then return tag end
            end
        end
        return wire_of(short(it))
    end
    for fn, path in pairs({ PlayPrimaryUseAnim = "/Game/WorldObj/Items/BP_ParentItem.BP_ParentItem_C:PlayPrimaryUseAnim",
                            PlaySecondaryUseAnim = "/Game/WorldObj/Items/BP_ParentItem.BP_ParentItem_C:PlaySecondaryUseAnim" }) do
        local ok, err = pcall(function()
            RegisterHook(path, function(self)
                pcall(function()
                    local tgt = anim_target(self:get())
                    anim_id = anim_id + 1
                    send_now(string.format("Y|%d|%s|%s|-", anim_id, tgt, fn))
                    log(string.format("use anim %d: %s on %s", anim_id, fn, tgt))
                end)
            end)
        end)
        log("anim hook " .. fn .. ": " .. (ok and "ok" or tostring(err)))
    end
    local ok_fx, err_fx = pcall(function()
        -- the shovel parent class path, from a live shovel's class chain
        local c, path = FindFirstOf("BP_ShovelT1_C"):GetClass(), nil
        for _ = 1, 4 do
            if c:GetFName():ToString() == "BP_ParentShovel_C" then path = c:GetFullName():match("^%S+%s+(.+)$") break end
            c = c:GetSuperStruct()
        end
        RegisterHook(path .. ":DirtFX", function(self, show)
            pcall(function()
                local tgt = anim_target(self:get())
                anim_id = anim_id + 1
                send_now(string.format("Y|%d|%s|DirtFX|%s", anim_id, tgt, show:get() and "1" or "0"))
                log(string.format("dig fx %d: DirtFX(%s) on %s", anim_id, tostring(show:get()), tgt))
            end)
        end)
    end)
    log("anim hook DirtFX: " .. (ok_fx and "ok" or tostring(err_fx)))

    -- The swing itself is AC_Animator:PlayAnimation(seconds, mesh, move curve, rotation curve, opt),
    -- called from PlayPrimaryUseAnim. On the client PlayPrimaryUseAnim ran but never reached
    -- PlayAnimation (the friend saw no swing), so send the PlayAnimation call itself.
    local function obj_path(o)
        local p2 = nil
        pcall(function() if o and o:IsValid() then p2 = o:GetFullName():match("^%S+%s+(.+)$") end end)
        return p2 or "-"
    end
    local ok_pa, err_pa = pcall(function()
        local cls = FindFirstOf("AC_Animator_C"):GetClass()
        RegisterHook(obj_path(cls) .. ":PlayAnimation", function(self, secs, mesh, mov, rot, opt)
            pcall(function()
                local comp = self:get()
                local owner = comp:GetOwner()
                if not (owner and owner:IsValid()) then return end
                local tgt = anim_target(owner)
                local m = mesh:get()
                local mname = (m and m:IsValid()) and short(m) or "-"
                anim_id = anim_id + 1
                send_now(string.format("Y|%d|%s|PlayAnimation|%.3f,%s,%s,%s,%s", anim_id, tgt, secs:get(), mname,
                    obj_path(mov:get()), obj_path(rot:get()), opt:get() and "1" or "0"))
            end)
        end)
    end)
    log("anim hook PlayAnimation: " .. (ok_pa and "ok" or tostring(err_pa)))

    -- Sounds: the client's actions run here, so their sounds play here only (the friend heard none).
    -- Sounds the game's blueprints start (GameplayStatics) are sent when they belong to a player:
    -- the object is that player's controller, carried item or its held copy (P1 also its pawn), or
    -- the sound starts within 1.2 s of that player's world action and within 10 m of them.
    -- Not sent: sounds of P2's own pawn (jump, footsteps run on the client too).
    --   U|id|tag|sound|x|y|z|volume|pitch|2d
    local last_act = { P1 = -1e9, P2 = -1e9 }
    recent_drop = {}   -- item full name -> { tag, t } for items a player just let go of
    for _, ev in ipairs({ "InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_RMB_K2Node_InputActionEvent_7",
                          "InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Rotate_K2Node_InputActionEvent_15",
                          "InpActEvt_VehicleKey_K2Node_InputActionEvent_11" }) do
        pcall(function() RegisterHook(CTRL .. ev, function(self)
            local w = who(self:get())
            if w == "P1" or w == "P2" then last_act[w] = os.clock() end
        end) end)
    end
    local function sound_owner_tag(o)
        local tag = nil
        pcall(function()
            if not (o and o:IsValid()) then return end
            local a = o
            pcall(function() local ow = o:GetOwner() if ow and ow:IsValid() then a = ow end end)
            local fa = a:GetFullName()
            for t, pc in pairs({ P1 = pc1, P2 = pc2 }) do
                if fa == pc:GetFullName() then tag = t return end
                if pc.Pawn and fa == pc.Pawn:GetFullName() then tag = (t == "P1") and "P1" or "P2pawn" return end
                local rd = recent_drop[fa]
                if rd and os.clock() - rd.t < 5 then tag = rd.tag return end
                local _, ci = carried_name(pc)
                if ci then
                    if fa == ci:GetFullName() then tag = t return end
                    local px = ci.ProxyItem
                    if px and px:IsValid() and fa == px:GetFullName() then tag = t return end
                end
            end
        end)
        return tag
    end
    local snd_id, snd_stats = 0, { sent = 0, skipped = 0, repeats = 0 }
    -- the same sound at the same spot again within 0.4 s is not sent (seen: a dropped shovel's
    -- bounces played S_DropMetalNormal 20+ times in a second or two)
    local snd_last = {}
    local function on_sound(fn, ctx, snd, loc, vol, pitch, two_d)
        local ok3, err3 = pcall(function()
            local so = snd and snd:IsValid() and snd or nil
            if not so then return end
            local tag = sound_owner_tag(ctx)
            local l = loc
            if not l then pcall(function() local a = ctx l = loc_of(a) end) end
            if not l then pcall(function() l = loc_of(ctx:GetOwner()) end) end
            if not tag and l then
                for t, pc in pairs({ P1 = pc1, P2 = pc2 }) do
                    if os.clock() - last_act[t] < 1.2 and dist(loc_of(pc.Pawn), l) < 1000 then tag = t end
                end
            end
            local sp = obj_path(so)
            -- footsteps come from the walk animation, which plays on the client's puppet too
            if sp:find("Footstep", 1, true) then return end
            -- the client's own jump and landing play on the client already
            if tag == "P2pawn" then
                if sp:find("Jump", 1, true) or sp:find("Land", 1, true) then return end
                tag = "P2"
            end
            if tag ~= "P1" and tag ~= "P2" then
                snd_stats.skipped = snd_stats.skipped + 1
                if snd_stats.skipped <= 20 then log(string.format("sound not sent (%s): %s %s", tostring(tag or "no player"), fn, sp)) end
                return
            end
            l = l or loc_of((tag == "P1" and pc1 or pc2).Pawn)
            local key = string.format("%s@%.0f,%.0f,%.0f", sp, l.X / 50, l.Y / 50, l.Z / 50)
            if snd_last[key] and os.clock() - snd_last[key] < 0.4 then
                snd_last[key] = os.clock()
                snd_stats.repeats = snd_stats.repeats + 1
                return
            end
            snd_last[key] = os.clock()
            snd_id = snd_id + 1
            snd_stats.sent = snd_stats.sent + 1
            send_now(string.format("U|%d|%s|%s|%.1f|%.1f|%.1f|%.2f|%.2f|%d", snd_id, tag, sp, l.X, l.Y, l.Z, vol or 1, pitch or 1, two_d and 1 or 0))
            if snd_stats.sent <= 30 or snd_stats.sent % 50 == 0 then
                log(string.format("sound %d for %s: %s %s at %s", snd_id, tag, fn, sp, fmt(l)))
            end
        end)
        if not ok3 then log("sound hook " .. fn .. " failed: " .. tostring(err3)) end
    end
    local GS = "/Script/Engine.GameplayStatics:"
    local snd_hooks = {
        PlaySoundAtLocation = function(c, sn, lo, ro, v, pi) on_sound("PlaySoundAtLocation", c:get(), sn:get(), lo:get(), v:get(), pi:get(), false) end,
        SpawnSoundAtLocation = function(c, sn, lo, ro, v, pi) on_sound("SpawnSoundAtLocation", c:get(), sn:get(), lo:get(), v:get(), pi:get(), false) end,
        PlaySound2D = function(c, sn, v, pi) on_sound("PlaySound2D", c:get(), sn:get(), nil, v:get(), pi:get(), true) end,
        SpawnSound2D = function(c, sn, v, pi) on_sound("SpawnSound2D", c:get(), sn:get(), nil, v:get(), pi:get(), true) end,
        SpawnSoundAttached = function(sn, comp, ap, lo, ro, lt, st, v, pi) on_sound("SpawnSoundAttached", comp:get(), sn:get(), nil, v:get(), pi:get(), false) end,
    }
    local n_snd = 0
    for fn, cb in pairs(snd_hooks) do
        local okh = pcall(function() RegisterHook(GS .. fn, function(self, ...) cb(...) end) end)
        if okh then n_snd = n_snd + 1 end
    end
    log(string.format("sound hooks set: %d of 5", n_snd))

    local spawn = loc_of(pc1.Pawn)
    local lantern = nearest_item("BP_Lantern_C", spawn)
    local shovel = nearest_item("BP_ShovelT1_C", spawn)

    local tick, last_rx_tick, last_ev, last_seq = 0, -1000, 0, 0
    local last_rx_time = -1e9
    local latest, client_seen = nil, false
    -- P2's movement is replayed every FRAME when the build supports frame loops: the game-thread
    -- timer runs at ~30 Hz (34 ms), and replaying axes only then made P2 walk slower than the
    -- client's real (per-frame) input, so the client was pulled back 35-75 cm on every walk.
    local per_frame = LoopInGameThreadAfterFrames ~= nil
    local frame_calls = 0
    local function replay_axes()
        if latest and os.clock() - last_rx_time <= 0.3 then
            local pawn = pc2.Pawn
            if latest.fwd ~= 0 then pawn:InpAxisEvt_MoveForward_K2Node_InputAxisEvent_0(latest.fwd) end
            if latest.right ~= 0 then pawn:InpAxisEvt_MoveRight_K2Node_InputAxisEvent_1(latest.right) end
            pc2:SetControlRotation({ Pitch = latest.pitch, Yaw = latest.yaw, Roll = 0 })
        end
    end
    if per_frame then
        LoopInGameThreadAfterFrames(1, function()
            frame_calls = frame_calls + 1
            pcall(replay_axes)
        end)
        log("P2 axis replay: every frame (LoopInGameThreadAfterFrames)")
    else
        log("P2 axis replay: on the game-thread timer (no frame loop in this UE4SS)")
    end
    local stats = { lines = 0, lost = 0, events = 0, s_sent = 0, i_sent = 0, i_lines = 0, digs = 0 }
    local out_seq, marker_id, dig_id = 0, 0, 0
    local pending = {}

    local function send(line) out:write(line .. "\n") out:flush() end
    local friend_version = nil
    local held_prev = {}
    local predig = nil           -- test only: a dig made before a late joiner's save
    -- a new id each time co-op starts on the host: the client notices a restarted host
    local session = string.format("%x%06x", os.time(), math.random(0, 0xffffff))
    log("host session " .. session)
    local function send_repeat(line) for i = 0, 2 do pending[#pending + 1] = { tick + i * 5, line } end end
    local marker_extra = function() return "", "" end   -- set by the item tracking below
    local wire_name = function(n) return n end           -- set by the item tracking below
    local function marker(name)
        marker_id = marker_id + 1
        local p1, p2 = loc_of(pc1.Pawn), loc_of(pc2.Pawn)
        local extra, gone_list = marker_extra()
        local items = string.format("%s@%s;%s@%s%s", short(lantern), fmt(loc_of(lantern)), short(shovel), fmt(loc_of(shovel)), extra)
        log(string.format("marker %s P1 %s P2 %s %s | gone %s | carry P2=%s", name, fmt(p1), fmt(p2), items, gone_list,
            wire_name((carried_name(pc2)))))
        send_repeat(string.format("M|%d|%s|%s|%s|%s|%s", marker_id, name, fmt(p1), fmt(p2), items, gone_list))
    end

    -- Terrain edits: the game's digs end in Voxel plugin sphere edits (seen: a shovel scoop is
    -- RemoveSphere(world, pos, 30, true x4), a dump AddSphere(world, pos, 28, true x4)). Send
    -- every such call as it happens, whoever made it; the client makes the same call.
    --   W|id|fn|world|x|y|z|radius|extra|b1|b2|b3|b4   (extra: Value, or Min:Max for durability)
    local voxel_ok, voxel_id = 0, 0
    local edits_log = {}         -- id -> W line, to repeat edits made after a late joiner's save
    local function arg(p) local v = nil pcall(function() v = p:get() end) return v end
    for fn, layout in pairs({ AddSphere = { 3, nil }, RemoveSphere = { 3, nil }, SetValueSphere = { 3, "value" },
                              RemoveSphereWithDurability = { 3, "interval" },
                              AddSphereAsync = { 5, nil }, RemoveSphereAsync = { 5, nil },
                              SetValueSphereAsync = { 5, "value" }, RemoveSphereWithDurabilityAsync = { 5, "interval" } }) do
        local ok, err = pcall(function()
            RegisterHook("/Script/Voxel.VoxelSphereTools:" .. fn, function(self, ...)
                local a = { ... }
                local w, at = layout[1], layout[2]
                local ok2, err2 = pcall(function()
                    local world = arg(a[w]):GetFName():ToString()
                    local pos = arg(a[w + 1])
                    local rad = arg(a[w + 2])
                    local extra, b0 = "-", w + 3
                    if at == "value" then extra = string.format("%.3f", arg(a[w + 3])) b0 = w + 4
                    elseif at == "interval" then local iv = arg(a[w + 3]) extra = iv.Min .. ":" .. iv.Max b0 = w + 4 end
                    local bs = {}
                    for i = 0, 3 do bs[#bs + 1] = arg(a[b0 + i]) and "1" or "0" end
                    voxel_id = voxel_id + 1
                    local base = fn:gsub("Async$", "")
                    local line = string.format("W|%d|%s|%s|%.2f|%.2f|%.2f|%.2f|%s|%s", voxel_id, base, world,
                        pos.X, pos.Y, pos.Z, rad, extra, table.concat(bs, "|"))
                    log(string.format("terrain edit %d: %s %s at %.0f,%.0f,%.0f r=%.1f %s", voxel_id, fn, world, pos.X, pos.Y, pos.Z, rad, extra))
                    edits_log[voxel_id] = line
                    send_repeat(line)
                end)
                if not ok2 then log("terrain edit hook " .. fn .. " failed: " .. tostring(err2)) end
            end)
        end)
        if ok then voxel_ok = voxel_ok + 1 else log("terrain hook " .. fn .. " not set: " .. tostring(err)) end
    end
    log(string.format("terrain hooks set: %d of 8", voxel_ok))

    -- digs: after MoveDirt on any host player, send where and what (the client applies it)
    pcall(function()
        RegisterHook(CTRL .. "MoveDirt", function(self, pickup, radius)
            local c = self:get()
            local pick, rad = pickup:get(), radius:get()
            local l
            pcall(function() local h = c.CrosshairTraceHit l = vec(h.Location.X, h.Location.Y, h.Location.Z) end)
            if not l then log("MoveDirt: no trace location") return end
            dig_id = dig_id + 1
            stats.digs = stats.digs + 1
            local id = dig_id
            log(string.format("game call MoveDirt on %s: pickup=%s radius=%.0f at %s", who(c), tostring(pick), rad, fmt(l)))
            send_repeat(string.format("V|%d|%d|%.1f|%.1f|%.1f|%.1f", id, pick and 1 or 0, l.X, l.Y, l.Z, rad))
            later(500, function()
                local z, hit = surface_z(pc1, l.X, l.Y, l.Z + 1000, l.Z - 1000)
                log(string.format("host ground at dig %d: %s (%s)", id, tostring(z and string.format("%.1f", z)), tostring(hit)))
                if z then send_repeat(string.format("Z|%d|%.1f", id, z)) end
            end)
        end)
    end)

    -- Item tracking spread over ticks: sweep 6 per tick, hot items every tick, proxies (held copies)
    -- skipped, moved items resent every ~2 s.
    -- Runtime items: every new BP_ParentItem_C (NotifyOnNewObject) that is not a proxy gets a net
    -- id "N<k>" ~10 ticks after construction; the host sends N|id|class|transform, and from then on
    -- uses the id on the wire. An item that disappears is sent as X|name-or-id.
    local all_items, cursor, last_sent, hot, moved_ever, proxies = {}, 1, {}, {}, {}, {}
    local pending_new, net_name, net_count, runtime, gone = {}, {}, 0, {}, {}
    local batch = {}
    local function wire(n) return net_name[n] or n end
    wire_of = wire
    local function flush()
        if #batch == 0 then return end
        out_seq = out_seq + 1
        send("I|" .. out_seq .. "|" .. table.concat(batch, ";"))
        stats.i_lines = stats.i_lines + 1
        batch = {}
    end
    for _, it in ipairs(FindAllOf("BP_ParentItem_C") or {}) do all_items[#all_items + 1] = { it = it, n = short(it) } end
    pcall(function()
        NotifyOnNewObject("/Game/WorldObj/Items/BP_ParentItem.BP_ParentItem_C", function(obj)
            pending_new[#pending_new + 1] = { it = obj, t = tick }
        end)
    end)
    local function class_path(it)
        local s = it:GetClass():GetFullName()
        return s:match("^%S+%s+(.+)$") or s
    end
    local function note_proxies()
        for _, pc in ipairs({ pc1, pc2 }) do
            local _, ci = carried_name(pc)
            if ci then pcall(function()
                local px = ci.ProxyItem
                if px and px:IsValid() then proxies[short(px)] = true end
            end) end
        end
    end
    local function register_new()
        for i = #pending_new, 1, -1 do
            local p = pending_new[i]
            if tick - p.t >= 10 then
                table.remove(pending_new, i)
                if p.it:IsValid() then
                    note_proxies()
                    local n = short(p.it)
                    if proxies[n] then
                        stats.proxies_seen = (stats.proxies_seen or 0) + 1
                    elseif not net_name[n] then
                        net_count = net_count + 1
                        local id = "N" .. net_count
                        net_name[n] = id
                        runtime[#runtime + 1] = { id = id, it = p.it, cp = class_path(p.it), fname = n }
                        all_items[#all_items + 1] = { it = p.it, n = n }
                        local l, r = loc_of(p.it), rot_of(p.it)
                        local cp = class_path(p.it)
                        log(string.format("runtime item %s = %s (%s) at %s", id, n, cp, fmt(l)))
                        send_repeat(string.format("N|%s|%s|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%s", id, cp, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, n))
                        last_sent[n] = { X = l.X, Y = l.Y, Z = l.Z, Yaw = r.Yaw, Pitch = r.Pitch }
                        stats.spawned = (stats.spawned or 0) + 1
                    end
                end
            end
        end
    end
    -- A destroyed actor stays IsValid() and in FindAllOf for a while (UE4SS 3.0.1); its root
    -- component is invalid at once (observed after K2_DestroyActor).
    local function alive(it)
        if not it:IsValid() then return false end
        local ok = false
        pcall(function() local r = it:K2_GetRootComponent() ok = r and r:IsValid() or false end)
        return ok
    end
    local function removed(e)
        local w = wire(e.n)
        if not gone[w] and not proxies[e.n] then
            gone[w] = true
            stats.destroyed = (stats.destroyed or 0) + 1
            log("item gone: " .. w)
            send_repeat("X|" .. w)
        end
        hot[e.n] = nil
        moved_ever[e.n] = nil
    end
    -- item state (water, dirt loads, meshes): T|name|state when it changes
    local last_state = {}
    function state_check(e, force)
        local ok, st = pcall(item_state, e.it)
        if not ok then return end
        -- a carried item's held copy shows the state (water in hand): read it from there if present
        pcall(function()
            local px = e.it.ProxyItem
            local by = e.it.BeingCarriedBy
            if px and px:IsValid() and by and by:IsValid() then st = item_state(px) end
        end)
        local prev = last_state[e.n]
        if prev == nil then last_state[e.n] = st return end   -- first look: the client starts the same
        if st ~= prev or (force and prev ~= nil and stats.state_changed and stats.state_changed[e.n]) then
            if st ~= prev then
                stats.state_changed = stats.state_changed or {}
                stats.state_changed[e.n] = true
                log(string.format("item state %s: %s", wire(e.n), st:sub(1, 300)))
            end
            last_state[e.n] = st
            send("T|" .. wire(e.n) .. "|" .. st)
        end
    end
    local function check(e, force)
        local it, n = e.it, e.n
        if not it:IsValid() then return false end
        if proxies[n] then return false end
        local carried = false
        pcall(function()
            local by = it.BeingCarriedBy
            carried = by and by:IsValid() or false
            local px = it.ProxyItem
            if px and px:IsValid() then proxies[short(px)] = true end
        end)
        local l, r = loc_of(it), rot_of(it)
        local prev = last_sent[n]
        local moved = not prev or dist(prev, l) > 2 or math.abs(prev.Yaw - r.Yaw) > 2 or math.abs(prev.Pitch - r.Pitch) > 2
        if moved or force then
            last_sent[n] = { X = l.X, Y = l.Y, Z = l.Z, Yaw = r.Yaw, Pitch = r.Pitch }
            batch[#batch + 1] = string.format("%s,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", wire(n), l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
            stats.i_sent = stats.i_sent + 1
            if #batch >= 10 then flush() end
        end
        if prev and moved then moved_ever[n] = e end
        state_check(e, false)
        if (prev and moved) or carried then hot[n] = { e = e, still = 0 } end
        return moved
    end
    local function scan_tick()
        register_new()
        for n, h in pairs(hot) do
            if not alive(h.e.it) then removed(h.e)
            else
                if check(h.e, false) then h.still = 0 else h.still = h.still + 1 end
                if h.still > 60 then hot[n] = nil end
            end
        end
        for _ = 1, math.min(6, #all_items) do
            if cursor > #all_items then cursor = 1 end
            local e = all_items[cursor]
            if e and alive(e.it) then check(e, false) cursor = cursor + 1
            else
                if e then removed(e) end
                table.remove(all_items, cursor)
            end
        end
        flush()
    end
    local function resend_moved()
        for _, e in pairs(moved_ever) do check(e, true) end
        flush()
    end
    -- slow full resend: 2 items per tick, forced, so every item goes out again every ~4.5 s.
    -- Covers a client copy that drifted on the client while the host's item never moved.
    -- Own batch, sent only when 12 items have collected (~every 6 ticks), so these lines are full;
    -- change-based updates still go out on the tick they happen.
    -- For a friend who starts co-op later: repeat the spawn line of every live runtime item and
    -- the list of removed items every ~5 s (the client ignores ids it already has).
    -- Items that already existed at F7 but carry game-made names (Class_C_<number>: the starter
    -- tools a new game spawns, items from a loaded save). Their names differ between two games, so
    -- the client pairs each with its own item of that class, or spawns a copy (seen: the friend's
    -- pickups of the starter shovel never showed for him, 1,653 updates for a name he did not have).
    --   A|name,classpath,x,y,z,pitch,yaw,roll;...   (8 per line)
    local function announce_named()
        local parts, n = {}, 0
        for _, e in ipairs(all_items) do
            if not net_name[e.n] and not proxies[e.n] and e.n:match("_C_%d+$") and alive(e.it) then
                local l, ro = loc_of(e.it), rot_of(e.it)
                parts[#parts + 1] = string.format("%s,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", e.n, class_path(e.it), l.X, l.Y, l.Z, ro.Pitch, ro.Yaw, ro.Roll)
                n = n + 1
                if #parts >= 8 then send("A|" .. table.concat(parts, ";")) parts = {} end
            end
        end
        if #parts > 0 then send("A|" .. table.concat(parts, ";")) end
        if not stats.named_logged then
            stats.named_logged = true
            log(string.format("items with game-made names (announced for pairing): %d", n))
        end
    end
    local function reannounce()
        announce_named()
        for _, r in ipairs(runtime) do
            if alive(r.it) then
                local l, ro = loc_of(r.it), rot_of(r.it)
                send(string.format("N|%s|%s|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%s", r.id, r.cp, l.X, l.Y, l.Z, ro.Pitch, ro.Yaw, ro.Roll, r.fname))
            end
        end
        for w in pairs(gone) do send("X|" .. w) end
    end
    reannounce_tick = reannounce
    local full_cursor, rbatch = 1, {}
    local function resend_full_tick()
        for _ = 1, math.min(2, #all_items) do
            if full_cursor > #all_items then full_cursor = 1 end
            local e = all_items[full_cursor]
            if e and alive(e.it) and not proxies[e.n] then
                local l, r = loc_of(e.it), rot_of(e.it)
                last_sent[e.n] = { X = l.X, Y = l.Y, Z = l.Z, Yaw = r.Yaw, Pitch = r.Pitch }
                rbatch[#rbatch + 1] = string.format("%s,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", wire(e.n), l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
                state_check(e, true)
                stats.i_sent = stats.i_sent + 1
                stats.i_resent = (stats.i_resent or 0) + 1
            end
            full_cursor = full_cursor + 1
        end
        if #rbatch >= 12 then
            out_seq = out_seq + 1
            send("I|" .. out_seq .. "|" .. table.concat(rbatch, ";"))
            stats.i_lines = stats.i_lines + 1
            stats.r_lines = (stats.r_lines or 0) + 1
            rbatch = {}
        end
    end
    -- test harness: every live item with its wire name, to compare with the client's file
    local function dump_items(path)
        local f = io.open(path, "w")
        if not f then return end
        local n = 0
        for _, e in ipairs(all_items) do
            if alive(e.it) and not proxies[e.n] then
                local l = loc_of(e.it)
                f:write(string.format("%s %.1f %.1f %.1f\n", wire(e.n), l.X, l.Y, l.Z))
                n = n + 1
            end
        end
        f:close()
        log("dumped " .. n .. " items to " .. path)
    end
    wire_name = wire
    marker_extra = function()
        local parts, g = {}, {}
        for _, r in ipairs(runtime) do
            if r.it:IsValid() then parts[#parts + 1] = string.format(";%s@%s", r.id, fmt(loc_of(r.it))) end
        end
        for w in pairs(gone) do g[#g + 1] = w end
        return table.concat(parts), table.concat(g, ",")
    end

    -- late join: save the world, put the files where the relay sends them from
    local join = { busy = false, last = -1e9, mark = 0, late = false }
    local function save_for_join()
        if join.busy or os.clock() - join.last < 20 then return end
        join.busy, join.last, join.late = true, os.clock(), true
        local slot = current_slot(pc1)
        if not slot then
            log("late join: no current save slot")
            send("J|in a world it cannot save (no save slot)")
            join.busy = false
            return
        end
        log("late join: the friend asks for the world; saving slot " .. slot)
        game_status("host: your friend is joining; saving and sending your world ...")
        send("J|saving its world")
        join.mark = voxel_id
        pc1:Autosave()
        local ems = StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary")
        local t0 = os.clock()
        game_loop(500, function()
            local busy = true
            pcall(function() busy = ems:IsSavingOrLoading(pc1) end)
            if os.clock() - t0 < 3 or (busy and os.clock() - t0 < 60) then return false end
            local sd = saved_dir()
            local src = sd and (sd .. "SaveGames/" .. slot .. "/")
            make_dir(cfg.run .. "/save_out")
            local names, total = {}, 0
            for _, n in ipairs(SAVE_FILES) do
                local sz = src and copy_file(src .. n, cfg.run .. "/save_out/" .. n)
                if sz then names[#names + 1] = n total = total + sz end
            end
            if #names == 0 then
                log("late join: cannot read the save in " .. tostring(src))
                send("J|unable to read its save")
                join.busy = false
                return true
            end
            local ready = cfg.run .. "/save_out.ready"
            local f = io.open(ready .. ".part", "w")
            f:write(slot .. "\n" .. table.concat(names, "\n") .. "\n")
            f:close()
            os.remove(ready)
            os.rename(ready .. ".part", ready)
            log(string.format("late join: %d files (%.1f MB) of slot %s ready for the relay; terrain edits after id %d will be repeated",
                #names, total / 1e6, slot, join.mark))
            send(string.format("J|sending its world (%.1f MB)", total / 1e6))
            join.busy = false
            return true
        end)
    end

    local function apply_event(T, name)
        stats.events = stats.events + 1
        if T == "J" then save_for_join() return end
        if T == "L" then
            local n = 0
            for id = join.mark + 1, voxel_id do
                if edits_log[id] then send(edits_log[id]) n = n + 1 end
            end
            log(string.format("late join: the friend loaded our world; repeated %d terrain edits made since the save", n))
            game_status("host: your friend is in your world")
            if predig then send(string.format("P|%.1f|%.1f|%.1f|%.1f", predig.X, predig.Y, predig.Z, predig.ground)) end
            if cfg.bot then later(3000, host_bot) end
            return
        end
        if T == "V" then
            friend_version = name
            log("friend's CoopNet version: " .. name .. " (ours " .. MOD_VERSION .. ")")
            if name ~= MOD_VERSION then
                game_status("host: your friend runs CoopNet " .. name .. ", you run " .. MOD_VERSION .. ". Both need the same fix")
            end
            return
        end
        if T == "M" then
            log(string.format("client marker %s: P2 at %s", name, fmt(loc_of(pc2.Pawn))))
            marker("echo_" .. name)
            if name == "c_end" then
                log(string.format("host summary: lines=%d lost=%d events=%d S=%d items sent=%d in %d lines, digs=%d, runtime items=%d, gone=%d, new proxies skipped=%d",
                    stats.lines, stats.lost, stats.events, stats.s_sent, stats.i_sent, stats.i_lines, stats.digs,
                    stats.spawned or 0, stats.destroyed or 0, stats.proxies_seen or 0))
                log(string.format("resend: %d items in %d full lines", stats.i_resent or 0, stats.r_lines or 0))
                if host_timing_summary then log(host_timing_summary()) end
                later(1500, function() dump_items(cfg.run .. "/items-host.txt") end)
                later(4000, function() log("coopnet host finished") end)
            end
            return
        end
        if T == "D" then
            local n = {}
            for v in name:gmatch("_(m?%d+)") do n[#n + 1] = tonumber((v:gsub("^m", "-"))) end
            if name:sub(1, 3) == "TP_" and #n == 4 then
                pc2.Pawn:K2_TeleportTo(vec(n[1], n[2], n[3]), { Pitch = 0, Yaw = n[4], Roll = 0 })
            end
            return
        end
        local target = (T == "C") and pc2 or pc2.Pawn
        log("replay " .. T .. " " .. name)
        target[name](target, key(key_for(name)))
    end

    local function handle(line)
        local seq, fwd, right, pitch, yaw, evs =
            line:match("^%d+|%d+|(%d+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)|(.*)$")
        if not seq then return end
        seq = tonumber(seq)
        if seq <= last_seq then return end
        if last_seq > 0 and seq > last_seq + 1 then stats.lost = stats.lost + (seq - last_seq - 1) end
        last_seq = seq
        stats.lines = stats.lines + 1
        client_seen = true
        latest = { fwd = tonumber(fwd), right = tonumber(right), pitch = tonumber(pitch), yaw = tonumber(yaw) }
        last_rx_tick = tick
        last_rx_time = os.clock()
        for id, T, name in evs:gmatch("(%d+),(%a),([%w_]+)") do
            id = tonumber(id)
            if id > last_ev then
                last_ev = id
                local ok, err = pcall(apply_event, T, name)
                if not ok then log("replay failed " .. name .. ": " .. tostring(err)) end
            end
        end
    end
    local read_inbox = line_reader(INBOX)

    -- timing: work per tick, per phase, and real time between ticks (os.clock: 1 ms resolution)
    local tm = { sum = 0, n = 0, max = 0, slow = 0, phase = {}, gap_max = 0, gap_sec_max = 0, work_sec_max = 0, last = nil }
    local function phase(name, since)
        local ms = (os.clock() - since) * 1000
        if ms > (tm.phase[name] or 0) then tm.phase[name] = ms end
        return os.clock()
    end
    game_loop(16, function()
        do
            tick = tick + 1
            local t0 = os.clock()
            if tm.last then
                local gap = (t0 - tm.last) * 1000
                if gap > tm.gap_max then tm.gap_max = gap end
                if gap > tm.gap_sec_max then tm.gap_sec_max = gap end
            end
            tm.last = t0
            local tp = t0
            local ok, err = pcall(function()
                read_inbox(handle)
                tp = phase("inbox+replay", tp)
                if not per_frame then replay_axes() end
                if tick % 3 == 0 then
                    local a, b = loc_of(pc1.Pawn), loc_of(pc2.Pawn)
                    local v = pc1.Pawn:GetVelocity()
                    local i1, it1 = carried_name(pc1)
                    local i2, it2 = carried_name(pc2)
                    -- remember what each player just dropped or threw (its landing sounds are theirs)
                    for tg, itx in pairs({ P1 = it1 or false, P2 = it2 or false }) do
                        local prev_c = held_prev[tg]
                        if prev_c and (not itx or prev_c ~= itx) then
                            pcall(function() if prev_c:IsValid() then recent_drop[prev_c:GetFullName()] = { tag = tg, t = os.clock() } end end)
                        end
                        held_prev[tg] = itx or nil
                    end
                    out_seq = out_seq + 1
                    local r1 = pc1:GetControlRotation()
                    send(string.format("S|%d|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%d|%d|%s|%s|%d|%d|%s|%s|%.1f|%s", out_seq,
                        a.X, a.Y, a.Z, r1.Yaw, b.X, b.Y, b.Z, pc2:GetControlRotation().Yaw,
                        v.X, v.Y, v.Z, last_seq, last_ev, wire(i1), wire(i2), dirt_flag(it1), dirt_flag(it2),
                        session, voxel_ok > 0 and "W" or "-", r1.Pitch, MOD_VERSION))
                    stats.s_sent = stats.s_sent + 1
                end
                tp = phase("axes+S", tp)
                scan_tick()
                tp = phase("item scan", tp)
                if tick % 125 == 60 then resend_moved() end
                if os.getenv("HYDRO_COOP_NO_RESEND") ~= "1" then resend_full_tick() end
                if tick % 150 == 75 and reannounce_tick then reannounce_tick() end
                tp = phase("resend", tp)
                for i = #pending, 1, -1 do
                    if pending[i][1] <= tick then send(pending[i][2]) table.remove(pending, i) end
                end
            end)
            if not ok and tick < 5 then log("host tick error: " .. tostring(err)) end
            local work = (os.clock() - t0) * 1000
            if client_seen then
                tm.sum, tm.n = tm.sum + work, tm.n + 1
                if work > tm.max then tm.max = work end
                if work > 4 then tm.slow = tm.slow + 1 end
                if work > tm.work_sec_max then tm.work_sec_max = work end
                trace_tick()
                if tick % 30 == 15 then
                    local _, c1 = carried_name(pc1)
                    local _, c2 = carried_name(pc2)
                    if c1 then trace_item_class(c1) end
                    if c2 then trace_item_class(c2) end
                end
                if tick % 62 == 0 then
                    local v = pc2.Pawn:GetVelocity()
                    log(string.format("host second: P2 speed %.0f (MaxWalkSpeed %s, carrying %s), tick gap max %.0f ms, work max %.0f ms, client lines %d, per-frame replays %d",
                        math.sqrt(v.X ^ 2 + v.Y ^ 2), str_mws(pc2.Pawn), wire((carried_name(pc2))), tm.gap_sec_max, tm.work_sec_max, stats.lines, frame_calls))
                    frame_calls = 0
                    tm.gap_sec_max, tm.work_sec_max = 0, 0
                end
            end
        end
        return false
    end)
    host_timing_summary = function()
        local ph = {}
        for k, v in pairs(tm.phase) do ph[#ph + 1] = string.format("%s %.0f", k, v) end
        return string.format("host tick work avg %.2f ms max %.0f ms, ticks over 4 ms %d of %d, longest gap between ticks %.0f ms; phase max ms: %s",
            tm.sum / math.max(1, tm.n), tm.max, tm.slow, tm.n, tm.gap_max, table.concat(ph, ", "))
    end

    -- -------- host bot: runtime items through the game's own spawn path
    local function tap1(down, up)
        pc1[down](pc1, key(key_for(down)))
        later(100, function() pc1[up](pc1, key(key_for(up))) end)
    end
    local function live_runtime()
        local t = {}
        for _, r in ipairs(runtime) do if r.it:IsValid() then t[#t + 1] = r end end
        return t
    end
    -- bucket water: fill and empty a bucket on the host; the client should mirror both
    local function bucket_step(after)
        local b
        for _, r in ipairs(live_runtime()) do if r.cp:find("BP_Bucket", 1, true) then b = r end end
        if not b then log("bucket test: no bucket") after() return end
        log("bucket test: " .. b.id .. " before: " .. item_state(b.it))
        pcall(function() b.it["HasLiquidType?"] = 1 end)
        local ok, err = pcall(function() b.it:HasWater() end)
        log("bucket test: HasWater() " .. (ok and "called" or tostring(err)))
        later(4000, function()
            log("bucket test: after HasWater: " .. item_state(b.it))
            marker("h_bucket_full")
            local ok2, err2 = pcall(function() b.it:EmptyLiquid() end)
            log("bucket test: EmptyLiquid() " .. (ok2 and "called" or tostring(err2)))
            later(4000, function()
                log("bucket test: after EmptyLiquid: " .. item_state(b.it))
                marker("h_bucket_empty")
                after()
            end)
        end)
    end
    function host_bot()
        marker("h_start")
        log("calling GM_Hydroneer.SpawnInitialItems() (the game's starter-item spawn)")
        FindFirstOf("GM_Hydroneer_C"):SpawnInitialItems()
        later(4000, function()
            local rs = live_runtime()
            log("runtime items after spawn: " .. #rs)
            marker("h_spawned")
            if #rs < 3 then log("need 3 runtime items for the test") marker("h_done") return end
            -- P1 carries the first one 1.5 m and drops it
            local a = rs[1]
            local al = loc_of(a.it)
            pc1.Pawn:K2_TeleportTo(vec(al.X + 120, al.Y, al.Z + 60), { Pitch = 0, Yaw = 180, Roll = 0 })
            later(800, function()
                aim_pc(pc1, loc_of(a.it))
                later(500, function()
                    tap1("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                    later(1500, function()
                        log("P1 carries " .. wire((carried_name(pc1))) .. " (wanted " .. a.id .. ")")
                        drive(1500, function() pc1.Pawn:InpAxisEvt_MoveRight_K2Node_InputAxisEvent_1(1.0) end, function()
                            local me = loc_of(pc1.Pawn)
                            local yaw = math.rad(pc1:GetControlRotation().Yaw)
                            aim_pc(pc1, vec(me.X + math.cos(yaw) * 150, me.Y + math.sin(yaw) * 150, me.Z - 120))
                            later(400, function()
                                tap1("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                                later(3000, function()
                                    marker("h_moved")
                                    -- stand-in for "sold/consumed": the host destroys the second one
                                    local b = rs[2]
                                    log("destroying " .. b.id .. " on the host")
                                    b.it:K2_DestroyActor()
                                    later(3000, function()
                                        marker("h_destroyed")
                                        later(500, function() bucket_step(function() marker("h_done") end) end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    game_loop(250, function()
        if client_seen then
            log("client connected")
            game_status("host: your friend is connected")
            -- clients before fix 5 send no version
            later(8000, function()
                if not friend_version then
                    log("friend sent no CoopNet version: older than fix5")
                    game_status("host: your friend runs an OLDER CoopNet (before fix5), you run " .. MOD_VERSION .. ". Both need the same fix")
                end
            end)
            if cfg.bot and not join.late then later(3000, host_bot) end
            return true
        end
        return false
    end)
    -- test only: change the world before a late joiner comes (items made after F7, one dig), so the
    -- test proves the friend gets them through the save
    if cfg.mode ~= "play" and os.getenv("HYDRO_COOP_TEST_PREWORLD") == "1" then
        later(4000, function()
            log("preworld test: SpawnInitialItems() and one dig before the friend joins")
            FindFirstOf("GM_Hydroneer_C"):SpawnInitialItems()
            -- a real dig by P1 with the starter shovel: a Lua RemoveSphere is not kept in the save
            -- (first late-join run: the friend's ground stayed 11.6 cm higher); the game's own dig is
            local shovel
            for _, it in ipairs(FindAllOf("BP_ShovelT1_C") or {}) do
                if short(it):match("_C_%d+$") and not shovel then shovel = it end
            end
            if not shovel then log("preworld test: no starter shovel") return end
            -- from the far side (the friend's bot comes from +X later), after the new items settled
            later(3000, function()
            local sl = loc_of(shovel)
            pc1.Pawn:K2_TeleportTo(vec(sl.X - 120, sl.Y, sl.Z + 60), { Pitch = 0, Yaw = 0, Roll = 0 })
            later(1000, function()
                aim_pc(pc1, loc_of(shovel))
                later(600, function()
                    aim_pc(pc1, loc_of(shovel))
                    tap1("InpActEvt_Pickup_K2Node_InputActionEvent_12", "InpActEvt_Pickup_K2Node_InputActionEvent_13")
                    later(1500, function()
                        log("preworld test: P1 picked up " .. tostring((carried_name(pc1))) .. " (" .. short(shovel) .. " wanted)")
                        local x, y = 22700, 6100
                        local z0 = surface_z(pc1, x, y, 2000, -2000)
                        if not z0 then log("preworld test: no ground at the dig spot") return end
                        -- the friend's bot's dig approach: 1.5 m off, 1.2 m up, aim, click (twice if needed)
                        pc1.Pawn:K2_TeleportTo(vec(x + 150, y, z0 + 120), { Pitch = 0, Yaw = 180, Roll = 0 })
                        later(1500, function()
                            aim_pc(pc1, vec(x, y, z0))
                            later(800, function()
                                aim_pc(pc1, vec(x, y, z0))
                                log("preworld test: P1 carries " .. tostring((carried_name(pc1))) .. ", digging at " .. x .. "," .. y)
                                tap1("InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6")
                                later(1500, function()
                                    local zc = surface_z(pc1, x, y, 2000, -2000)
                                    if zc and math.abs(zc - z0) < 1 then
                                        log("preworld test: no change after the first click, clicking again")
                                        aim_pc(pc1, vec(x, y, z0))
                                        tap1("InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6")
                                        later(1000, function()
                                            local zd = surface_z(pc1, x, y, 2000, -2000)
                                            if zd and math.abs(zd - z0) < 1 then
                                                log("preworld test: still no change, third click from closer")
                                                pc1.Pawn:K2_TeleportTo(vec(x + 110, y, z0 + 110), { Pitch = 0, Yaw = 180, Roll = 0 })
                                                later(800, function()
                                                    aim_pc(pc1, vec(x, y, z0))
                                                    tap1("InpActEvt_LMB_K2Node_InputActionEvent_5", "InpActEvt_LMB_K2Node_InputActionEvent_6")
                                                end)
                                            end
                                        end)
                                    end
                                end)
                                later(5500, function()
                                    local z1 = surface_z(pc1, x, y, 2000, -2000)
                                    predig = { X = x, Y = y, Z = z0, ground = z1 or -1 }
                                    log(string.format("preworld test: P1 dug at %d,%d: ground %.1f -> %s", x, y, z0, tostring(z1 and string.format("%.1f", z1))))
                                    -- out of the friend's bot's way
                                    pc1.Pawn:K2_TeleportTo(vec(x + 900, y - 600, z0 + 150), { Pitch = 0, Yaw = 0, Roll = 0 })
                                end)
                            end)
                        end)
                    end)
                end)
            end)
            end)
        end)
    end
    game_status("host: co-op running, waiting for your friend to press F7")
    local f = io.open(cfg.ready, "w")
    if f then f:write("ready\n") f:close() end
    log("host ready")
end

-- ================================================================ late join (client)
-- At the main menu: ask the host for its world, wait for the relay to bring the save, copy it into
-- our CoopNetHost slot, load it the way the save manager does, then start the normal client.
local function load_slot(slot, after)
    local gm = FindFirstOf("GM_Hydroneer_C")
    StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):SetCurrentSaveGameName(gm, slot)
    -- Continue opens the save manager; there: select the slot and continue
    FindFirstOf("UI_MainMenu_C"):BndEvt__UI_MainMenu_ContinueButton_1_K2Node_ComponentBoundEvent_14_OnButtonClickedEvent__DelegateSignature()
    later(2500, function()
        local sm = FindFirstOf("UI_Menu_SaveManager_C")
        if not (sm and sm:IsValid()) then
            log("late join: the save manager did not open")
            game_status("client: could not open the game's save manager; load the save 'CoopNetHost' yourself, then press F7")
            return
        end
        sm:SaveSelected(slot)
        later(1500, function()
            sm:ContinueMainGame()
            local t0 = os.clock()
            game_loop(500, function()
                if in_game() then
                    log("late join: the host's world is loaded")
                    later(6000, after)
                    return true
                end
                if os.clock() - t0 > 180 then
                    log("late join: the world did not load in 3 minutes")
                    game_status("client: the host's world did not load; load the save 'CoopNetHost' yourself, then press F7")
                    return true
                end
                return false
            end)
        end)
    end)
end

local function late_join(start_client)
    log("late join: asking the host for its world")
    game_status("client: asking the host for its world ...")
    local out = client_outbox()
    local read_status = line_reader(cfg.client_in)
    local ready = cfg.run .. "/save_in.ready"
    local asked_at, t0, ev = -1e9, os.clock(), client_ev
    client_ev = client_ev + 2      -- the join request and our version
    game_loop(250, function()
        -- the request goes out every 2 s until the save is here (the host ignores repeats)
        if os.clock() - asked_at > 2 then
            asked_at = os.clock()
            client_seq = client_seq + 1
            out:write(string.format("%d|0.000|0.000|0.00|0.00|%d,J,late;%d,V,%s\n", client_seq, ev, ev + 1, MOD_VERSION))
            out:flush()
        end
        read_status(function(line)
            local st = line:match("^%d+|%d+|J|(.*)$")
            if st then log("host: " .. st) game_status("client: the host is " .. st) end
        end)
        local f = io.open(ready, "r")
        if f then
            local slot = f:read("l")
            local names = {}
            for l in f:lines() do if l ~= "" then names[#names + 1] = l end end
            f:close()
            os.remove(ready)
            local sd = saved_dir()
            local dst = sd and (sd .. "SaveGames/" .. JOIN_SLOT .. "/")
            if not dst then log("late join: no Saved folder") game_status("client: cannot find the game's save folder") return true end
            make_dir(dst)
            local copied, total = 0, 0
            for _, n in ipairs(names) do
                local sz = copy_file(cfg.run .. "/save_in/" .. n, dst .. n)
                if sz then copied, total = copied + 1, total + sz else log("late join: could not write " .. dst .. n) end
            end
            log(string.format("late join: host slot %s, %d of %d files (%.1f MB) copied to %s", tostring(slot), copied, #names, total / 1e6, dst))
            if copied < #names then game_status("client: could not store the host's world in the save folder") return true end
            game_status("client: loading the host's world ...")
            load_slot(JOIN_SLOT, start_client)
            return true
        end
        if os.clock() - t0 > 300 then
            log("late join: no world from the host after 5 minutes")
            game_status("client: no world from the host after 5 minutes. Is the host in a world with co-op running (F7)?")
            return true
        end
        return false
    end)
end

-- ================================================================ startup
local started = false
local function start_coop()
    if started then return end
    if cfg.mode ~= "test" then
        local f = io.open(cfg.run .. "/role.txt", "r")
        local r = f and f:read("l")
        if f then f:close() end
        if r ~= "host" and r ~= "client" then
            game_status("F7 pressed, but no relay is running: start Host.bat or Join.bat first")
            return
        end
        ROLE = r
    end
    if not in_game() then
        if ROLE == "client" then
            -- at the main menu: join late, in the host's world
            started = true
            late_join(function()
                late_joined = true
                log("starting co-op as client (late join)")
                run_client()
            end)
        else
            game_status("F7 pressed at the main menu: the host starts or loads a world first, then presses F7")
        end
        return
    end
    local pc = controllers()[1]
    if not (pc and pc.Pawn and pc.Pawn:IsValid()) then
        game_status("F7 pressed outside a world: start or load a game first")
        return
    end
    started = true
    log("starting co-op as " .. ROLE)
    if ROLE == "host" then
        FindFirstOf("GM_Hydroneer_C"):AddLocalPlayer()
        log("host added P2")
        later(5000, run_host)
    else
        run_client()
    end
end

if cfg.mode == "play" then
    RegisterKeyBind(Key.F7, function() ExecuteInGameThread(function()
        local ok, err = pcall(start_coop)
        if not ok then log("start failed: " .. tostring(err)) end
    end) end)
    game_status("mod loaded: host: load a world and press F7; friend: press F7 at the main menu to join")
else
    -- harness: start a new game, then do what F7 does (a late-joining test client stays at the
    -- menu and presses "F7" there)
    if os.getenv("HYDRO_COOP_LATEJOIN") == "1" then
        later(45000, function()
            log("late join test: F7 at the main menu")
            start_coop()
        end)
    else
        later(20000, function()
            log("NewGame on " .. tostring(ROLE or "?"))
            FindFirstOf("GM_Hydroneer_C"):NewGame()
            later(60000, start_coop)
        end)
    end
end
