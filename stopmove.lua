--[[
    stopmove - Ashita v4 addon
    Blocks the numpad movement keys while you are casting a spell, so you can't
    accidentally interrupt the cast by walking. Optionally turns Multisend follow
    and the in-game auto-follow (/follow) off for the length of the cast and back
    on afterwards.

    Multi-client: if you run a second FFXI client with this addon loaded, the two
    copies detect each other. The on-screen box shows one row per character, and
    each row's ON/OFF button controls that character independently.

    Commands:
        /stopmove            open / close the settings window
        /stopmove on|off     turn stopmove on or off for THIS character
        /stopmove resetbox   put the on-screen box back at normal size, top-left
        /stopmove move       Allow Move: end the cast lock now (same as the widget button)

    NOTE: Keyboard movement only. Gamepad / mouse movement is not blocked.
--]]

addon.name    = 'stopmove'
addon.author  = 'Claude'
addon.version = '3.0'
addon.desc    = 'Blocks numpad movement while casting (toggleable, multi-client aware).'
addon.link    = ''

require('common')
local imgui = require('imgui')
local ffi   = require('ffi')

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
local enabled  = true   -- master toggle (starts ON when loaded)
local block_keys = true   -- disable keyboard movement (numpad) while casting
local block_wasd = false  -- ... and also W/A/S/D
local lock_pos   = false  -- lock the on-screen box position and size

-- Multisend follow: turned off when a cast starts, back on after it ends.
--   ms_off_cmd : chat command sent when the cast starts   (blank = send nothing)
--   ms_on_cmd  : chat command sent when the cast ends     (blank = send nothing)
local ms_enabled = true
local ms_off_cmd = '/ms follow off'
local ms_on_cmd  = '/ms follow on'
local ms_quiet   = true    -- hide Multisend's "Follow is currently ..." reply to our own commands
local QUIET_FOR  = 3       -- seconds after we send a command during which its reply is hidden
local quiet_until = 0

-- In-game auto-follow (/follow): stopped while casting, resumed on the same target after.
local gf_enabled = true
local gf_saved   = nil     -- { target index, server id } of the follow we stopped
local gf_name    = ''      -- if set: after every cast, make sure we are following this character
local CONFIRM_WITHIN = 3    -- seconds to see the cast actually begin before assuming the request failed
local inject   = true   -- on cast start, send a key-release for movement keys you are holding
local UNLOCK_DONE = 0.0   -- seconds before follow comes back after a COMPLETED cast
local UNLOCK_INT  = 10.0  -- seconds before follow comes back after an INTERRUPTED cast
local MAX_LOCK = 9      -- hard cap: movement lock / follow-off never lasts longer than this many seconds

local HEARTBEAT_EVERY = 1    -- seconds between "I'm alive" writes
local CLIENT_TIMEOUT  = 6    -- another client is considered gone after this many seconds
local POLL_EVERY      = 0.3  -- seconds between checks of the shared toggle file

-- DirectInput scan codes (used by the 'key_data' event)
local dik_keys = {
    [0x48] = true, [0x50] = true, [0x4B] = true, [0x4D] = true, -- Numpad 8/2/4/6 (arrow keys are NOT locked)
}
-- Also locked when "Also disable WASD" is ticked
local dik_wasd = { [0x11] = true, [0x1E] = true, [0x1F] = true, [0x20] = true }

-- Windows virtual-key codes (used by the 'key' event)
local vk_keys = {
    [0x68] = true, [0x62] = true, [0x64] = true, [0x66] = true, -- Numpad 8/2/4/6 (arrow keys are NOT locked)
}
local vk_wasd = { [0x57] = true, [0x53] = true, [0x41] = true, [0x44] = true }

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
-- wait-until-stopped state (see the 'wait' section further down)
local wait_for_stop = true    -- ON by default
local WAIT_STILL    = 0.15   -- seconds of no movement required (tune live: /stopmove still <sec>)
local WAIT_MAX      = 1.0    -- never hold the request longer than this
local pending       = nil    -- { bytes = {...}, since = clock }
local resending     = false
local resend_clock  = 0
local last_x, last_y = 0, 0
local last_move     = 0      -- os.clock() when position last changed

local show_ui      = true
local low_profile  = false  -- compact widget: first letter of each name only
local letter_badge = false  -- low profile: letter drawn inside the ON/OFF shape (smallest widget)
local show_cfg_btn = false  -- (the widget's UI / Allow Move buttons were removed: settings open with a
local show_move_btn = false --  right-click or /stopmove, and Allow Move is in the settings or /stopmove move)
local circle_fail  = false   -- set if drawing a circle failed (falls back to squares)
local bg_fail      = false   -- set if the ImGui draw-list background failed (falls back to a plain window)
local layout_mode  = 0      -- 0 = stacked rows, 1 = inline (name then status, long and skinny)
local rot          = 0      -- box rotation: 0, 1, 2, 3  =  0, 90, 180, 270 degrees
local refit        = true   -- resize the box to fit its content on the next frame
local last_sig     = nil
local last_scale   = 1.0
local PAD          = 6      -- window padding of the on-screen box (2 in letter-in-shape mode)

-- per-character box position/scale (saved to char_<name>.txt) and shared-settings sync
local char_loaded        = false
local char_pos           = nil     -- { x, y } to apply once after the saved file is read
local char_saved         = {}      -- last values written for this character
local last_char_write    = 0
local last_blob          = nil     -- last text of settings.txt that we wrote or read
local last_settings_check = 0
local ui_alpha     = 1.0     -- overall opacity of the on-screen box (config screen)
local cfg_open     = { false }   -- settings window visible?

-- Appearance settings (edited in the settings window, saved to settings.txt)
local function default_style()
    return {
        bg       = { 0.06, 0.06, 0.08, 0.92 },   -- box background
        border   = { 0.45, 0.45, 0.52, 1.00 },   -- box border colour
        border_w = 1.0,                           -- box border width
        bg_style = 0,                             -- 0 = solid colour, 1 = FFXI menu (blue gradient + stripes)
        -- Colours measured from the in-game Magic menu: grey-purple at the top, darker
        -- through the middle, bluer at the bottom, with 2px dark stripes every 4px.
        menu_top    = { 0.153, 0.153, 0.275, 1.0 },
        menu_mid    = { 0.110, 0.110, 0.267, 1.0 },
        menu_bottom = { 0.153, 0.149, 0.361, 1.0 },
        menu_stripes   = true,
        menu_frame     = true,                    -- classic FFXI window frame (light outer line, dark inner line)
        lock_name_tint = true,                    -- name turns orange while that character is locked (like the selected menu item)
        menu_stripe_a  = 0.45,
        bg_w_add = 0,                             -- background wider/narrower than the box (pixels)
        bg_h_add = 0,                             -- background taller/shorter than the box (pixels)
        name  = { color = { 0.88, 0.88, 0.96, 1 }, shadow = true, bold = false, size = 1.0,
                  outline = false, outline_color = { 0, 0, 0, 1 }, outline_w = 1.0 },  -- character-name text
        state = { color = { 0.88, 0.88, 0.96, 1 }, shadow = true, bold = false, size = 1.0,
                  outline = false, outline_color = { 0, 0, 0, 1 }, outline_w = 1.0 },  -- ON/OFF text
        on_col   = { 0.15, 0.55, 0.20, 1.0 },    -- ON button
        off_col  = { 0.55, 0.15, 0.15, 1.0 },    -- OFF button
        lock_col = { 0.80, 0.55, 0.10, 1.0 },    -- LOCK (casting) button
        badge_text = true,                        -- show ON / OFF / LOCK text inside the badge
        badge_circle = false,                     -- ON/OFF shown in a circle instead of a square box
    }
end
local S = default_style()

-- Put the FFXI-menu colours (gradient + stripes) back to their defaults.
local function reset_menu_colors()
    local d = default_style()
    S.menu_top     = d.menu_top
    S.menu_mid     = d.menu_mid
    S.menu_bottom  = d.menu_bottom
    S.menu_stripes = d.menu_stripes
    S.menu_frame   = d.menu_frame
    S.menu_stripe_a = d.menu_stripe_a
end
local casting      = false
local cast_started = 0
local cast_need    = 0     -- the spell's own cast time + a margin: the failsafe never fires before it
local int_until    = 0     -- the widget flashes INT until then, after a cast was interrupted
local INT_FLASH    = 2     -- seconds of INT on the widget

-- multi-client sync state
local sync_dir       = nil
local other_clients  = {}      -- [name] = { enabled = bool } for each live second client
local other_names    = {}      -- sorted list of the names above (stable UI order)
local other_count    = 0
local last_heartbeat = 0
local pub_locked = 0      -- lock state last published to the other client
local last_poll      = 0
local last_scan      = 0
local hb_file        = nil
local cmd_primed     = false   -- have we read (and ignored) any stale command file yet?
local last_cmd       = nil
local cmd_counter    = 0

-- Movement keys we believe are physically held right now (VK -> true)
local held_vk = {}

-- VK -> { scancode, extended } used when we send a key-release ourselves
local vk_scan = {
    [0x68] = { 0x48, false }, [0x62] = { 0x50, false }, [0x64] = { 0x4B, false }, [0x66] = { 0x4D, false },
    [0x57] = { 0x11, false }, [0x53] = { 0x1F, false }, [0x41] = { 0x1E, false }, [0x44] = { 0x20, false },
}

local user32   = nil
local kernel32 = nil
pcall(function()
    ffi.cdef[[
        void     keybd_event(uint8_t bVk, uint8_t bScan, uint32_t dwFlags, uintptr_t dwExtraInfo);
        void*    GetForegroundWindow(void);
        uint32_t GetWindowThreadProcessId(void* hWnd, uint32_t* lpdwProcessId);
        uint32_t GetCurrentProcessId(void);
        int16_t  GetAsyncKeyState(int vKey);
    ]]
    user32   = ffi.load('user32')
    kernel32 = ffi.load('kernel32')
end)

-- Is THIS client's game window the one in front?
--   true / false = known, nil = could not be determined
local function foreground_state()
    if not user32 or not kernel32 then return nil end
    local ok, result = pcall(function()
        local hwnd = user32.GetForegroundWindow()
        if hwnd == nil then return false end
        local pid = ffi.new('uint32_t[1]')
        user32.GetWindowThreadProcessId(hwnd, pid)
        -- the window in front belongs to THIS game process?
        return pid[0] == kernel32.GetCurrentProcessId()
    end)
    if not ok then return nil end
    return result
end

-- Send a key-release for any movement key currently held, so the character
-- stops running the moment a cast starts (only while this client has focus).
local function release_held_keys()
    if not (block_keys and inject) or not user32 then return end
    -- Key-releases go to whichever window is in front, so only send them when
    -- we KNOW this client is the one in front (never guess).
    if foreground_state() ~= true then return end
    for vk in pairs(held_vk) do
        local info = vk_scan[vk]
        if info then
            local flags = 0x0002                       -- KEYEVENTF_KEYUP
            if info[2] then flags = flags + 0x0001 end -- KEYEVENTF_EXTENDEDKEY
            pcall(function() user32.keybd_event(vk, info[1], flags, 0) end)
        end
    end
end

-- After "Allow Move": a movement key you were already holding had its press
-- blocked, so the game thinks it is up. Send a fresh key-down for each one.
local function repress_held_keys()
    if not user32 or foreground_state() ~= true then return end
    for vk, info in pairs(vk_scan) do
        if vk_keys[vk] or (block_wasd and vk_wasd[vk]) then
            pcall(function()
                if bit.band(user32.GetAsyncKeyState(vk), 0x8000) ~= 0 then
                    user32.keybd_event(vk, info[1], 0, 0)
                end
            end)
        end
    end
end

local follow_suspended = false
local ms_suspended       = false -- did THIS cast send the Multisend "off" command?
local resume_at          = nil   -- os.clock() time at which follow is turned back on
local cast_confirmed     = false

local function run_command(cmd)
    quiet_until = os.clock() + QUIET_FOR
    pcall(function() AshitaCore:GetChatManager():QueueCommand(-1, cmd) end)
end

-- In-game auto-follow (/follow): stopped when a cast starts, then restarted on
-- the same target once the cast is over.
local function game_follow_stop()
    local ok, saved = pcall(function()
        local af = AshitaCore:GetMemoryManager():GetAutoFollow()
        if af:GetIsAutoRunning() == 0 then return nil end
        local idx, sid = af:GetFollowTargetIndex(), af:GetFollowTargetServerId()
        af:SetIsAutoRunning(0)
        af:SetFollowTargetIndex(0)
        af:SetFollowTargetServerId(0)
        if idx == 0 then return nil end      -- plain auto-run, not a follow: don't restart it
        return { idx, sid }
    end)
    if ok then gf_saved = saved end
end

local function game_follow_resume()
    local s = gf_saved
    gf_saved = nil
    if not s then return end
    pcall(function()
        -- target gone (or its slot reused by someone else)? don't follow
        if AshitaCore:GetMemoryManager():GetEntity():GetServerId(s[1]) ~= s[2] then return end
        local af = AshitaCore:GetMemoryManager():GetAutoFollow()
        af:SetFollowTargetIndex(s[1])
        af:SetFollowTargetServerId(s[2])
        af:SetIsAutoRunning(1)
    end)
end

-- Follow the character typed in the settings window. Returns false when no
-- name is set, so the caller can fall back to the follow we stopped.
local function game_follow_named()
    local name = gf_name:match('^%s*(.-)%s*$')
    if name == '' then return false end
    gf_saved = nil
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        local want = name:lower()
        -- both clients share settings: the leader never follows itself
        if (mm:GetParty():GetMemberName(0) or ''):lower() == want then return end
        local ent, idx = mm:GetEntity(), nil
        for i = 1, 2303 do
            local n = ent:GetName(i)
            if n and n:lower() == want and ent:GetServerId(i) ~= 0 then idx = i; break end
        end
        if not idx then return end           -- not in this zone: don't spam the game with /follow
        local af = mm:GetAutoFollow()
        if af:GetIsAutoRunning() ~= 0 and af:GetFollowTargetIndex() == idx then return end
        run_command('/follow ' .. ent:GetName(idx))
    end)
    return true
end

-- Cast starts: turn Multisend follow and in-game auto-follow off.
local function suspend_follow()
    if follow_suspended or not (ms_enabled or gf_enabled) then return end
    follow_suspended = true
    if ms_enabled then
        ms_suspended = true
        if ms_off_cmd ~= '' then run_command(ms_off_cmd) end
    end
    if gf_enabled then game_follow_stop() end
end

-- Cast over (after any unlock wait): turn them back on.
local function resume_follow()
    if not follow_suspended then return end
    follow_suspended = false
    if ms_suspended then
        ms_suspended = false
        if ms_on_cmd ~= '' then run_command(ms_on_cmd) end
    end
    if not (gf_enabled and game_follow_named()) then game_follow_resume() end
end

-- confirmed = true when the server's "you began casting" packet arrived
local function start_cast(confirmed)
    local was_casting = casting
    casting = true
    resume_at = nil          -- a new cast cancels any pending follow re-enable
    if confirmed then
        cast_confirmed = true
        cast_started   = os.clock()
    elseif not was_casting then
        cast_confirmed = false
        cast_started   = os.clock()
    end
    if not was_casting then
        suspend_follow()
        release_held_keys()
    end
end

-- Ends the movement lock. follow_delay (seconds) = how long to wait before the
-- follow commands are turned back on; nil or 0 = right away.
local function stop_cast(reason, follow_delay)
    if reason == 'interrupted' and casting then int_until = os.clock() + INT_FLASH end
    casting        = false
    cast_confirmed = false
    cast_need      = 0
    if follow_delay and follow_delay > 0 and follow_suspended then
        resume_at = os.clock() + follow_delay
    else
        resume_at = nil
        resume_follow()
    end
end

----------------------------------------------------------------------
-- Multi-client sync (file based; each client runs its own copy of the
-- addon, and they talk through small files in the addon's config folder)
--   client_<name>.txt : heartbeat written by that client  ("time|enabled")
--   cmd_<name>.txt    : "please switch to ON/OFF" request sent TO that client
----------------------------------------------------------------------
local SCAN_EVERY      = 0.5

local function my_name()
    local ok, name = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0)
    end)
    if ok and name and name ~= '' then return name end
    return nil
end

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

----------------------------------------------------------------------
-- YunaUI looks (Settings > Widget > Theme)
--   classic : the original widget (its options are the Box / text settings)
--   vex     : YunaUI's Vex party / alliance list - a coloured state tag, then a
--             dark slanted plate with the name and a thin state bar
--   hex     : YunaUI's Hex link party plates - cut corners lit gold, the name,
--             a slanted gold divider and a job-box style state tag
-- Each look keeps its own options (TH.vex / TH.hex), so switching between
-- looks never loses what you picked for the other one.
----------------------------------------------------------------------
local theme = 'classic'
-- Every look also keeps its own arrangement, rotation, low profile, opacity and
-- (Vex / Hex link) colours; the active look's values live in the usual globals
-- (layout_mode, rot, ...) and are swapped in and out when the look changes.
local TH_DEFAULT = {
    classic = { layout = 0, rot = 0, low = false, letter = false, alpha = 1.0 },
    vex = { row = 'party', ls = 'B', frame = true, goldlock = true, size = 1.0, view = 'A', bar_w = 110,
            name_w = 150, name_h = 30, tag_w = 40, tag_h = 17, gap = 0, align = 'left',
            plate = { 0.085, 0.08, 0.11 }, plate_a = 0.88,
            layout = 0, rot = 0, low = false, letter = false, alpha = 1.0,
            on = { 0.36, 0.79, 0.42 }, off = { 0.85, 0.28, 0.30 }, lock = { 0.95, 0.70, 0.24 },
            lockname = { 0.95, 0.70, 0.24 }, tagauto = true },
    hex = { ls = 'B', gold = true, cut = 'medium', size = 1.0, view = 'A',
            name_w = 110, name_h = 30, tag_w = 38, tag_h = 17, gap = 10, align = 'left',
            plate = { 0.067, 0.059, 0.09 }, plate_a = 0.86,   -- YunaUI's Hex link plate
            layout = 0, rot = 0, low = false, letter = false, alpha = 1.0,
            on = { 0.36, 0.79, 0.42 }, off = { 0.85, 0.28, 0.30 }, lock = { 0.95, 0.70, 0.24 },
            lockname = { 0.95, 0.70, 0.24 }, tagauto = true },
}
local TH = { classic = {}, vex = {}, hex = {} }

-- Vex and Hex link also get their own copy of the Classic look's style table
-- (background box, border, name text, ON / OFF text): TH.vex.st / TH.hex.st.
-- No box behind the plates until you raise its opacity.
local function themed_style()
    local st = default_style()
    st.bg[4], st.border_w = 0, 0
    st.name.color = { 0.84, 0.84, 0.88, 1 }     -- soft white, as YunaUI's party names
    st.state.shadow = false                       -- ON / OFF text: plain, not bold-looking
    return st
end

local function reset_theme(id)
    for k, v in pairs(TH_DEFAULT[id]) do
        TH[id][k] = (type(v) == 'table') and { v[1], v[2], v[3] } or v
    end
    if id ~= 'classic' then TH[id].st = themed_style() end
end
reset_theme('classic')
reset_theme('vex')
reset_theme('hex')

-- a style table <-> "bg:0.060/0.060/0.080/0.000,border_w:1,name__size:1.000,..."
local function style_ser(st)
    local out = {}
    local function put(k, v)
        if type(v) == 'boolean' then v = v and 1 or 0
        elseif type(v) == 'number' then v = ('%.3f'):format(v)
        elseif type(v) == 'table' then
            local t = {}
            for i = 1, #v do t[i] = ('%.3f'):format(v[i]) end
            v = table.concat(t, '/')
        end
        out[#out + 1] = k .. ':' .. tostring(v)
    end
    for k, v in pairs(st) do
        if k == 'name' or k == 'state' then
            for k2, v2 in pairs(v) do put(k .. '__' .. k2, v2) end
        else
            put(k, v)
        end
    end
    table.sort(out)
    return table.concat(out, ',')
end

local function style_parse(st, s)
    for k, v in s:gmatch('([%w_]+):([^,]+)') do
        local tbl, key = st, k
        local a, b = k:match('^(%w+)__([%w_]+)$')
        if a == 'name' or a == 'state' then tbl, key = st[a], b end
        local d = tbl[key]
        if type(d) == 'boolean' then tbl[key] = (v == '1')
        elseif type(d) == 'number' then tbl[key] = tonumber(v) or d
        elseif type(d) == 'table' then
            local t = {}
            for x in v:gmatch('[^/]+') do t[#t + 1] = clamp(tonumber(x) or 0, 0, 1) end
            if #t == #d then tbl[key] = t end
        end
    end
end

-- box sizes for a theme (Vex Menu rows start smaller)
local function dims_default(id, row)
    if id == 'vex' and row == 'menu' then
        return { name_w = 96, name_h = 26, tag_w = 40, tag_h = 16, gap = 10 }
    end
    local d = TH_DEFAULT[id]
    return { name_w = d.name_w, name_h = d.name_h, tag_w = d.tag_w, tag_h = d.tag_h, gap = d.gap }
end

-- the active look's arrangement / opacity <-> its saved copy
local function store_profile(id)
    local o = TH[id]
    o.layout, o.rot, o.low, o.letter, o.alpha = layout_mode, rot, low_profile, letter_badge, ui_alpha
end
local function apply_profile(id)
    local o = TH[id]
    layout_mode, rot, low_profile, letter_badge, ui_alpha = o.layout, o.rot, o.low, o.letter, o.alpha
    refit = true
end

-- "row:party,ls:B,..." <-> the option table (types follow the defaults)
local function theme_ser(id)
    local keys = {}
    for k in pairs(TH_DEFAULT[id]) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = TH[id][k]
        if type(v) == 'boolean' then v = v and 1 or 0
        elseif type(v) == 'table' then v = ('%.3f/%.3f/%.3f'):format(v[1], v[2], v[3]) end
        out[#out + 1] = k .. ':' .. tostring(v)
    end
    return table.concat(out, ',')
end

local function theme_parse(id, s)
    for k, v in s:gmatch('([%w_]+):([^,]+)') do
        local d = TH_DEFAULT[id][k]
        if type(d) == 'boolean' then TH[id][k] = (v == '1')
        elseif type(d) == 'number' then
            local x = tonumber(v) or d
            if k == 'size' then x = clamp(x, 0.4, 3.0)
            elseif k == 'alpha' then x = clamp(x, 0.2, 1.0)
            elseif k == 'rot' then x = math.floor(clamp(x, 0, 3))
            elseif k == 'layout' then x = (x == 1) and 1 or 0 end
            TH[id][k] = x
        elseif type(d) == 'string' then
            if k == 'row' and v == 'alliance' then v = 'menu' end   -- (Alliance is now Menu)
            TH[id][k] = v
        elseif type(d) == 'table' then
            local r, g, b = v:match('([%d%.]+)/([%d%.]+)/([%d%.]+)')
            if b then TH[id][k] = { clamp(tonumber(r), 0, 1), clamp(tonumber(g), 0, 1), clamp(tonumber(b), 0, 1) } end
        end
    end
    -- Hex link values still at the old defaults move to the new ones (darker plate, smaller tag)
    if id == 'hex' then
        local o, pl = TH.hex, TH.hex.plate
        if math.abs(pl[1] - 0.13) < 0.002 and math.abs(pl[2] - 0.12) < 0.002 and math.abs(pl[3] - 0.16) < 0.002 then
            o.plate = { 0.067, 0.059, 0.09 }
            if math.abs(o.plate_a - 0.85) < 0.002 then o.plate_a = 0.86 end
        end
        if o.tag_w == 50 and o.tag_h == 20 then o.tag_w, o.tag_h = 38, 17 end
    elseif id == 'vex' then                                -- (Vex Party tag: 48 x 22 -> 40 x 17)
        local o = TH.vex
        if o.row == 'party' and o.tag_w == 48 and o.tag_h == 22 then o.tag_w, o.tag_h = 40, 17 end
        if o.row == 'menu' and o.name_w == 100 and o.name_h == 17 and o.tag_w == 34 and o.tag_h == 13 then
            o.name_w, o.name_h, o.tag_w, o.tag_h, o.gap = 96, 26, 40, 16, 10   -- (the new Menu cards)
        end
    end
end

local test_lock_until = 0       -- Settings > Test lock: show LOCK for a few seconds (look only)


-- Settings are saved to config/addons/stopmove/settings.txt
-- (shared by both clients because they use the same Ashita folder)
local function f4(t) return ('%.3f,%.3f,%.3f,%.3f'):format(t[1], t[2], t[3], t[4]) end

-- Settings both clients share (settings.txt). Everything else - the theme, its
-- options and the widget's looks - is per character, in look_<name>.txt, so one
-- client's appearance never carries over to the other.
local SHARED = {
    wait = true, still = true, waitmax = true, maxlock = true, block_keys = true, block_wasd = true,
    inject = true, unlock_done = true, unlock_int = true, ms_enabled = true, ms_quiet = true,
    ms_offcmd = true, ms_oncmd = true, game_follow = true, game_follow_name = true,
}

local last_lines = {}          -- every setting line from the last save (Save and load uses them)

local function save_settings()
    if not sync_dir then return end
    local lines = {
        ('alpha=%.2f'):format(ui_alpha),
        ('wait=%d'):format(wait_for_stop and 1 or 0),
        ('still=%.2f'):format(WAIT_STILL),
        ('waitmax=%.2f'):format(WAIT_MAX),
        ('maxlock=%.1f'):format(MAX_LOCK),
        'bg=' .. f4(S.bg),
        'border=' .. f4(S.border),
        ('borderw=%.1f'):format(S.border_w),
        'name_color=' .. f4(S.name.color),
        ('name_bold=%d'):format(S.name.bold and 1 or 0),
        ('name_size=%.2f'):format(S.name.size),
        'state_color=' .. f4(S.state.color),
        ('state_bold=%d'):format(S.state.bold and 1 or 0),
        ('state_size=%.2f'):format(S.state.size),
        'on_col=' .. f4(S.on_col),
        'off_col=' .. f4(S.off_col),
        'lock_col=' .. f4(S.lock_col),
        ('block_keys=%d'):format(block_keys and 1 or 0),
        ('block_wasd=%d'):format(block_wasd and 1 or 0),
        ('badge_circle=%d'):format(S.badge_circle and 1 or 0),
        ('badge_text=%d'):format(S.badge_text and 1 or 0),
        ('inject=%d'):format(inject and 1 or 0),
        ('lock_pos=%d'):format(lock_pos and 1 or 0),
        ('low_profile=%d'):format(low_profile and 1 or 0),
        ('letter_badge=%d'):format(letter_badge and 1 or 0),
        ('layout=%d'):format(layout_mode),
        ('bg_style=%d'):format(S.bg_style),
        'menu_top=' .. f4(S.menu_top),
        'menu_mid=' .. f4(S.menu_mid),
        'menu_bottom=' .. f4(S.menu_bottom),
        ('menu_stripes=%d'):format(S.menu_stripes and 1 or 0),
        ('menu_frame=%d'):format(S.menu_frame and 1 or 0),
        ('lock_tint=%d'):format(S.lock_name_tint and 1 or 0),
        ('name_shadow=%d'):format(S.name.shadow and 1 or 0),
        ('state_shadow=%d'):format(S.state.shadow and 1 or 0),
        ('menu_stripe_a=%.2f'):format(S.menu_stripe_a),
        ('bg_w_add=%d'):format(S.bg_w_add),
        ('bg_h_add=%d'):format(S.bg_h_add),
        ('name_outline=%d'):format(S.name.outline and 1 or 0),
        ('name_outlinew=%.1f'):format(S.name.outline_w),
        'name_outlinecolor=' .. f4(S.name.outline_color),
        ('state_outline=%d'):format(S.state.outline and 1 or 0),
        ('state_outlinew=%.1f'):format(S.state.outline_w),
        'state_outlinecolor=' .. f4(S.state.outline_color),
        ('rot=%d'):format(rot),
        ('unlock_done=%.1f'):format(UNLOCK_DONE),
        ('unlock_int=%.1f'):format(UNLOCK_INT),
        ('show_ui=%d'):format(show_ui and 1 or 0),
    }
    lines[#lines + 1] = ('ms_enabled=%d'):format(ms_enabled and 1 or 0)
    lines[#lines + 1] = ('ms_quiet=%d'):format(ms_quiet and 1 or 0)
    lines[#lines + 1] = ('game_follow=%d'):format(gf_enabled and 1 or 0)
    lines[#lines + 1] = 'game_follow_name=>' .. gf_name
    lines[#lines + 1] = 'ms_offcmd=>' .. ms_off_cmd      -- leading '>' keeps blank commands
    lines[#lines + 1] = 'ms_oncmd=>'  .. ms_on_cmd
    lines[#lines + 1] = 'theme=>' .. theme
    store_profile(theme)
    lines[#lines + 1] = 'th_classic=>' .. theme_ser('classic')
    lines[#lines + 1] = 'th_vex=>' .. theme_ser('vex')
    lines[#lines + 1] = 'th_hex=>' .. theme_ser('hex')
    lines[#lines + 1] = 'st_vex=>' .. style_ser(TH.vex.st)
    lines[#lines + 1] = 'st_hex=>' .. style_ser(TH.hex.st)
    local blob = table.concat(lines, '\n') .. '\n'
    last_lines = lines
    write_file(sync_dir .. 'settings.txt', blob)    -- (its looks only seed a character that has none yet)
    last_blob = blob
    local me = my_name()
    if me then
        local own = {}
        for _, l in ipairs(lines) do
            local k = l:match('^([%w_]+)=')
            if k and not SHARED[k] then own[#own + 1] = l end
        end
        write_file(sync_dir .. 'look_' .. me .. '.txt', table.concat(own, '\n') .. '\n')
    end
end

-- shared_only: the other client changed settings.txt - take its shared settings, not its looks
local function apply_settings(data, shared_only)
    local had_classic = false
    local had_theme = false        -- any th_ line: not a file from before themes
    for k, v in data:gmatch('([%w_]+)=([^\r\n]+)') do
        local n = {}
        if shared_only and not SHARED[k] then goto continue end
        if k == 'ms_offcmd' then
            ms_off_cmd = (v:gsub('^>', ''))
            goto continue
        elseif k == 'ms_oncmd' then
            ms_on_cmd = (v:gsub('^>', ''))
            goto continue
        elseif k == 'theme' then
            local t = (v:gsub('^>', ''))
            if t == 'classic' or t == 'vex' or t == 'hex' then theme = t end
            refit = true
            goto continue
        elseif k == 'th_classic' or k == 'th_vex' or k == 'th_hex' then
            theme_parse(k:sub(4), (v:gsub('^>', '')))
            if k == 'th_classic' then had_classic = true end
            had_theme = true
            goto continue
        elseif k == 'st_vex' or k == 'st_hex' then
            local st_ = TH[k:sub(4)].st
            style_parse(st_, (v:gsub('^>', '')))
            local c_ = st_.name.color
            if c_[1] == 1 and c_[2] == 1 and c_[3] == 1 then st_.name.color = { 0.84, 0.84, 0.88, c_[4] } end
            goto continue
        elseif k == 'game_follow_name' then
            gf_name = (v:gsub('^>', ''))
            goto continue
        end
        for num in v:gmatch('[%-%d%.]+') do n[#n + 1] = tonumber(num) end
        local x = n[1]
        local function col(t)
            if #n >= 4 then
                for q = 1, 4 do t[q] = clamp(n[q] or t[q], 0, 1) end
            end
        end
        if x then
            if     k == 'alpha'       then ui_alpha      = clamp(x, 0.2, 1.0)
            elseif k == 'wait'        then wait_for_stop = (x ~= 0)
            elseif k == 'still'       then WAIT_STILL    = clamp(x, 0.05, 1.0)
            elseif k == 'waitmax'     then WAIT_MAX      = clamp(x, 0.1, 5.0)
            elseif k == 'maxlock'     then MAX_LOCK      = clamp(x, 1, 30)
            elseif k == 'bg'          then col(S.bg)
            elseif k == 'border'      then col(S.border)
            elseif k == 'borderw'     then S.border_w    = clamp(x, 0, 6)
            elseif k == 'name_color'  then col(S.name.color)
            elseif k == 'name_bold'   then S.name.bold   = (x ~= 0)
            elseif k == 'name_size'   then S.name.size   = clamp(x, 0.1, 2.5)
            elseif k == 'state_color' then col(S.state.color)
            elseif k == 'state_bold'  then S.state.bold  = (x ~= 0)
            elseif k == 'state_size'  then S.state.size  = clamp(x, 0.1, 2.5)
            elseif k == 'on_col'      then col(S.on_col)
            elseif k == 'off_col'     then col(S.off_col)
            elseif k == 'lock_col'    then col(S.lock_col)
            elseif k == 'block_keys'  then block_keys    = (x ~= 0)
            elseif k == 'block_wasd'  then block_wasd    = (x ~= 0)
            elseif k == 'badge_circle' then S.badge_circle = (x ~= 0)
            elseif k == 'badge_text'  then S.badge_text  = (x ~= 0)
            elseif k == 'ms_enabled'  then ms_enabled    = (x ~= 0)
            elseif k == 'ms_quiet'    then ms_quiet      = (x ~= 0)
            elseif k == 'game_follow' then gf_enabled    = (x ~= 0)
            elseif k == 'inject'      then inject        = (x ~= 0)
            elseif k == 'lock_pos'    then lock_pos      = (x ~= 0)
            elseif k == 'low_profile' then low_profile   = (x ~= 0); refit = true
            elseif k == 'letter_badge' then letter_badge = (x ~= 0); refit = true
            elseif k == 'layout'      then layout_mode   = (x == 1) and 1 or 0
            elseif k == 'bg_style'    then S.bg_style    = (x == 1) and 1 or 0
            elseif k == 'menu_top'    then col(S.menu_top)
            elseif k == 'menu_mid'    then col(S.menu_mid)
            elseif k == 'menu_bottom' then col(S.menu_bottom)
            elseif k == 'menu_stripes' then S.menu_stripes = (x ~= 0)
            elseif k == 'menu_frame'  then S.menu_frame  = (x ~= 0)
            elseif k == 'lock_tint'   then S.lock_name_tint = (x ~= 0)
            elseif k == 'name_shadow' then S.name.shadow = (x ~= 0)
            elseif k == 'state_shadow' then S.state.shadow = (x ~= 0)
            elseif k == 'menu_stripe_a' then S.menu_stripe_a = clamp(x, 0, 1)
            elseif k == 'bg_w_add'    then S.bg_w_add    = clamp(x, -300, 800)
            elseif k == 'bg_h_add'    then S.bg_h_add    = clamp(x, -300, 800)
            elseif k == 'name_outline' then S.name.outline = (x ~= 0)
            elseif k == 'name_outlinew' then S.name.outline_w = clamp(x, 0.5, 4)
            elseif k == 'name_outlinecolor' then col(S.name.outline_color)
            elseif k == 'state_outline' then S.state.outline = (x ~= 0)
            elseif k == 'state_outlinew' then S.state.outline_w = clamp(x, 0.5, 4)
            elseif k == 'state_outlinecolor' then col(S.state.outline_color)
            elseif k == 'rot'         then rot           = math.floor(clamp(x, 0, 3))
            elseif k == 'unlock_done' then UNLOCK_DONE   = clamp(x, 0, 60)
            elseif k == 'unlock_int'  then UNLOCK_INT    = clamp(x, 0, 60)
            elseif k == 'show_ui'     then show_ui       = (x ~= 0)
            end
        end
        ::continue::
    end
    if shared_only then return end
    -- a settings file from before per-look profiles: every look starts from its layout etc.
    if not had_classic and not had_theme then
        store_profile('classic'); store_profile('vex'); store_profile('hex')
    end
    apply_profile(theme)
end

----------------------------------------------------------------------
-- Save and load (Settings > Tools): whole configurations in
-- config\addons\stopmove\saved\<name>.txt
----------------------------------------------------------------------
-- saved setups live next to the addon itself: <Ashita>\addons\stopmove\saved\
local SAVED_DIR = nil
local function saved_dir()
    if SAVED_DIR then return SAVED_DIR end
    local base = addon.path
    if type(base) ~= 'string' or base == '' then
        base = ('%saddons\\%s\\'):format(AshitaCore:GetInstallPath(), addon.name)
    end
    if not base:find('[\\/]$') then base = base .. '\\' end
    SAVED_DIR = base .. 'saved\\'
    -- setups saved by 3.0 test builds in config\addons\stopmove\saved: move them over once
    pcall(function()
        if not sync_dir then return end
        local old = sync_dir .. 'saved\\'
        local files = ashita.fs.get_dir(old, '.*', true)
        if not files or #files == 0 then return end
        ashita.fs.create_dir(SAVED_DIR)
        for _, f in ipairs(files) do
            local n = tostring(f):match('([^\\/]+%.txt)$')
            local have = n and io.open(SAVED_DIR .. n, 'r')
            if have then have:close() end
            if n and not have then
                local src = io.open(old .. n, 'rb')
                if src then
                    local data = src:read('*a'); src:close()
                    local dst = io.open(SAVED_DIR .. n, 'wb')
                    if dst then dst:write(data); dst:close(); os.remove(old .. n) end
                end
            end
        end
    end)
    return SAVED_DIR
end

-- the settings window's own state and helpers live in one table (LuaJIT allows a
-- function at most 60 outer locals, and the settings window uses a lot of them)
local CFG = {}

-- Saves under "<character> - <name>" (the character's name is added unless the
-- name already starts with it). Returns the file name used, or nil.
function CFG.save_config(name)
    name = (name or ''):gsub('[^%w_%- ]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or not saved_dir() then return nil end
    local me = my_name()
    if me and name:lower():sub(1, #me) ~= me:lower() then name = me .. ' - ' .. name end
    ashita.fs.create_dir(saved_dir())
    save_settings()
    if not write_file(saved_dir() .. name .. '.txt', table.concat(last_lines, '\n') .. '\n') then return nil end
    return name
end

function CFG.saved_configs()
    local out = {}
    local dir = saved_dir()
    if not dir then return out end
    local files = ashita.fs.get_dir(dir, '.*', true)
    if files then
        for _, f in ipairs(files) do
            local n = tostring(f):match('([^\\/]+)%.txt$')
            if n then out[#out + 1] = n end
        end
    end
    table.sort(out)
    return out
end

function CFG.load_config(name)
    local data = saved_dir() and read_file(saved_dir() .. name .. '.txt')
    if not data then return false end
    store_profile(theme)
    apply_settings(data)
    save_settings()
    return true
end

----------------------------------------------------------------------
-- Copy this theme to the other client: its theme and that theme's own
-- settings go in copy_<name>.txt, which that client picks up and deletes.
----------------------------------------------------------------------
local NOT_COPIED = { show_ui = true, lock_pos = true, cfg_btn = true, move_btn = true }

-- Push a whole configuration to the other client: a saved file (or, with no
-- file, the settings in use now) goes in push_<name>.txt. That client saves
-- what it had first ("before push ...") and then loads what was pushed.
function CFG.push_to(name, file)
    if not sync_dir then return false end
    local data
    if file then
        data = saved_dir() and read_file(saved_dir() .. file .. '.txt')
    else
        save_settings()
        data = table.concat(last_lines, '\n') .. '\n'
    end
    if not data then return false end
    return write_file(sync_dir .. 'push_' .. name .. '.txt', data)
end

function CFG.copy_theme_to(name)
    if not sync_dir then return end
    save_settings()
    local out = { 'theme=>' .. theme }
    for _, l in ipairs(last_lines) do
        local k = l:match('^([%w_]+)=')
        if k and not SHARED[k] and not NOT_COPIED[k] and k ~= 'theme' then
            local mine
            if theme == 'classic' then
                mine = not k:match('^th_') and not k:match('^st_') or k == 'th_classic'
            else
                mine = (k == 'th_' .. theme) or (k == 'st_' .. theme)
            end
            if mine then out[#out + 1] = l end
        end
    end
    write_file(sync_dir .. 'copy_' .. name .. '.txt', table.concat(out, '\n') .. '\n')
end

local function load_settings()
    local data = read_file(sync_dir .. 'settings.txt')
    if data then
        last_blob = data
        apply_settings(data)
    end
end

local function init_sync()
    sync_dir = ('%sconfig\\addons\\%s\\'):format(AshitaCore:GetInstallPath(), addon.name)
    ashita.fs.create_dir(sync_dir)
    load_settings()
end

-- what the other client is told: 0 = free, 1 = locked, 2 = a cast was just interrupted
local function lock_code()
    if not enabled then return 0 end
    if casting then return 1 end
    return (os.clock() < int_until) and 2 or 0
end

local function write_heartbeat()
    local me = my_name()
    if not me or not sync_dir then return end
    hb_file = sync_dir .. 'client_' .. me .. '.txt'
    pub_locked = lock_code()
    write_file(hb_file, ('%d|%d|%d'):format(os.time(), enabled and 1 or 0, pub_locked))
end

-- Per-character file: where this character's box is, its scale, and ON/OFF.
local function char_path()
    local me = my_name()
    if not me or not sync_dir then return nil end
    return sync_dir .. 'char_' .. me .. '.txt'
end

local function save_char(x, y)
    local path = char_path()
    if not path then return end
    x = x or char_saved.x or 20
    y = y or char_saved.y or 200
    write_file(path, ('x=%.0f\ny=%.0f\nscale=%.3f\nenabled=%d\n'):format(x, y, last_scale, enabled and 1 or 0))
    char_saved = { x = x, y = y, scale = last_scale, en = enabled }
    last_char_write = os.clock()
end

local function load_char()
    if char_loaded then return end
    local path = char_path()
    if not path then return end          -- not logged in yet
    char_loaded = true
    -- this character's own looks (the first time: start from what settings.txt had)
    local look = read_file(sync_dir .. 'look_' .. my_name() .. '.txt')
    if look then pcall(apply_settings, look) else save_settings() end
    local data = read_file(path)
    if not data then return end
    local t = {}
    for k, v in data:gmatch('(%w+)=([%-%d%.]+)') do t[k] = tonumber(v) end
    if t.x and t.y then char_pos = { t.x, t.y } end
    if t.scale then last_scale = clamp(t.scale, 0.3, 4.0); refit = true end
    if t.enabled ~= nil then enabled = (t.enabled ~= 0); write_heartbeat() end
    char_saved = { x = t.x, y = t.y, scale = t.scale, en = enabled }
end

-- Change THIS client's toggle.
local function set_enabled(value)
    local changed = (enabled ~= value)
    enabled = value
    if not enabled then stop_cast('addon turned off') end
    write_heartbeat()   -- publish the new state right away
    if changed then save_char() end
end

-- Ask ANOTHER client to switch itself on/off.
local function set_remote(name, value)
    if not sync_dir then return end
    cmd_counter = cmd_counter + 1
    -- value: true = ON, false = OFF, 'release' = Allow Move (end its cast lock)
    local st = (value == 'release') and 2 or (value and 1 or 0)
    write_file(sync_dir .. 'cmd_' .. name .. '.txt',
        ('%d|%d.%d|%s'):format(st, os.time(), cmd_counter, my_name() or '?'))
    if st ~= 2 and other_clients[name] then other_clients[name].enabled = value end  -- optimistic UI
end

-- Allow Move: end the cast lock on this client and on any other client that is locked.
local function allow_move()
    local was = casting
    stop_cast('manual release')
    if was then repress_held_keys() end
    for name, info in pairs(other_clients) do
        if info.locked then set_remote(name, 'release') end
    end
end

local function scan_clients(now)
    local found, names = {}, {}
    local me = my_name()
    local files = ashita.fs.get_dir(sync_dir, '.*', true)
    if files then
        for _, fname in ipairs(files) do
            local who = tostring(fname):match('client_(.+)%.txt$')
            if who and who ~= me then
                local data = read_file(sync_dir .. 'client_' .. who .. '.txt') or ''
                local stamp, st, lk = data:match('^(%d+)|(%d)|?(%d?)')
                if stamp and (now - tonumber(stamp)) <= CLIENT_TIMEOUT then
                    found[who] = { enabled = (st == '1'), locked = (lk == '1'), int = (lk == '2') }
                    names[#names + 1] = who
                end
            end
        end
    end
    table.sort(names)
    other_clients, other_names, other_count = found, names, #names
end

local function sync_tick()
    if not sync_dir then return end
    local me = my_name()
    if not me then return end          -- not logged in yet

    local clock = os.clock()

    -- publish lock changes right away so the other client's widget shows LOCK too
    if lock_code() ~= pub_locked then write_heartbeat() end

    if (clock - last_heartbeat) >= HEARTBEAT_EVERY then
        last_heartbeat = clock
        write_heartbeat()
    end

    -- the other client changed the shared settings? pick them up
    if (clock - last_settings_check) >= 1.5 then
        last_settings_check = clock
        local blob = read_file(sync_dir .. 'settings.txt')
        if blob and blob ~= last_blob then
            last_blob = blob
            pcall(apply_settings, blob, true)
            refit = true
        end
    end

    if (clock - last_scan) >= SCAN_EVERY then
        last_scan = clock
        scan_clients(os.time())
    end

    -- requests sent to us by the other client
    if (clock - last_poll) >= POLL_EVERY then
        last_poll = clock
        local cp = sync_dir .. 'copy_' .. me .. '.txt'
        local pp = sync_dir .. 'push_' .. me .. '.txt'
        local pushed = read_file(pp)
        if pushed then                                  -- a whole configuration pushed from the other client
            os.remove(pp)
            CFG.save_config('before push ' .. os.date('%Y-%m-%d %H-%M-%S'))   -- keep what this client had
            store_profile(theme)
            pcall(apply_settings, pushed)
            save_settings()
            refit = true
        end
        local copied = read_file(cp)
        if copied then                                  -- a theme copied over from the other client
            os.remove(cp)
            store_profile(theme)
            pcall(apply_settings, copied)
            save_settings()
            refit = true
        end
        local data = read_file(sync_dir .. 'cmd_' .. me .. '.txt')
        if data then
            if not cmd_primed then
                last_cmd   = data       -- stale file from an earlier session: ignore it
                cmd_primed = true
            elseif data ~= last_cmd then
                last_cmd = data
                local st = data:match('^(%d)|')
                if st == '2' then
                    local was = casting
                    stop_cast('manual release')
                    if was then repress_held_keys() end
                elseif st then
                    set_enabled(st == '1')
                end
            end
        else
            cmd_primed = true
        end
    end
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
ashita.events.register('command', 'stopmove_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/stopmove' then
        return
    end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or ''

    if sub == '' then
        cfg_open[1] = not cfg_open[1]          -- /stopmove opens the settings window
    elseif sub == 'on' then
        set_enabled(true)
    elseif sub == 'off' then
        set_enabled(false)
    elseif sub == 'move' then
        allow_move()
    elseif sub == 'resetbox' then
        last_scale = 1.0
        char_pos   = { 20, 200 }
        refit      = true
        save_char(20, 200)
    end
end)

----------------------------------------------------------------------
-- Hide Multisend's "Multisend: Follow is currently enabled/disabled." line,
-- but only for a few seconds after stopmove itself sent a command.
----------------------------------------------------------------------
ashita.events.register('text_in', 'stopmove_text_in', function(e)
    if not ms_quiet or os.clock() > quiet_until then return end
    local msg = e.message_modified or e.message or ''
    if msg:find('Multisend: Follow is currently', 1, true) then
        e.blocked = true
    end
end)

----------------------------------------------------------------------
-- Detect casting from incoming action packets (0x0028)
--   category 8 + param 24931 = you began casting
--   category 8 + other param  = cast interrupted
--   category 4                = spell finished (unless its first result plays the
--                               interrupt animation, 508: paralyzed or intimidated)
----------------------------------------------------------------------
ashita.events.register('packet_in', 'stopmove_packet_in', function(e)
    if e.id == 0x000B then
        stop_cast('zoning')
        return
    end

    if e.id ~= 0x0028 then
        return
    end
    if not enabled then
        return
    end

    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
    local actor = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
    local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
    local param    = ashita.bits.unpack_be(e.data_raw, 0, 86, 16)

    if actor ~= me then
        return
    end

    if category == 8 then
        if param == 24931 then
            start_cast(true)
        else
            stop_cast('interrupted', UNLOCK_INT)
        end
    elseif category == 4 then
        local anim = ashita.bits.unpack_be(e.data_raw, 0, 191, 12)
        if anim == 508 then
            stop_cast('interrupted', UNLOCK_INT)
        else
            stop_cast('finished', UNLOCK_DONE)
        end
    end
end)

----------------------------------------------------------------------
-- "Wait until stopped" (optional, ON by default; see the settings window)
-- If you press a spell macro while still moving, the outgoing cast request is
-- held back, follow is turned off, and the request is re-sent as soon as your
-- character has stood still for a moment (or after WAIT_MAX seconds).
----------------------------------------------------------------------

local function track_position()
    pcall(function()
        local idx = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0)
        local ent = AshitaCore:GetMemoryManager():GetEntity()
        local x = ent:GetLocalPositionX(idx)
        local y = ent:GetLocalPositionY(idx)
        if math.abs(x - last_x) > 0.01 or math.abs(y - last_y) > 0.01 then
            last_move = os.clock()
        end
        last_x, last_y = x, y
    end)
end

local function send_pending()
    if not pending then return end
    local bytes = pending.bytes
    pending = nil
    resending    = true
    resend_clock = os.clock()
    local pm = AshitaCore:GetPacketManager()
    local ok = pcall(function() pm:AddOutgoingPacket(0x1A, bytes) end)
    if not ok then
        ok = pcall(function() pm:AddOutgoingPacket(0x1A, #bytes, bytes) end)
    end
    if not ok then
        resending = false
    end
end

----------------------------------------------------------------------
-- Second start trigger: your outgoing action request (0x001A).
-- Action category 3 = cast a spell. This fires the moment you press the
-- macro, independent of how the incoming action packet is parsed.
----------------------------------------------------------------------
ashita.events.register('packet_out', 'stopmove_packet_out', function(e)
    if e.id ~= 0x001A then
        return
    end
    if not enabled then
        return
    end
    local cat_lo = ashita.bits.unpack_be(e.data_raw, 10, 0, 8)
    local cat_hi = ashita.bits.unpack_be(e.data_raw, 11, 0, 8)
    if cat_lo == 3 and cat_hi == 0 then
        pcall(function()
            local id  = ashita.bits.unpack_be(e.data_raw, 12, 0, 8) + ashita.bits.unpack_be(e.data_raw, 13, 0, 8) * 256
            local res = AshitaCore:GetResourceManager():GetSpellById(id)
            if res and res.CastTime then cast_need = res.CastTime / 4 + 2 end   -- quarter seconds; +2 s for lag
        end)
        if resending then
            resending = false          -- this is our own re-send; let it through
            start_cast()
            return
        end
        if wait_for_stop then
            if pending then
                e.blocked = true       -- duplicate request while holding one
                return
            end
            if (os.clock() - last_move) < WAIT_STILL then
                local raw = e.data_modified or e.data
                pending = { bytes = { raw:byte(1, -1) }, since = os.clock() }
                e.blocked = true
                suspend_follow()
                release_held_keys()
                return
            end
        end
        start_cast()
    end
end)

----------------------------------------------------------------------
-- Block movement keys while casting
----------------------------------------------------------------------
-- Read the press/release state of a key_data event without assuming
-- which field this Ashita build uses.
local function dik_is_down(e)
    local ok, d = pcall(function() return e.down end)
    if ok and d ~= nil then return d and true or false end
    local ok2, st = pcall(function() return e.state end)
    if ok2 and st ~= nil then
        if type(st) == 'boolean' then return st end
        return st ~= 0
    end
    return nil   -- unknown
end

-- Only key PRESSES are blocked. Key RELEASES are always let through, so the
-- game never thinks a key is stuck down.
ashita.events.register('key_data', 'stopmove_key_data', function(e)
    if enabled and block_keys and casting and (dik_keys[e.key] or (block_wasd and dik_wasd[e.key])) then
        local down = dik_is_down(e)
        if down ~= false then          -- true, or unknown -> block
            e.blocked = true
        end
    end
end)

ashita.events.register('key', 'stopmove_key', function(e)
    local vk = e.wparam
    if not (vk_keys[vk] or (block_wasd and vk_wasd[vk])) then
        return
    end

    -- bit 31 of lparam set = key release
    local release = bit.band(e.lparam or 0, 0x80000000) ~= 0
    if release then held_vk[vk] = nil else held_vk[vk] = true end

    if enabled and block_keys and casting and not release then
        e.blocked = true
        held_vk[vk] = nil   -- the game never saw this press
    end
end)

-- The game also polls the whole keyboard each frame (DirectInput GetDeviceState).
-- A held key shows up there even when its key events are blocked, so clear the
-- movement keys in that snapshot too.
ashita.events.register('key_state', 'stopmove_key_state', function(e)
    if not (enabled and block_keys and casting) then return end
    local keys = ffi.cast('uint8_t*', e.data_raw)
    for k in pairs(dik_keys) do keys[k] = 0 end
    if block_wasd then
        for k in pairs(dik_wasd) do keys[k] = 0 end
    end
end)

-- Box background + border, sized as the box plus the width/height adjustments.
local function draw_background(wx, wy, ww, wh)
    local x1, y1 = wx, wy
    local x2 = wx + math.max(8, ww + S.bg_w_add)
    local y2 = wy + math.max(8, wh + S.bg_h_add)
    local menu = (S.bg_style == 1)
    local mult = S.bg[4]            -- "Background opacity" slider

    if not bg_fail then
        local ok = pcall(function()
            local dl = imgui.GetBackgroundDrawList()
            local u  = imgui.GetColorU32
            if menu then
                local t = { S.menu_top[1],    S.menu_top[2],    S.menu_top[3],    S.menu_top[4] * mult }
                local m = { S.menu_mid[1],    S.menu_mid[2],    S.menu_mid[3],    S.menu_mid[4] * mult }
                local b = { S.menu_bottom[1], S.menu_bottom[2], S.menu_bottom[3], S.menu_bottom[4] * mult }
                local my = y1 + (y2 - y1) / 2
                dl:AddRectFilledMultiColor({ x1, y1 }, { x2, my }, u(t), u(t), u(m), u(m))   -- top to middle
                dl:AddRectFilledMultiColor({ x1, my }, { x2, y2 }, u(m), u(m), u(b), u(b))   -- middle to bottom
            else
                dl:AddRectFilled({ x1, y1 }, { x2, y2 }, u(S.bg), 0)
            end
        end)
        if not ok then bg_fail = true end
        if ok and S.border_w > 0 then
            pcall(function()
                imgui.GetBackgroundDrawList():AddRect({ x1, y1 }, { x2, y2 }, imgui.GetColorU32(S.border), 0, 0, S.border_w)
            end)
        end
    end

    -- horizontal stripes over the gradient (the FFXI menu look)
    if menu and S.menu_stripes and (y2 - y1) < 1500 then
        pcall(function()
            local dl = imgui.GetBackgroundDrawList()
            -- 2px dark band every 4px, in a deep blue-black like the game's menus
            local col = imgui.GetColorU32({ 0.02, 0.0, 0.14, S.menu_stripe_a * mult })
            local yy = y1 + 2
            while yy < y2 do
                dl:AddRectFilled({ x1, yy }, { x2, math.min(yy + 2, y2) }, col, 0)
                yy = yy + 4
            end
        end)
    end

    -- classic FFXI window frame: soft light outer line, dark inner line, slightly rounded corners
    if menu and S.menu_frame then
        pcall(function()
            local dl = imgui.GetBackgroundDrawList()
            dl:AddRect({ x1, y1 }, { x2, y2 }, imgui.GetColorU32({ 0.78, 0.78, 0.90, 0.95 * mult }), 3, 0, 1)
            dl:AddRect({ x1 + 1, y1 + 1 }, { x2 - 1, y2 - 1 }, imgui.GetColorU32({ 0.02, 0.0, 0.14, 0.9 * mult }), 2, 0, 1)
            dl:AddLine({ x1 + 3, y1 + 2 }, { x2 - 3, y1 + 2 }, imgui.GetColorU32({ 0.60, 0.60, 0.85, 0.45 * mult }), 1)  -- top highlight
        end)
    end
end

-- state tag colours: fill, inner line, text (green ON, red OFF, gold LOCK)
local TAGC = {
    on   = { { 0.36, 0.79, 0.42 }, { 0.66, 0.89, 0.64 }, { 0.05, 0.16, 0.07 } },
    off  = { { 0.85, 0.28, 0.30 }, { 0.94, 0.64, 0.64 }, { 0.18, 0.03, 0.04 } },
    lock = { { 0.95, 0.70, 0.24 }, { 1.00, 0.89, 0.63 }, { 0.16, 0.10, 0.00 } },
    none = { { 0.33, 0.33, 0.37 }, { 0.54, 0.54, 0.58 }, { 0.88, 0.88, 0.90 } },
    vbtn = { { 0.85, 0.85, 0.88 }, { 1.00, 1.00, 1.00 }, { 0.15, 0.15, 0.17 } },   -- Vex U / M: white, like the WHM tag
    hbtn = { { 0.16, 0.16, 0.20 }, { 0.42, 0.39, 0.45 }, { 0.85, 0.83, 0.88 } },   -- Hex U / M: dark grey
    int  = { { 0.95, 0.16, 0.28 }, { 1.00, 0.60, 0.66 }, { 0.22, 0.02, 0.05 } },   -- INT: a cast was interrupted
}
local LBL = { on = 'ON', off = 'OFF', lock = 'LOCK', int = 'INT', none = '--' }
local INT_COL = { 0.95, 0.16, 0.28, 1.0 }

-- While the settings window is open - or with Shift held - the widget can be
-- dragged from anywhere, even its badges (the smallest widget has no background
-- left to grab). A press that moves more than a few pixels is a drag; one that
-- doesn't is still a click.
local wdrag = nil             -- { mouse x, mouse y, window x, window y, moved }
local function shift_down()
    local ok, v = pcall(function() return imgui.GetIO().KeyShift end)
    return ok and v == true
end
local function widget_drag(wx, wy)
    if lock_pos or (wdrag == nil and not cfg_open[1] and not shift_down()) then wdrag = nil; return false end
    local mx, my = 0, 0
    pcall(function()
        local a, b = imgui.GetMousePos()
        if type(a) == 'table' then mx, my = a[1], a[2] else mx, my = a, b end
    end)
    if wdrag == nil then
        if imgui.IsWindowHovered() and imgui.IsMouseClicked(0) then wdrag = { mx, my, wx, wy, false } end
        return false
    end
    if imgui.IsMouseDown(0) then
        local dx, dy = mx - wdrag[1], my - wdrag[2]
        if not wdrag[5] and (dx * dx + dy * dy) > 16 then wdrag[5] = true end
        if wdrag[5] then pcall(imgui.SetWindowPos, { wdrag[3] + dx, wdrag[4] + dy }) end
        return wdrag[5]
    end
    local moved = wdrag[5]
    wdrag = nil
    return moved                -- the release that ends a drag is not a click
end

local function u32(c, a) return imgui.GetColorU32({ c[1], c[2], c[3], (a or 1) * ui_alpha }) end
local function poly_fill(dl, p, col)            -- a convex shape (triangle fan if this ImGui can't)
    if not pcall(function() dl:AddConvexPolyFilled(p, col) end) then
        for i = 2, #p - 1 do pcall(function() dl:AddTriangleFilled(p[1], p[i], p[i + 1], col) end) end
    end
end
local function poly_line(dl, p, col, th)
    for i = 1, #p do dl:AddLine(p[i], p[i % #p + 1], col, th) end
end

-- the widget in a YunaUI look; replaces the classic grid when theme ~= 'classic'
local function draw_themed(entries, flags)
    local o   = TH[theme]
    local st  = o.st                               -- this look's box / text style
    -- this look's tag colours: the fill, a lighter inner line and dark text
    local function tagset(c)
        return { c, { c[1] + (1 - c[1]) * 0.45, c[2] + (1 - c[2]) * 0.45, c[3] + (1 - c[3]) * 0.45 },
                 { c[1] * 0.18, c[2] * 0.18, c[3] * 0.18 } }
    end
    local TAGC = { on = tagset(o.on), off = tagset(o.off), lock = tagset(o.lock),
                   none = TAGC.none, vbtn = TAGC.vbtn, hbtn = TAGC.hbtn, int = TAGC.int }
    local vex = (theme == 'vex')
    local letter = low_profile
    local now = os.clock()

    local locked_any = (casting and enabled) or now < test_lock_until
    for _, info in pairs(other_clients) do if info.locked then locked_any = true end end

    -- sizes are designed for a 13px font at size 1.0; u converts them to pixels
    local lh = 13
    pcall(function()
        local v = imgui.GetTextLineHeight()
        if v and v > 4 then lh = v end
    end)
    local s = o.size
    local u = s * lh / 13
    -- text widths are measured once here, at font scale 1 (inside the widget the
    -- font scale changes per text, which would skew a fresh measurement)
    local W1 = {}
    local function measure(str)
        if W1[str] then return end
        local w = 0
        pcall(function()
            local a = imgui.CalcTextSize(str)
            if type(a) == 'table' then w = a[1] else w = a end
        end)
        if not w or w <= 0 then w = #str * lh * 0.55 end
        W1[str] = w
    end
    local function tw(str, px)                     -- text width at px (13-based) size
        return (W1[str] or #str * lh * 0.55) * (px / 13) * s
    end
    for _, str in ipairs({ 'ON', 'OFF', 'LOCK', 'INT', '--', 'U', 'M', 'UI', 'MOVE', 'OK', 'NO' }) do measure(str) end
    local function spaced_w(str, px, sp)
        local w = 0
        for i = 1, #str do w = w + tw(str:sub(i, i), px) end
        return w + sp * u * math.max(0, #str - 1)
    end

    local function state_of(e)
        if not e.active then return 'none' end
        if not e.on then return 'off' end
        if e.locked then return 'lock' end
        if e.int then return 'int' end
        return 'on'
    end
    local function name_of(e, n)
        local nm = e.full or e.name or '?'
        if nm:sub(1, 1) == '(' then return '-' end
        if n then nm = nm:sub(1, n) end
        return nm:upper()                          -- Vex / Hex link: names always in capitals, as YunaUI
    end
    -- the longest start of the name that fits in avail pixels ("BENTHE." when cut, as YunaUI)
    local function fit_name(full, avail, px, sp)
        for i = 1, #full do measure(full:sub(i, i)) end
        measure('.')
        if spaced_w(full, px, sp) <= avail then return full end
        for n = #full - 1, 1, -1 do
            local t = full:sub(1, n) .. '.'
            if spaced_w(t, px, sp) <= avail then return t end
        end
        return full:sub(1, 1)
    end

    -- what to draw: one item per character, then the U / M buttons
    local alliance = vex and o.row == 'menu'      -- Vex Menu: smaller rows in a faint framed box
    local items = {}
    local NAME_PX = (alliance and 12.5 or 14) * st.name.size
    local SP = alliance and 1.5 or 1.6             -- letter spacing of names
    local NAME_PAD = (vex and o.view == 'B') and (0.32 * o.name_h + 8) or (vex and (alliance and 22 or 26) or 16)   -- room the name box keeps free of text
    for _, e in ipairs(entries) do
        local it = { kind = 'char', e = e, st = state_of(e) }
        if letter then
            it.txt = name_of(e, 1)
        else
            it.txt = fit_name(name_of(e), math.max(1, (o.name_w - NAME_PAD) * u), NAME_PX, SP)
        end
        measure(it.txt)
        for i = 1, #it.txt do measure(it.txt:sub(i, i)) end
        items[#items + 1] = it
    end
    if letter then
        if show_cfg_btn then items[#items + 1] = { kind = 'u' } end
        if show_move_btn then items[#items + 1] = { kind = 'm' } end
    elseif show_cfg_btn or show_move_btn then
        items[#items + 1] = { kind = 'btns' }
    end

    -- item sizes (pixels)
    local LET_PX  = 13 * st.name.size              -- the single letters
    local TAG_K   = st.state.size                  -- ON / OFF / LOCK text size
    for _, it in ipairs(items) do
        if it.kind == 'btns' then
            it.w = ((show_cfg_btn and 46 or 0) + (show_move_btn and 74 or 0) + ((show_cfg_btn and show_move_btn) and 5 or 0)) * u
            it.h = (vex and math.max(o.name_h, o.tag_h) or math.max(o.name_h, o.tag_h + 8)) * u   -- as tall as a name row
        elseif letter then
            local v = (it.kind == 'char') and o.ls or 'btn'
            if vex and alliance then                   -- Vex Menu letters: small rounded cards
                it.w = ((v == 'A' or v == 'btn') and 30 or (v == 'B') and 50 or 48) * u
                it.h = 28 * u
            elseif vex and v == 'A' then               -- Vex letter A: a bigger dark tag, white letter, state bar
                it.w, it.h = 54 * u, 39 * u
            elseif vex then
                it.w = ((v == 'btn') and 30 or (v == 'B') and (18 + 34 - 0.32 * (26 + 16) / 2) or 40) * u   -- (B: tag touching the plate)
                it.h = 26 * u
            else
                it.w = ((v == 'A' or v == 'btn') and 26 or (v == 'B') and 50 or 48) * u
                it.h = 28 * u
            end
        elseif vex and alliance then               -- Vex Menu: one rounded card [name | divider | tag]
            it.w = (o.name_w + o.gap + o.tag_w + 14) * u
            it.h = math.max(o.name_h, o.tag_h + 8) * u
        elseif vex and o.view == 'B' then          -- [plate: name over two bars, empty TP spot] tag
            it.w = (o.name_w + 36 + o.gap + o.tag_w + 8 - 0.32 * (o.name_h + o.tag_h) / 2) * u
            it.h = math.max(o.name_h, o.tag_h) * u
        elseif vex then                            -- [tag] gap [name plate]
            it.w = (o.tag_w + o.gap + o.name_w - 0.32 * (o.name_h + o.tag_h) / 2) * u
            it.h = math.max(o.name_h, o.tag_h) * u
        elseif o.view == 'B' then                  -- one plate: [tag | name over its bar | MOVE box]
            it.w = (6 + o.tag_w + o.gap + o.name_w + 8 + 30) * u
            it.h = math.max(o.name_h, o.tag_h + 8) * u
        else                                       -- one plate: [name | gap with divider | tag]
            it.w = (o.name_w + o.gap + o.tag_w + 6) * u
            it.h = math.max(o.name_h, o.tag_h + 8) * u
        end
    end

    -- arrangement: stacked or inline; 90 / 270 swap it, 180 / 270 reverse the order
    local across = (layout_mode == 1)
    if rot == 1 or rot == 3 then across = not across end
    if rot == 2 or rot == 3 then
        local r = {}
        for i = #items, 1, -1 do r[#r + 1] = items[i] end
        items = r
    end
    local gap = (alliance and 3 or 5) * u
    local pad = ((vex and alliance) and 5 or 3) * u     -- (room for the Menu cards' glow)
    local cw, ch = 0, 0
    for i, it in ipairs(items) do
        if across then
            it.x, it.y = pad + cw + ((i > 1) and gap or 0), pad
            cw = cw + it.w + ((i > 1) and gap or 0)
            ch = math.max(ch, it.h)
        else
            it.x, it.y = pad, pad + ch + ((i > 1) and gap or 0)
            ch = ch + it.h + ((i > 1) and gap or 0)
            cw = math.max(cw, it.w)
        end
    end
    for _, it in ipairs(items) do                  -- centre each item across the row / column
        if across then it.y = it.y + (ch - it.h) / 2 end
        if not across and o.align == 'right' then it.x = it.x + (cw - it.w) end   -- (stacked rows to the right)
    end
    local W, H = math.floor(cw + 2 * pad + 2), math.floor(ch + 2 * pad + 2)

    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0, 0, 0 })
    imgui.SetNextWindowSize({ W, H }, ImGuiCond_Always)
    if char_pos then
        imgui.SetNextWindowPos({ char_pos[1], char_pos[2] }, ImGuiCond_Always)
        char_pos = nil
    else
        imgui.SetNextWindowPos({ 20, 200 }, ImGuiCond_FirstUseEver)
    end

    if imgui.Begin('stopmove_ui', true, bit.bor(flags, ImGuiWindowFlags_NoResize)) then
        local wx, wy = 0, 0
        pcall(function()
            local a, b = imgui.GetWindowPos()
            if type(a) == 'table' then wx, wy = a[1], a[2] else wx, wy = a, b end
        end)
        if char_loaded and (os.clock() - last_char_write) > 1.0 then
            if char_saved.x == nil or math.abs(wx - char_saved.x) > 0.5 or math.abs(wy - char_saved.y) > 0.5 then
                save_char(wx, wy)
            end
        end

        local suppress = widget_drag(wx, wy)
        local dl = imgui.GetWindowDrawList()
        -- text with the look's own shadow / outline / bold (part = st.name or st.state)
        local OFFS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
        local function glyphs(x, y, str, col, part)
            if part.outline then
                local d = math.max(1, part.outline_w * u)
                local oc = u32(part.outline_color, part.outline_color[4])
                for _, q in ipairs(OFFS) do dl:AddText({ x + q[1] * d, y + q[2] * d }, oc, str) end
            elseif part.shadow then
                dl:AddText({ x + 1, y + 1 }, u32({ 0, 0, 0 }, 0.75), str)
            end
            dl:AddText({ x, y }, u32(col), str)
            if part.bold then dl:AddText({ x + 1, y }, u32(col), str) end
        end
        local function text(x, y, str, px, col, sp, part)
            part = part or st.name
            pcall(function() imgui.SetWindowFontScale(s * px / 13) end)
            if not sp then glyphs(x, y, str, col, part); return end
            for i = 1, #str do
                local c = str:sub(i, i)
                glyphs(x, y, c, col, part)
                x = x + tw(c, px) + sp * u
            end
        end
        local function text_c(cx, cy, str, px, col, part)   -- centred on cx, cy
            text(cx - tw(str, px) / 2, cy - (lh * s * px / 13) / 2, str, px, col, nil, part)
        end
        local function tag_text(c, tc) return tc or (o.tagauto and c[3] or st.state.color) end
        -- dark automatic text on a bright tag: no drop shadow (a black shadow on it reads as bold)
        local TAG_PART = st.state
        if o.tagauto then
            TAG_PART = { shadow = false, bold = st.state.bold, outline = st.state.outline,
                         outline_color = st.state.outline_color, outline_w = st.state.outline_w }
        end

        -- Vex: a slanted tag / plate (left edge leaning like "/")
        local function par(x, y, w, h, k) return { { x + k, y }, { x + w, y }, { x + w - k, y + h }, { x, y + h } } end
        local function vex_tag(x, y, w, h, c, str, px)
            -- left side upright, right side slanted like the plate (as YunaUI's job tags)
            local k = h * 0.32
            poly_fill(dl, { { x, y }, { x + w, y }, { x + w - k, y + h }, { x, y + h } }, u32(c[1]))
            if str and str ~= '' then text_c(x + (w - k / 2) / 2, y + h / 2, str, px * TAG_K, tag_text(c), TAG_PART) end
        end
        local function vex_plate(x, y, w, h, lock)
            local p = par(x, y, w, h, h * 0.32)
            poly_fill(dl, p, u32(o.plate, o.plate_a))
            if lock and o.goldlock then
                poly_line(dl, p, u32(TAGC.lock[1], 0.25), 3.5 * u)
                poly_line(dl, p, u32(TAGC.lock[1], 0.95), 1)
            else
                poly_line(dl, p, u32({ 0.29, 0.27, 0.34 }, 0.8), 1)
            end
        end
        local function vex_tag_r(x, y, w, h, c, str, px)   -- view B: upright right side, left leaning with the plate
            local k = h * 0.32
            poly_fill(dl, { { x + k, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }, u32(c[1]))
            if str and str ~= '' then text_c(x + (w + k / 2) / 2, y + h / 2, str, px * TAG_K, tag_text(c), TAG_PART) end
        end
        -- Vex Menu: a rounded near-black card with a violet edge and a soft violet glow (white
        -- while locked), a lucent blue divider, and rounded state tags - YunaUI's Vex cards
        -- the card's edge runs pink-red at the left to violet at the right, as YunaUI's Vex map
        -- frame (white while locked); drawn as short segments, each in the colour of its place
        local EDGE_L, EDGE_R = { 1.00, 0.36, 0.62 }, { 0.62, 0.40, 1.00 }
        local function card_edge(x, y, w, h, r, th, a, lock)
            local pts = {}
            local function arc(cx, cy, a0, a1)
                for i = 0, 6 do
                    local t = a0 + (a1 - a0) * i / 6
                    pts[#pts + 1] = { cx + math.cos(t) * r, cy + math.sin(t) * r }
                end
            end
            arc(x + r, y + r, math.pi, 1.5 * math.pi)
            arc(x + w - r, y + r, 1.5 * math.pi, 2 * math.pi)
            arc(x + w - r, y + h - r, 0, 0.5 * math.pi)
            arc(x + r, y + h - r, 0.5 * math.pi, math.pi)
            for i = 1, #pts do
                local p0, p1 = pts[i], pts[i % #pts + 1]
                local t = clamp(((p0[1] + p1[1]) / 2 - x) / math.max(1, w), 0, 1)
                local col = lock and { 1, 1, 1 } or { EDGE_L[1] + (EDGE_R[1] - EDGE_L[1]) * t,
                    EDGE_L[2] + (EDGE_R[2] - EDGE_L[2]) * t, EDGE_L[3] + (EDGE_R[3] - EDGE_L[3]) * t }
                dl:AddLine(p0, p1, u32(col, a), th)
            end
        end
        local function vex_card(x, y, w, h, lock)
            local r = math.min(8 * u, h / 2 - 1)
            card_edge(x - 1.5, y - 1.5, w + 3, h + 3, r + 1.5, 3.5, lock and 0.16 or 0.12, lock)   -- the soft glow
            dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(o.plate, o.plate_a), r)
            card_edge(x, y, w, h, r, 1.3, 0.95, lock)
        end
        local function vex_vdiv(cx, y, h)                  -- the divider: violet, with a faint glow
            dl:AddLine({ cx, y + 5 * u }, { cx, y + h - 5 * u }, u32({ 0.62, 0.40, 1.0 }, 0.35), 3.5 * u)
            dl:AddLine({ cx, y + 5 * u }, { cx, y + h - 5 * u }, u32({ 0.78, 0.62, 1.0 }, 1), 1.2)
        end
        local function vex_rtag(l, t, r, b, c, str, px, tc)
            local rr = math.min(5 * u, (b - t) / 2)
            dl:AddRectFilled({ l, t }, { r, b }, u32(c[1]), rr)
            dl:AddRect({ l, t }, { r, b }, u32({ 0.04, 0.04, 0.055 }), rr, 0, 1)
            dl:AddRect({ l + 1.5 * u, t + 1.5 * u }, { r - 1.5 * u, b - 1.5 * u }, u32(c[2], 0.8), math.max(1, rr - 1.5 * u), 0, 1)
            if str and str ~= '' then text_c((l + r) / 2, (t + b) / 2, str, px * TAG_K, tc or tag_text(c), tc and st.state or TAG_PART) end
        end
        local function vex_bar(x, y, w, c)
            dl:AddRectFilled({ x, y }, { x + w, y + 3 * u }, u32({ 0.14, 0.13, 0.17 }, 0.9), 0)
            dl:AddRectFilled({ x, y }, { x + w, y + 3 * u }, u32(c[1]), 0)
        end

        -- Hex link: cut-corner plate, gold divider, job-box style tag
        local CUT = ({ small = 4, medium = 7, large = 10 })[o.cut] or 7
        local function hex_plate(x, y, w, h, lock)
            local K = math.min(CUT * u, h * 0.32)
            local p = { { x + K, y }, { x + w, y }, { x + w, y + h - K }, { x + w - K, y + h }, { x, y + h }, { x, y + K } }
            poly_fill(dl, p, lock and u32({ o.plate[1] + 0.03, o.plate[2] + 0.035, o.plate[3] + 0.03 }, o.plate_a) or u32(o.plate, o.plate_a))
            if lock then
                poly_line(dl, p, u32({ 1.0, 0.80, 0.43 }, 0.22), 4 * u)
                poly_line(dl, p, u32({ 1.0, 0.94, 0.78 }, 0.95), 1.4)
            else
                poly_line(dl, p, u32({ 0.79, 0.65, 0.35 }, 0.45), 1)
            end
            if o.gold then
                local cc = lock and { 1.0, 0.94, 0.78 } or { 1.0, 0.90, 0.62 }
                local ca = lock and 1 or 0.6
                dl:AddLine({ x, y + K }, { x + K, y }, u32(cc, ca), math.max(1.5, 2.0 * u))
                dl:AddLine({ x + w - K, y + h }, { x + w, y + h - K }, u32(cc, ca), math.max(1.5, 2.0 * u))
            end
        end
        local function hex_divider(cx, y, h)
            dl:AddLine({ cx + 3 * u, y + 3 * u }, { cx - 3 * u, y + h - 3 * u }, u32({ 1.0, 0.76, 0.34 }, 0.9), math.max(1, 0.9 * u))
        end
        local function hex_tag(l, t, r, b, c, str, px, tc)
            local kc, sl = 3 * u, 2.5 * u
            poly_fill(dl, { { l + sl, t }, { r, t }, { r, b - kc }, { r - kc, b }, { l - sl, b } }, u32(c[1]))
            poly_line(dl, { { l + sl, t }, { r, t }, { r, b - kc }, { r - kc, b }, { l - sl, b } }, u32({ 0.04, 0.04, 0.055 }), 1)
            local i = 1.5 * u
            poly_line(dl, { { l + sl + i, t + i }, { r - i, t + i }, { r - i, b - kc - i * 0.3 }, { r - kc - i * 0.3, b - i }, { l - sl + i * 1.2, b - i } }, u32(c[2], 0.8), 1)
            if str and str ~= '' then text_c((l + r) / 2, (t + b) / 2, str, px * TAG_K, tag_text(c, tc), tc and st.state or TAG_PART) end
        end

        -- this look's own box behind the widget (Appearance > Background)
        local keep = S
        st.bg_style = 0                            -- (no FFXI menu background in Vex / Hex link)
        S = st
        pcall(draw_background, wx, wy, W, H)
        S = keep

        -- the lavender window frame (Vex)

        local clicked_any = false
        for n, it in ipairs(items) do
            local x, y = wx + it.x, wy + it.y
            local w, h = it.w, it.h
            local c = it.st and TAGC[it.st] or nil
            local lock = (it.st == 'lock')
            local ncol = (lock and (not vex or o.goldlock)) and o.lockname or st.name.color

            if it.kind == 'btns' then
                local bx = x
                for _, b in ipairs({ { show_cfg_btn, 'UI', 46, false, 'u' }, { show_move_btn, 'MOVE', 74, locked_any, 'm' } }) do
                    if b[1] then
                        local bw = b[3] * u
                        local lit = b[4]
                        if vex then vex_plate(bx, y, bw, h, lit) else hex_plate(bx, y, bw, h, lit) end
                        text_c(bx + bw / 2, y + h / 2, b[2], NAME_PX * 0.85, lit and o.lockname or st.name.color)
                        imgui.SetCursorPosX(bx - wx)
                        imgui.SetCursorPosY(y - wy)
                        if imgui.InvisibleButton('##smt_' .. b[5], { bw, h }) and not suppress then
                            clicked_any = true
                            if b[5] == 'm' then allow_move() else cfg_open[1] = not cfg_open[1] end
                        end
                        pcall(function()
                            if imgui.IsItemHovered() then imgui.SetTooltip(b[5] == 'm' and 'Allow Move' or 'StopMove settings') end
                        end)
                        bx = bx + bw + 5 * u
                    end
                end
            elseif it.kind == 'u' or it.kind == 'm' then
                local lit = (it.kind == 'm') and locked_any
                local L = (it.kind == 'm') and 'M' or 'U'
                if vex then vex_plate(x, y, w, h, lit) else hex_plate(x, y, w, h, lit) end
                text_c(x + w / 2, y + h / 2, L, LET_PX, lit and o.lockname or st.name.color)
            elseif letter then
                local v = o.ls
                if vex and alliance then                       -- Vex Menu letters
                    if v == 'A' then
                        vex_rtag(x + 2 * u, y + 2 * u, x + w - 2 * u, y + h - 2 * u, c, it.txt, 13)
                    else
                        vex_card(x, y, w, h, lock)
                        local flip = (o.view == 'B')
                        local lx = flip and (x + w - 11 * u) or (x + 11 * u)
                        text_c(lx, y + h / 2, it.txt, LET_PX, ncol)
                        local cut = flip and (x + w - 22 * u) or (x + 22 * u)
                        vex_vdiv(cut, y, h)
                        if v == 'B' then
                            if flip then vex_rtag(x + 5 * u, y + 7 * u, cut - 5 * u, y + h - 7 * u, c, '', 10)
                            else vex_rtag(cut + 5 * u, y + 7 * u, x + w - 5 * u, y + h - 7 * u, c, '', 10) end
                        else
                            local dx = flip and (x + 12 * u) or (x + w - 12 * u)
                            dl:AddCircleFilled({ dx, y + h / 2 }, 5 * u, u32(c[1]), 16)
                        end
                    end
                elseif vex then
                    if v == 'A' then
                        -- a dark tag (upright on the outer side), the letter in white, and one bar in
                        -- the ON / OFF / LOCK colour along its foot
                        local k = h * 0.32
                        local P = par(x, y, w, h, k)                   -- both sides slanted, like the name plates
                        poly_fill(dl, P, u32(o.plate, math.max(o.plate_a, 0.9)))
                        if lock and o.goldlock then
                            poly_line(dl, P, u32(c[1], 0.25), 3.5 * u)
                            poly_line(dl, P, u32(c[1], 0.95), 1)
                        else
                            poly_line(dl, P, u32({ 0.29, 0.27, 0.34 }, 0.8), 1)
                        end
                        local ty = y + (h - 7 * u) / 2
                        text_c(x + w / 2 + k * (0.5 - (ty - y) / h) , ty, it.txt, LET_PX * 1.5, lock and o.goldlock and o.lockname or { 1, 1, 1 })
                        local bh, by = 4 * u, y + h - 8 * u
                        local sk = bh * 0.32
                        local xa = x + k * (1 - (by - y) / h) + 5 * u     -- inside the slanted sides at the bar's height
                        local xb = x + w - k * ((by - y) / h) - 5 * u
                        poly_fill(dl, { { xa + sk, by }, { xb + sk, by }, { xb, by + bh }, { xa, by + bh } }, u32(c[1]))
                    elseif v == 'B' then
                        -- tag and plate touching (their slanted edges meet); view B puts the plate first
                        local th_, tw_, pw = 16 * u, 18 * u, 34 * u
                        local touch = 0.32 * (h + th_) / 2
                        if o.view == 'B' then
                            vex_plate(x, y, pw, h, lock)
                            text_c(x + pw / 2 - 1 * u, y + h / 2, it.txt, LET_PX, ncol)
                            vex_tag_r(x + pw - touch, y + (h - th_) / 2, tw_, th_, c, '', 10)
                        else
                            vex_tag(x, y + (h - th_) / 2, tw_, th_, c, '', 10)
                            local px = x + tw_ - touch
                            vex_plate(px, y, pw, h, lock)
                            text_c(px + pw / 2 - 1 * u, y + h / 2, it.txt, LET_PX, ncol)
                        end
                    else
                        vex_plate(x, y, w, h, lock)
                        local lx, dx = x + 15 * u, x + 28 * u           -- view B: the dot first, then the letter
                        if o.view == 'B' then lx, dx = x + 27 * u, x + 13 * u end
                        text_c(lx, y + h / 2, it.txt, LET_PX, ncol)
                        dl:AddCircleFilled({ dx, y + h / 2 }, 4.5 * u, u32(c[1]), 16)
                    end
                else
                    hex_plate(x, y, w, h, lock)
                    if v == 'A' then
                        hex_tag(x + 6 * u, y + 5 * u, x + w - 5 * u, y + h - 5 * u, c, it.txt, 13, { 1, 1, 1 })   -- letter A: white letters
                    elseif o.view == 'B' then                  -- view B: flipped - the ON / OFF mark first, then the letter
                        text_c(x + w - 12 * u, y + h / 2, it.txt, LET_PX, ncol)
                        local cut = x + w - (v == 'B' and 25 or 24) * u
                        hex_divider(cut, y, h)
                        if v == 'B' then
                            hex_tag(x + 5 * u, y + 6 * u, cut - 6 * u, y + h - 6 * u, c, '', 10)
                        else
                            dl:AddCircleFilled({ x + 12 * u, y + h / 2 }, 5.5 * u, u32(c[1]), 16)
                            dl:AddCircle({ x + 12 * u, y + h / 2 }, 4 * u, u32(c[2], 0.8), 16, 1)
                        end
                    else
                        text_c(x + 12 * u, y + h / 2, it.txt, LET_PX, ncol)
                        local cut = x + (v == 'B' and 25 or 24) * u
                        hex_divider(cut, y, h)
                        if v == 'B' then
                            hex_tag(cut + 6 * u, y + 6 * u, x + w - 5 * u, y + h - 6 * u, c, '', 10)
                        else
                            dl:AddCircleFilled({ x + w - 12 * u, y + h / 2 }, 5.5 * u, u32(c[1]), 16)
                            dl:AddCircle({ x + w - 12 * u, y + h / 2 }, 4 * u, u32(c[2], 0.8), 16, 1)
                        end
                    end
                end
            elseif vex and alliance then
                -- Vex Menu: one rounded card - the name, a lucent blue divider, the rounded tag
                -- (view B: the tag first, the name after)
                vex_card(x, y, w, h, lock)
                local flip = (o.view == 'B')
                local th_ = o.tag_h * u
                local nh = lh * s * NAME_PX / 13
                local tl = flip and (x + 7 * u) or (x + (7 + o.name_w + o.gap) * u)
                local nl = flip and (x + (7 + o.tag_w + o.gap) * u) or (x + 9 * u)
                local nr = nl + (o.name_w - 4) * u
                local nx = (o.align == 'right') and (nr - spaced_w(it.txt, NAME_PX, SP)) or nl
                text(nx, y + (h - nh) / 2, it.txt, NAME_PX, ncol, SP)
                local cut = flip and (x + (7 + o.tag_w + o.gap / 2) * u) or (x + (7 + o.name_w + o.gap / 2) * u)
                vex_vdiv(cut, y, h)
                vex_rtag(tl, y + (h - th_) / 2, tl + o.tag_w * u, y + (h + th_) / 2, c,
                         st.badge_text and LBL[it.st] or '', math.min(10.5, o.tag_h * 0.62))
            elseif vex and o.view == 'B' then
                -- Vex view B, after YunaUI's other party row: one slanted plate holding the name
                -- over two bars (where HP and MP sit), an empty spot at its right (where TP sits),
                -- then the ON / OFF tag
                local ph = o.name_h * u
                local py = y + (h - ph) / 2
                local pw = (o.name_w + 36) * u                  -- + the empty spot where YunaUI shows TP
                vex_plate(x, py, pw, ph, lock)
                local k = ph * 0.32
                local il = x + k + 4 * u                       -- the name / bar area
                local ir = x + o.name_w * u - 2 * u
                local nh = lh * s * NAME_PX / 13
                local by = py + ph - 7 * u
                local ny = py + (by - py - nh) / 2 + 1 * u
                local nx = (o.align == 'right') and (ir - spaced_w(it.txt, NAME_PX, SP)) or il
                text(nx, ny, it.txt, NAME_PX, ncol, SP)
                -- two slanted bars (leaning with the plate, as YunaUI's HP / MP bars), ending well
                -- before the plate's empty right end
                local bh = 4 * u
                local sk = bh * 0.9
                local br = il + (ir - il) * 0.82
                local mid = il + (br - il) * 0.5
                local function bar(x0, x1, col)
                    local P = { { x0 + sk, by - 1 * u }, { x1 + sk, by - 1 * u }, { x1, by - 1 * u + bh }, { x0, by - 1 * u + bh } }
                    poly_fill(dl, P, u32({ 0.14, 0.13, 0.17 }, 0.9))
                    poly_fill(dl, P, u32(col))
                end
                bar(il - 2 * u, mid - 3 * u, c[1])
                bar(mid + 3 * u, br, c[2])
                local th_ = o.tag_h * u
                local tx = x + pw + (o.gap - 0.32 * (o.name_h + o.tag_h) / 2) * u   -- gap 0: touching the plate
                local tag_px = math.min(10.5, o.tag_h * 0.62)
                vex_tag_r(tx, y + (h - th_) / 2, (o.tag_w + 8) * u, th_, c, st.badge_text and LBL[it.st] or '', tag_px)   -- (a little longer in view B)
            elseif vex then
                local tw_, th_ = o.tag_w * u, o.tag_h * u
                local tag_px = math.min(alliance and 8.5 or 10.5, o.tag_h * 0.62)
                vex_tag(x, y + (h - th_) / 2, tw_, th_, c, st.badge_text and LBL[it.st] or '', tag_px)
                local px = x + tw_ + (o.gap - 0.32 * (o.name_h + o.tag_h) / 2) * u   -- gap 0: its slanted edge on the plate's
                local ph = o.name_h * u
                local py = y + (h - ph) / 2
                vex_plate(px, py, o.name_w * u, ph, lock)
                local bar = o.name_h >= 16                 -- the state bar, when the plate is tall enough
                local th = lh * s * NAME_PX / 13
                local ny = py + ((bar and ph - 5 * u or ph) - th) / 2
                local nx = px + (alliance and 10 or 13) * u    -- the name: at the plate's left, or its right
                if o.align == 'right' then nx = px + (o.name_w - (alliance and 12 or 15)) * u - spaced_w(it.txt, NAME_PX, SP) end
                text(nx, ny, it.txt, NAME_PX, ncol, SP)
                if bar then
                    vex_bar(px + (alliance and 9 or 11) * u, py + ph - (alliance and 4 or 7) * u, o.name_w * u - (alliance and 22 or 28) * u, c)
                end
            elseif o.view == 'B' then
                -- Hex link view B, as YunaUI's other party plate: the state tag where the job
                -- tag sits, the name over a state-coloured bar, and a small box at the right
                -- (MOVE OK / NO) where the TP box sits
                hex_plate(x, y, w, h, lock)
                local th_ = o.tag_h * u
                local tl = x + 6 * u
                do                                             -- the tag: left side upright, right side slanted (as the job tag)
                    local t, b, r = y + (h - th_) / 2, y + (h + th_) / 2, tl + o.tag_w * u
                    local k = th_ * 0.35
                    local P = { { tl, t }, { r, t }, { r - k, b }, { tl, b } }
                    poly_fill(dl, P, u32(c[1]))
                    poly_line(dl, P, u32({ 0.04, 0.04, 0.055 }), 1)
                    local i = 1.5 * u
                    poly_line(dl, { { tl + i, t + i }, { r - i * 1.4, t + i }, { r - k - i * 0.4, b - i }, { tl + i, b - i } }, u32(c[2], 0.8), 1)
                    local lbl = st.badge_text and LBL[it.st] or ''
                    if lbl ~= '' then
                        text_c(tl + (r - k / 2 - tl) / 2, (t + b) / 2, lbl, math.min(11, o.tag_h * 0.55) * TAG_K, tag_text(c), TAG_PART)
                    end
                end
                local nl = tl + (o.tag_w + o.gap) * u          -- the name area
                local nr = nl + o.name_w * u
                local nh = lh * s * NAME_PX / 13
                local ny = y + (h - nh - 10 * u) / 2
                local nx = nl
                if o.align == 'right' then nx = nr - spaced_w(it.txt, NAME_PX, SP) end
                text(nx, ny, it.txt, NAME_PX, ncol, SP)
                -- the bar: a band with pointed ends (as YunaUI's HP bar), a light line along its top
                local bh = 7.5 * u
                local by = ny + nh + 2 * u
                local kb = bh / 2
                local band = { { nl, by + kb }, { nl + kb, by }, { nr - kb, by }, { nr, by + kb }, { nr - kb, by + bh }, { nl + kb, by + bh } }
                poly_fill(dl, band, u32({ 0.10, 0.09, 0.13 }, 0.9))
                local fill = { { nl + 1, by + kb }, { nl + kb, by + 1 }, { nr - kb, by + 1 }, { nr - 1, by + kb }, { nr - kb, by + bh - 1 }, { nl + kb, by + bh - 1 } }
                poly_fill(dl, fill, u32(c[1]))
                dl:AddLine({ nl + kb, by + 1.5 }, { nr - kb, by + 1.5 }, u32(c[2], 0.85), 1)
                hex_divider(x + w - 34 * u, y, h)               -- the right box (where the TP sits): left empty
            else
                hex_plate(x, y, w, h, lock)
                local nx = x + 12 * u                          -- the name: at the plate's left, or against the divider
                if o.align == 'right' then nx = x + (o.name_w - 4) * u - spaced_w(it.txt, NAME_PX, SP) end
                text(nx, y + h / 2 - (lh * s * NAME_PX / 13) / 2, it.txt, NAME_PX, ncol, SP)
                local cut = x + (o.name_w + o.gap / 2) * u      -- the divider, in the middle of the gap
                hex_divider(cut, y, h)
                local tl = x + (o.name_w + o.gap) * u
                local th_ = o.tag_h * u
                hex_tag(tl, y + (h - th_) / 2, tl + o.tag_w * u, y + (h + th_) / 2, c,
                        st.badge_text and LBL[it.st] or '', math.min(11, o.tag_h * 0.55))
            end

            -- clicks: a character switches it on / off; U opens settings; M = Allow Move
            if it.kind ~= 'btns' then
                imgui.SetCursorPosX(it.x)
                imgui.SetCursorPosY(it.y)
                if imgui.InvisibleButton('##smt_' .. n .. '_' .. it.kind, { w, h }) and not suppress then
                    clicked_any = true
                    if it.kind == 'm' then allow_move()
                    elseif it.kind == 'u' then cfg_open[1] = not cfg_open[1]
                    elseif it.e.active and it.e.click then it.e.click() end
                end
                if it.kind ~= 'char' then
                    pcall(function()
                        if imgui.IsItemHovered() then imgui.SetTooltip(it.kind == 'm' and 'Allow Move' or 'StopMove settings') end
                    end)
                end
            end
        end
        if clicked_any then pcall(function() imgui.SetWindowFocus() end) end   -- hand the keyboard back to the game

        -- mouse wheel over the widget = bigger / smaller (saved with this look)
        if not lock_pos then
            pcall(function()
                local wheel = imgui.GetIO().MouseWheel
                if wheel ~= 0 and imgui.IsWindowHovered() then
                    o.size = clamp(o.size * (1 + 0.1 * wheel), 0.4, 3.0)
                    save_settings()
                end
            end)
        end
        pcall(function()
            if imgui.IsWindowHovered() and imgui.IsMouseClicked(1) then cfg_open[1] = not cfg_open[1] end
        end)
    end
    imgui.End()
    imgui.PopStyleColor(1)
    imgui.PopStyleVar(2)
end

----------------------------------------------------------------------
-- Settings window (/stopmove, or right-click the widget)
-- Laid out like Vanacore's own settings: pages in a sidebar, a gold page
-- title, teal section headers (each with its own reset), switches and
-- segmented buttons.
----------------------------------------------------------------------
CFG.page          = 'general'
CFG.copy_note     = nil       -- { text, until } after Copy to <name>
CFG.file_name     = { 'my setup' }
CFG.file_note     = nil       -- { text, until } after Save / Load
CFG.search        = ''
CFG.reset_confirm = 0         -- "Reset all" needs a second click within 3 seconds

CFG.VC = {                    -- Vanacore's colours
    bg    = { 0.078, 0.094, 0.129, 0.98 },
    side  = { 0.063, 0.075, 0.102, 1.00 },
    line  = { 0.137, 0.157, 0.212, 1.00 },
    text  = { 0.85, 0.87, 0.90, 1.00 },
    dim   = { 0.56, 0.59, 0.66, 1.00 },
    mute  = { 0.43, 0.46, 0.53, 1.00 },
    gold  = { 0.91, 0.69, 0.29, 1.00 },
    teal  = { 0.25, 0.82, 0.72, 1.00 },
    acc   = { 0.36, 0.78, 1.00, 1.00 },
    on    = { 0.36, 0.55, 0.94, 1.00 },
    off   = { 0.165, 0.184, 0.235, 1.00 },
    knob  = { 0.90, 0.91, 0.94, 1.00 },
    field = { 0.047, 0.059, 0.082, 1.00 },
    seg   = { 0.165, 0.192, 0.259, 1.00 },
}

-- a small line icon at (x, cy), size sz: about, stop, widget, files, test, reset, info
function CFG.icon(dl, kind, x, cy, sz, col)
    local r = sz / 2
    local cx = x + r
    if kind == 'about' or kind == 'info' then
        dl:AddCircle({ cx, cy }, r, col, 16, 1.2)
        dl:AddLine({ cx, cy - r * 0.15 }, { cx, cy + r * 0.5 }, col, 1.4)
        dl:AddCircleFilled({ cx, cy - r * 0.45 }, 1.1, col, 6)
    elseif kind == 'stop' then                         -- a stop sign (octagon)
        local p, k = {}, r * 0.92
        for i = 0, 7 do
            local a = (i + 0.5) * math.pi / 4
            p[#p + 1] = { cx + math.cos(a) * k, cy + math.sin(a) * k }
        end
        for i = 1, 8 do dl:AddLine(p[i], p[i % 8 + 1], col, 1.3) end
        dl:AddLine({ cx - r * 0.4, cy }, { cx + r * 0.4, cy }, col, 1.6)
    elseif kind == 'widget' then                       -- four small squares
        local q = r * 0.8
        for _, o in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            local qx, qy = cx + o[1] * q * 0.6, cy + o[2] * q * 0.6
            dl:AddRect({ qx - q * 0.42, qy - q * 0.42 }, { qx + q * 0.42, qy + q * 0.42 }, col, 1, 0, 1.2)
        end
    elseif kind == 'files' then                        -- a floppy disk
        dl:AddRect({ cx - r, cy - r }, { cx + r, cy + r }, col, 2, 0, 1.2)
        dl:AddRect({ cx - r * 0.5, cy - r }, { cx + r * 0.4, cy - r * 0.25 }, col, 0, 0, 1.1)
        dl:AddRect({ cx - r * 0.55, cy + r * 0.15 }, { cx + r * 0.55, cy + r }, col, 0, 0, 1.1)
    elseif kind == 'test' then                         -- a play triangle
        dl:AddLine({ cx - r * 0.6, cy - r }, { cx + r * 0.85, cy }, col, 1.3)
        dl:AddLine({ cx + r * 0.85, cy }, { cx - r * 0.6, cy + r }, col, 1.3)
        dl:AddLine({ cx - r * 0.6, cy + r }, { cx - r * 0.6, cy - r }, col, 1.3)
    elseif kind == 'reset' then                        -- a circular arrow
        local n, a0, a1 = 14, -0.25 * math.pi, 1.45 * math.pi
        local prev
        for i = 0, n do
            local a = a0 + (a1 - a0) * i / n
            local pt = { cx + math.cos(a) * r * 0.85, cy + math.sin(a) * r * 0.85 }
            if prev then dl:AddLine(prev, pt, col, 1.3) end
            prev = pt
        end
        local tip = { cx + math.cos(a0) * r * 0.85, cy + math.sin(a0) * r * 0.85 }
        dl:AddLine(tip, { tip[1] - r * 0.55, tip[2] - r * 0.05 }, col, 1.3)
        dl:AddLine(tip, { tip[1] + r * 0.05, tip[2] - r * 0.6 }, col, 1.3)
    end
end

function CFG.reset_all()
    S = default_style()
    ui_alpha = 1.0
    enabled = true
    show_ui, lock_pos = true, false
    low_profile, letter_badge, layout_mode, rot = false, false, 0, 0
    block_keys, block_wasd, inject, wait_for_stop = true, false, true, true
    ms_enabled, ms_quiet, ms_off_cmd, ms_on_cmd = true, true, '/ms follow off', '/ms follow on'
    gf_enabled, gf_name, gf_saved = true, '', nil
    WAIT_STILL, WAIT_MAX, MAX_LOCK, UNLOCK_DONE, UNLOCK_INT = 0.15, 1.0, 9, 0.0, 10.0
    theme = 'classic'
    reset_theme('classic')
    reset_theme('vex')
    reset_theme('hex')
    last_scale, refit, pending = 1.0, true, nil
    save_char()
end

local function draw_config()
    if not cfg_open[1] then return end
    local VC = CFG.VC

    local function v2(a, b) if type(a) == 'table' then return a[1], a[2] end return a or 0, b or 0 end
    local function avail_w() local ok, a, b = pcall(imgui.GetContentRegionAvail); if not ok then return 300 end return (v2(a, b)) end
    local function screen_pos() return v2(imgui.GetCursorScreenPos()) end
    local function U(c) return imgui.GetColorU32(c) end

    -- window colours and shapes (each push is counted so they always pop)
    local ncol, nvar = 0, 0
    local function col(id, c) if id then imgui.PushStyleColor(id, c); ncol = ncol + 1 end end
    local function var(id, v) if id and pcall(imgui.PushStyleVar, id, v) then nvar = nvar + 1 end end
    col(ImGuiCol_WindowBg, VC.bg);          col(ImGuiCol_ChildBg, { 0, 0, 0, 0 })
    col(ImGuiCol_Border, VC.line);          col(ImGuiCol_Text, VC.text)
    col(ImGuiCol_TextDisabled, VC.dim);     col(ImGuiCol_TitleBg, VC.side)
    col(ImGuiCol_TitleBgActive, VC.side);   col(ImGuiCol_FrameBg, VC.field)
    col(ImGuiCol_FrameBgHovered, VC.seg);   col(ImGuiCol_FrameBgActive, VC.seg)
    col(ImGuiCol_Button, { 0.106, 0.125, 0.169, 1 })
    col(ImGuiCol_ButtonHovered, VC.seg);    col(ImGuiCol_ButtonActive, { 0.22, 0.26, 0.34, 1 })
    col(ImGuiCol_Header, { 0, 0, 0, 0 });   col(ImGuiCol_HeaderHovered, { 1, 1, 1, 0.04 })
    col(ImGuiCol_HeaderActive, { 1, 1, 1, 0.06 })
    col(ImGuiCol_SliderGrab, VC.on);        col(ImGuiCol_SliderGrabActive, VC.acc)
    col(ImGuiCol_CheckMark, VC.acc);        col(ImGuiCol_ScrollbarBg, { 0, 0, 0, 0 })
    col(ImGuiCol_ResizeGrip, { 0.85, 0.85, 0.85, 0.30 })
    col(ImGuiCol_ResizeGripHovered, { 1, 1, 1, 0.70 }); col(ImGuiCol_ResizeGripActive, { 1, 1, 1, 0.90 })
    var(ImGuiStyleVar_WindowRounding, 8);   var(ImGuiStyleVar_FrameRounding, 6)
    var(ImGuiStyleVar_ItemSpacing, { 8, 6 })

    imgui.SetNextWindowSize({ 640, 540 }, ImGuiCond_FirstUseEver)
    pcall(function() imgui.SetNextWindowSizeConstraints({ 470, 300 }, { 1100, 1300 }) end)

    pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 0, 0 })
    local began = imgui.Begin('StopMove###sm_settings', cfg_open, ImGuiWindowFlags_NoCollapse or 0)
    pcall(imgui.PopStyleVar, 1)
    if began then
        local changed = false
        local searching = CFG.search ~= ''
        local function shown(label)
            return not searching or label:lower():find(CFG.search:lower(), 1, true) ~= nil
        end

        ------------------------------------------------------------------
        -- building blocks
        ------------------------------------------------------------------
        local function title(t, sub)
            if searching then return end
            pcall(imgui.SetWindowFontScale, 1.35)
            imgui.TextColored(VC.gold, t)
            pcall(imgui.SetWindowFontScale, 1.0)
            if sub then imgui.SameLine(); imgui.TextColored(VC.gold, sub) end
        end
        -- section header: teal caps, a line to the right edge, and its own reset
        local function section(t, reset_fn)
            if searching then return end
            imgui.Dummy({ 1, 4 })
            imgui.TextColored(VC.teal, t)
            local tx1, ty1 = v2(imgui.GetItemRectMax())
            local tx0, ty0 = v2(imgui.GetItemRectMin())
            local wx = screen_pos() + avail_w()
            local rx = wx - (reset_fn and 28 or 0)
            pcall(function()
                imgui.GetWindowDrawList():AddLine({ tx1 + 10, (ty0 + ty1) / 2 }, { rx, (ty0 + ty1) / 2 }, U({ VC.teal[1], VC.teal[2], VC.teal[3], 0.55 }), 1)
            end)
            if reset_fn then
                imgui.SameLine(imgui.GetCursorPosX() + avail_w() - 18)
                local ix, iy = screen_pos()
                if imgui.InvisibleButton('##rst_' .. t, { 16, 16 }) then reset_fn(); changed = true; refit = true end
                local hov = imgui.IsItemHovered()
                pcall(CFG.icon, imgui.GetWindowDrawList(), 'reset', ix + 1, iy + 8, 13, U(hov and VC.text or VC.mute))
                pcall(function() if hov then imgui.SetTooltip('Put this section back to its defaults') end end)
            end
        end
        local function note(t)
            if searching then return end
            local ix, iy = screen_pos()
            pcall(CFG.icon, imgui.GetWindowDrawList(), 'info', ix + 1, iy + 8, 12, U(VC.mute))
            pcall(imgui.Indent, 20)
            imgui.PushStyleColor(ImGuiCol_Text, VC.dim)
            pcall(imgui.PushTextWrapPos, 0)
            imgui.Text(t)
            pcall(imgui.PopTextWrapPos)
            imgui.PopStyleColor(1)
            pcall(imgui.Unindent, 20)
        end
        -- a row: the label on the left, its control right-aligned (cw = control width)
        local function label_row(label, cw)
            local x0 = imgui.GetCursorPosX()
            local aw = avail_w()
            pcall(imgui.AlignTextToFramePadding)
            local star = label:find('%*$')
            if star then
                imgui.Text(label:sub(1, star - 1))
                imgui.SameLine(0, 2)
                imgui.TextColored(VC.gold, '*')
            else
                imgui.Text(label)
            end
            imgui.SameLine(x0 + math.max(160, aw - cw))
        end
        local function switch(label, v)
            if not shown(label) then return nil end
            label_row(label, 36)
            local x, y = screen_pos()
            local w, h = 34, 18
            local clicked = imgui.InvisibleButton('##sw_' .. label, { w, h })
            pcall(function()
                local dl = imgui.GetWindowDrawList()
                dl:AddRectFilled({ x, y }, { x + w, y + h }, U(v and VC.on or VC.off), h / 2)
                dl:AddCircleFilled({ v and (x + w - h / 2) or (x + h / 2), y + h / 2 }, h / 2 - 2, U(VC.knob), 16)
            end)
            if clicked then changed = true; return not v end
            return nil
        end
        local function seg(label, opts, cur)        -- segmented buttons; returns the picked value
            if not shown(label) then return nil end
            local tw_ = 0
            for _, op in ipairs(opts) do
                local a = imgui.CalcTextSize(op[2])
                tw_ = tw_ + (v2(a)) + 18
            end
            label_row(label, tw_ + 2)
            local picked = nil
            local gx, gy = screen_pos()
            for i, op in ipairs(opts) do
                if i > 1 then imgui.SameLine(0, 0) end
                local on = (op[1] == cur)
                imgui.PushStyleColor(ImGuiCol_Button, on and VC.seg or VC.field)
                imgui.PushStyleColor(ImGuiCol_Text, on and VC.text or VC.dim)
                if imgui.Button(op[2] .. '##seg_' .. label) then picked = op[1] end
                imgui.PopStyleColor(2)
            end
            pcall(function()                           -- one frame round the group, as Vanacore's
                local x1, y1 = v2(imgui.GetItemRectMax())
                imgui.GetWindowDrawList():AddRect({ gx - 1, gy - 1 }, { x1 + 1, y1 + 1 }, U(VC.line), 6, 0, 1)
            end)
            if picked ~= nil and picked ~= cur then changed = true; refit = true; return picked end
            return nil
        end
        local function number(label, v, step, fmt, lo, hi)
            if not shown(label) then return nil end
            label_row(label, 130)
            pcall(imgui.PushItemWidth, 130)
            local box = { v }
            local ch = imgui.InputFloat('##num_' .. label, box, step, step * 2, fmt)
            pcall(imgui.PopItemWidth)
            if ch then changed = true; return clamp(box[1], lo, hi) end
            return nil
        end
        local function textbox(label, v)
            if not shown(label) then return nil end
            label_row(label, 170)
            pcall(imgui.PushItemWidth, 170)
            local buf = { v }
            local ok, res = pcall(imgui.InputText, '##txt_' .. label, buf, 128)
            pcall(imgui.PopItemWidth)
            if ok and res then changed = true; return buf[1] end
            return nil
        end
        local function button_row(label, btn)
            if not shown(label) then return false end
            local a = imgui.CalcTextSize(btn)
            label_row(label, (v2(a)) + 16)
            return imgui.Button(btn .. '##btn_' .. label)
        end
        local function slider(label, v, lo, hi, fmt)
            if not shown(label) then return nil end
            label_row(label, 200)
            pcall(imgui.PushItemWidth, 200)
            local a = { v }
            local ch = imgui.SliderFloat('##sl_' .. label, a, lo, hi, fmt)
            pcall(imgui.PopItemWidth)
            if ch then changed = true; return clamp(a[1], lo, hi) end
            return nil
        end
        local function colour(label, t)
            if not shown(label) then return end
            label_row(label, 200)
            pcall(imgui.PushItemWidth, 200)
            local c = { t[1], t[2], t[3], t[4] }
            if imgui.ColorEdit4('##col_' .. label, c) then
                t[1], t[2], t[3], t[4] = c[1], c[2], c[3], c[4]
                changed = true
            end
            pcall(imgui.PopItemWidth)
        end
        local function text_options(id, p)
            colour(id .. ' colour', p.color)
            local v
            v = slider(id .. ' size', p.size, 0.1, 2.5, '%.2f');  if v then p.size = v; refit = true end
            v = switch(id .. ' bold', p.bold);                    if v ~= nil then p.bold = v; refit = true end
            v = switch(id .. ' drop shadow', p.shadow);           if v ~= nil then p.shadow = v end
            v = switch(id .. ' outline', p.outline);              if v ~= nil then p.outline = v end
            if p.outline then
                colour(id .. ' outline colour', p.outline_color)
                v = slider(id .. ' outline width', p.outline_w, 0.5, 4.0, '%.1f'); if v then p.outline_w = v end
            end
        end

        ------------------------------------------------------------------
        -- pages
        ------------------------------------------------------------------
        local PAGES = {}
        PAGES.general = function()
            title('General')
            section('THIS CHARACTER')
            local v
            v = switch('Enabled for this character', enabled);  if v ~= nil then set_enabled(v) end
            v = switch('Show the widget', show_ui);              if v ~= nil then show_ui = v end
            v = switch('Lock widget position and size', lock_pos); if v ~= nil then lock_pos = v end
            section('ALLOW MOVE')
            if button_row('End the cast lock now', 'Allow Move') then allow_move() end
            note('Allow Move frees every locked character and lets a key you are holding move you straight away.')
        end
        PAGES.casting = function()
            title('Casting')
            section('MOVEMENT KEYS', function() block_keys, block_wasd, inject = true, false, true end)
            local v
            v = switch('Disable numpad 8 / 2 / 4 / 6', block_keys);          if v ~= nil then block_keys = v end
            v = switch('Also disable W / A / S / D *', block_wasd);          if v ~= nil then block_wasd = v end
            v = switch('Release held keys at cast start', inject);           if v ~= nil then inject = v end
            note('* W / A / S / D also stop working in chat while you cast.')
            section('BEFORE THE CAST', function() wait_for_stop = true end)
            v = switch('Wait until stopped before casting', wait_for_stop);  if v ~= nil then wait_for_stop = v; pending = nil end
            note('If you press a spell while moving, it is held until you have stood still for the spell cast delay (Timing).')
        end
        PAGES.follow = function()
            title('Follow')
            section('MULTISEND', function()
                ms_enabled, ms_quiet, ms_off_cmd, ms_on_cmd = true, true, '/ms follow off', '/ms follow on'
            end)
            local v
            v = switch('Multisend follow', ms_enabled)
            if v ~= nil then
                ms_enabled = v
                if not ms_enabled and ms_suspended then
                    ms_suspended = false
                    if ms_on_cmd ~= '' then run_command(ms_on_cmd) end
                end
            end
            v = textbox('Cast starts', ms_off_cmd);                 if v ~= nil then ms_off_cmd = v end
            v = textbox('Cast ends', ms_on_cmd);                    if v ~= nil then ms_on_cmd = v end
            v = switch('Hide Multisend follow messages', ms_quiet);  if v ~= nil then ms_quiet = v end
            note('A blank command sends nothing. Only the replies to these commands are hidden.')
            section('IN-GAME AUTO-FOLLOW', function() gf_enabled, gf_name, gf_saved = true, '', nil end)
            v = switch('Stop and resume /follow', gf_enabled)
            if v ~= nil then gf_enabled = v; if not v then gf_saved = nil end end
            v = textbox('Follow after cast', gf_name);              if v ~= nil then gf_name = v end
            note('Type a name to follow that character after every cast. Blank = re-follow whoever you were following. The named character never follows itself.')
        end
        PAGES.timing = function()
            title('Timing')
            section('HOLDING THE CAST', function() WAIT_STILL, WAIT_MAX = 0.15, 1.0 end)
            local v
            v = number('Spell cast delay (s)', WAIT_STILL, 0.05, '%.2f', 0.05, 1.0);  if v then WAIT_STILL = v end
            v = number('Max hold (s)', WAIT_MAX, 0.1, '%.1f', 0.1, 5.0);              if v then WAIT_MAX = v end
            note('0.25 to 0.30 seconds is safest if you cast while following.')
            section('THE LOCK', function() MAX_LOCK, UNLOCK_DONE, UNLOCK_INT = 9, 0.0, 10.0 end)
            v = number('Max cast lock (s)', MAX_LOCK, 0.5, '%.1f', 1, 30);                   if v then MAX_LOCK = v end
            v = number('Unlock wait: cast completed (s)', UNLOCK_DONE, 0.5, '%.1f', 0, 60);  if v then UNLOCK_DONE = v end
            v = number('Unlock wait: cast interrupted (s)', UNLOCK_INT, 0.5, '%.1f', 0, 60); if v then UNLOCK_INT = v end
            note('Keys unlock when the server says the spell finished or was interrupted. Max cast lock is only a safety net, and it never fires before the spell\'s own cast time (plus 2 seconds), so long casts such as Stoneskin stay locked.')
            note('Unlock wait is the delay before follow turns back on. Keys unlock right away.')
            note('When a cast is interrupted (hit, stunned, silenced, knocked back, paralyzed or intimidated) the widget blinks a red INT for 2 seconds.')
        end
        PAGES.about = function()
            title('About', 'version ' .. tostring(addon.version))
            section('STOPMOVE')
            note('Blocks your numpad (and, if you like, W / A / S / D) movement keys while you cast, so you cannot walk and interrupt the spell by accident.')
            note('Turns Multisend follow and the in-game /follow off for the length of a cast and back on afterwards.')
            note('Shows one ON / OFF badge per character, and works across two clients.')
            section('COMMANDS')
            for _, c in ipairs({ { '/stopmove', 'open or close this window' }, { '/stopmove on | off', 'StopMove on or off for this character' },
                                 { '/stopmove move', 'Allow Move: end the cast lock now' }, { '/stopmove resetbox', 'put the widget back at the top left' } }) do
                imgui.TextColored(VC.acc, c[1]); imgui.SameLine(190); imgui.TextColored(VC.dim, c[2])
            end
            section('WIDGET')
            note('Right-click the widget to open this window. Shift + drag moves it (any drag works while this window is open). Roll the mouse wheel over it to resize it.')
            section('CREDITS')
            note('Written with Claude (Anthropic), directed and tested by Benthere407. Built on Ashita v4 and its Dear ImGui. Multisend (ThornyFFXI) is used only through /ms follow.')
            note('The Vex and Hex link looks are modelled on YunaUI by Yunas. The settings window is inspired by the VanaCore menus by Vekien and Josh.Xero.')
            note('Thanks to Toots for support in adjusting the cast lock durations for longer spells.')
        end

        PAGES.files = function()
            title('Save and load')
            section('SAVE')
            if not searching then
                label_row('File name', 230)
                pcall(imgui.PushItemWidth, 160)
                pcall(imgui.InputText, '##sm_fname', CFG.file_name, 48)
                pcall(imgui.PopItemWidth)
                imgui.SameLine()
                if imgui.Button('Save##sm_save') then
                    local saved = CFG.save_config(CFG.file_name[1])
                    if saved then CFG.pick = saved end
                    CFG.file_note = { saved and ('Saved "' .. saved .. '".') or 'Type a name first (letters, numbers, spaces).', os.clock() + 4 }
                end
                note('Saves everything: this character\'s themes and looks, and the shared casting, follow and timing settings. The character\'s name is added to the file name ("' .. (my_name() or 'Name') .. ' - my setup").')
            end
            section('LOAD')
            if searching then return end
            local list = CFG.saved_configs()
            if #list == 0 then
                note('No saved configurations yet.')
            else
                local found = false
                for _, n in ipairs(list) do if n == CFG.pick then found = true end end
                if not found then CFG.pick = list[1] end
                label_row('Configuration', 290)
                pcall(imgui.PushItemWidth, 220)
                local ok, open = pcall(imgui.BeginCombo, '##sm_pick', CFG.pick)
                if ok and open then
                    for _, n in ipairs(list) do
                        if imgui.Selectable(n .. '##pk_' .. n, n == CFG.pick) then CFG.pick = n end
                    end
                    imgui.EndCombo()
                end
                pcall(imgui.PopItemWidth)
                imgui.SameLine()
                if imgui.Button('Load##sm_load') then
                    local done = CFG.load_config(CFG.pick)
                    CFG.file_note = { done and ('Loaded "' .. CFG.pick .. '".') or ('Could not read "' .. CFG.pick .. '".'), os.clock() + 4 }
                end
                note('Loading changes this character\'s looks and the shared settings (both clients).')
            end

            section('PUSH TO THE OTHER CLIENT')
            if other_count == 0 then
                note('Load StopMove on a second client to push settings to it.')
            else
                -- two steps: the first click arms the button, a second click within 4 seconds pushes
                local function armed(key) return CFG.arm and CFG.arm[1] == key and os.clock() < CFG.arm[2] end
                local function push_btn(label, key, text)
                    local on = armed(key)
                    if on then imgui.PushStyleColor(ImGuiCol_Button, { 0.55, 0.16, 0.18, 1 }) end
                    local hit = button_row(label, (on and 'Click again to push' or text) .. '##' .. key)
                    if on then imgui.PopStyleColor(1) end
                    if not hit then return false end
                    if on then CFG.arm = nil; return true end
                    CFG.arm = { key, os.clock() + 4 }
                    return false
                end
                for _, nm in ipairs(other_names) do
                    if #list > 0 and push_btn('Push "' .. (CFG.pick or '') .. '" to ' .. nm, 'psf_' .. nm, 'Push to ' .. nm) then
                        local done = CFG.push_to(nm, CFG.pick)
                        CFG.file_note = { done and ('Pushed "' .. CFG.pick .. '" to ' .. nm .. '.') or 'Could not push.', os.clock() + 4 }
                    end
                    if push_btn('Push the settings in use now to ' .. nm, 'psn_' .. nm, 'Push now') then
                        local done = CFG.push_to(nm, nil)
                        CFG.file_note = { done and ('Pushed the current settings to ' .. nm .. '.') or 'Could not push.', os.clock() + 4 }
                    end
                end
                note('Pushing takes two clicks: click once, then "Click again to push" within 4 seconds.')
                note('The other client first saves what it had (as "before push" with the date and time), then loads what you pushed.')
            end
            if CFG.file_note and os.clock() < CFG.file_note[2] then imgui.TextColored(VC.teal, CFG.file_note[1]) end
            note('Files are in addons\\stopmove\\saved, next to the addon.')
        end

        local LOOK_NAME = { classic = 'Classic', vex = 'Vex', hex = 'Hex link' }
        local function switch_look(id)
            if id == theme then return end
            store_profile(theme)
            theme = id
            apply_profile(theme)
            changed = true
        end
        local function reset_look()
            if theme == 'classic' then
                S = default_style()
                reset_theme('classic')
                last_scale = 1.0
            else
                reset_theme(theme)
            end
            apply_profile(theme)
            changed = true
        end
        PAGES.widget = function()
            title('Appearance', 'each theme keeps its own settings')
            local v
            section('THEME')
            v = seg('Theme', { { 'classic', 'Classic' }, { 'vex', 'Vex' }, { 'hex', 'Hex link' } }, theme)
            if v ~= nil then switch_look(v) end
            if button_row('Reset ' .. LOOK_NAME[theme] .. ' to its defaults', 'Reset ' .. LOOK_NAME[theme]) then reset_look() end
            if other_count > 0 then
                for _, nm in ipairs(other_names) do
                    if button_row('Copy ' .. LOOK_NAME[theme] .. ' to ' .. nm, 'Copy to ' .. nm) then
                        CFG.copy_theme_to(nm)
                        CFG.copy_note = { 'Copied ' .. LOOK_NAME[theme] .. ' to ' .. nm .. '.', os.clock() + 4 }
                    end
                end
                if CFG.copy_note and os.clock() < CFG.copy_note[2] then imgui.TextColored(VC.teal, CFG.copy_note[1]) end
            elseif not searching then
                note('Copy to the other client: load StopMove on a second client to see this button.')
            end
            note('Everything below belongs to the ' .. LOOK_NAME[theme] .. ' theme. The other themes keep their own copies.')

            section('ARRANGEMENT', function() layout_mode, rot = 0, 0; if theme ~= 'classic' then TH[theme].align = 'left' end end)
            v = seg('Arrangement', { { 0, 'Stacked' }, { 1, 'Inline' } }, layout_mode);              if v ~= nil then layout_mode = v end
            v = seg('Rotation', { { 0, '0' }, { 1, '90' }, { 2, '180' }, { 3, '270' } }, rot);      if v ~= nil then rot = v end
            if theme ~= 'classic' then
                v = seg('Align', { { 'left', 'Left' }, { 'right', 'Right' } }, TH[theme].align);    if v ~= nil then TH[theme].align = v end
            end

            section('SIZE', function()
                if theme == 'classic' then last_scale = 1.0 else
                    TH[theme].size = 1.0
                    for k, x in pairs(dims_default(theme, TH[theme].row)) do TH[theme][k] = x end
                end
                low_profile, letter_badge = false, false
            end)
            if theme == 'classic' then
                v = number('Widget size', last_scale, 0.05, '%.2f', 0.3, 4.0);     if v then last_scale = v; refit = true end
            else
                local o = TH[theme]
                v = number('Widget size', o.size, 0.05, '%.2f', 0.4, 3.0); if v then o.size = v end
                v = slider('Overall length', o.name_w + o.gap + o.tag_w, 60, 460, '%.0f')
                if v then o.name_w = clamp(math.floor(v) - o.gap - o.tag_w, 20, 300) end
                v = slider('Name box length', o.name_w, 20, 300, '%.0f');            if v then o.name_w = math.floor(v) end
                v = slider('Name box height', o.name_h, 10, 60, '%.0f');             if v then o.name_h = math.floor(v) end
                v = slider('ON / OFF box length', o.tag_w, 16, 120, '%.0f');         if v then o.tag_w = math.floor(v) end
                v = slider('ON / OFF box height', o.tag_h, 8, 40, '%.0f');           if v then o.tag_h = math.floor(v) end
                v = slider('Gap between name and ON / OFF', o.gap, -10, 40, '%.0f');   if v then o.gap = math.floor(v) end
                note('Names shorten to fit the name box: drag it longer to see full names. Sizes are in pixels at Widget size 1.')
            end
            if theme == 'classic' then   -- (Vex / Hex link: Name style, in their options below)
                v = switch('Low profile (first letter only)', low_profile);             if v ~= nil then low_profile = v; refit = true end
            end
            if low_profile and theme == 'classic' then
                v = switch('Letter inside the shape', letter_badge);                 if v ~= nil then letter_badge = v; refit = true end
            end
            note('Roll the mouse wheel over the widget to resize it.')
            if theme == 'classic' and button_row('Fit the box to its content', 'Fit') then refit = true end

            -- the look's own options
            local o = TH[theme]
            if theme == 'vex' then
                section('VEX OPTIONS', function()
                    local d = TH_DEFAULT.vex
                    o.row, o.ls, o.frame, o.goldlock, o.view, o.bar_w = d.row, d.ls, d.frame, d.goldlock, d.view, d.bar_w
                end)
                v = seg('Row style', { { 'party', 'Party' }, { 'menu', 'Menu' } }, o.row)
                if v ~= nil then
                    o.row = v
                    for k, x in pairs(dims_default('vex', v)) do o[k] = x end
                end
                v = seg('Name style', { { 'full', 'Full name' }, { 'B', 'Letter B' }, { 'A', 'Letter A' }, { 'C', 'Letter C' } }, low_profile and o.ls or 'full')
                if v ~= nil then
                    if v == 'full' then low_profile = false else low_profile = true; o.ls = v end
                    refit = true
                end
                v = switch('Gold name and edge on LOCK', o.goldlock); if v ~= nil then o.goldlock = v end
                v = seg('View', { { 'A', 'A' }, { 'B', 'B' } }, o.view);  if v ~= nil then o.view = v end
                note('View A: the ON / OFF tag, then the name plate. View B: the name plate first (the name over two coloured bars, an empty spot at its right), then the ON / OFF tag.')
                note('Party: rows on their own, like the party list. Menu: rounded Vex cards, their edge pink to violet, a violet divider and rounded tags. Name style: the full name (shortened to fit its box) or one letter in style A, B or C.')
            elseif theme == 'hex' then
                section('HEX LINK OPTIONS', function()
                    local d = TH_DEFAULT.hex
                    o.ls, o.gold, o.cut, o.view = d.ls, d.gold, d.cut, d.view
                end)
                v = seg('Name style', { { 'full', 'Full name' }, { 'B', 'Letter B' }, { 'A', 'Letter A' }, { 'C', 'Letter C' } }, low_profile and o.ls or 'full')
                if v ~= nil then
                    if v == 'full' then low_profile = false else low_profile = true; o.ls = v end
                    refit = true
                end
                v = switch('Gold corner accents', o.gold);            if v ~= nil then o.gold = v end
                v = seg('Corner cut', { { 'small', 'Small' }, { 'medium', 'Medium' }, { 'large', 'Large' } }, o.cut); if v ~= nil then o.cut = v end
                v = seg('View', { { 'A', 'A' }, { 'B', 'B' } }, o.view);  if v ~= nil then o.view = v end
                note('View A: name, gold divider, then the ON / OFF tag. View B: the ON / OFF tag first, then the name over a coloured bar, and an empty box at the right.')
                note('A gold divider and a job-box style tag. Name style: the full name (shortened to fit its box) or one letter in style A, B or C.')
            end

            -- every look: its own box, name text and ON / OFF text (Classic's options)
            local classic = (theme == 'classic')
            local st = classic and S or o.st
            local function fresh() return classic and default_style() or themed_style() end

            section('BACKGROUND', function()
                local d = fresh()
                st.bg, st.border, st.border_w, st.bg_w_add, st.bg_h_add = d.bg, d.border, d.border_w, 0, 0
                st.bg_style, st.menu_frame, st.menu_stripes, st.menu_stripe_a = d.bg_style, d.menu_frame, d.menu_stripes, d.menu_stripe_a
                st.menu_top, st.menu_mid, st.menu_bottom = d.menu_top, d.menu_mid, d.menu_bottom
                ui_alpha = 1.0
                if not classic then
                    local dd = TH_DEFAULT[theme]
                    o.plate, o.plate_a = { dd.plate[1], dd.plate[2], dd.plate[3] }, dd.plate_a
                end
            end)
            if not classic then st.bg_style = 0 end        -- Vex / Hex link: a plain box only (no FFXI menu)
            v = classic and seg('Background', { { 0, 'Solid' }, { 1, 'FFXI menu' } }, st.bg_style) or nil
            if v ~= nil then
                st.bg_style = v
                if v == 1 then
                    local d = default_style()
                    st.menu_top, st.menu_mid, st.menu_bottom = d.menu_top, d.menu_mid, d.menu_bottom
                    st.menu_stripes, st.menu_frame, st.menu_stripe_a = d.menu_stripes, d.menu_frame, d.menu_stripe_a
                end
            end
            v = slider('Content opacity', ui_alpha, 0.2, 1.0, '%.2f');       if v then ui_alpha = v end
            v = slider('Background opacity', st.bg[4], 0.0, 1.0, '%.2f');    if v then st.bg[4] = v end
            colour('Background colour', st.bg)
            colour('Border colour', st.border)
            v = slider('Border width', st.border_w, 0.0, 6.0, '%.1f');       if v then st.border_w = v end
            v = slider('Background width +/-', st.bg_w_add, -100, 400, '%.0f');  if v then st.bg_w_add = math.floor(v) end
            v = slider('Background height +/-', st.bg_h_add, -100, 400, '%.0f'); if v then st.bg_h_add = math.floor(v) end
            if st.bg_style == 1 then
                v = switch('Classic FFXI window frame', st.menu_frame);      if v ~= nil then st.menu_frame = v end
                v = switch('Stripes', st.menu_stripes);                      if v ~= nil then st.menu_stripes = v end
                colour('Menu top colour', st.menu_top)
                colour('Menu middle colour', st.menu_mid)
                colour('Menu bottom colour', st.menu_bottom)
                v = slider('Stripe strength', st.menu_stripe_a, 0.0, 0.8, '%.2f'); if v then st.menu_stripe_a = v end
            end
            if not classic then
                note('This theme starts with no box behind it: raise Background opacity to add one.')
                if shown('Name box colour') then
                    label_row('Name box colour', 200)
                    pcall(imgui.PushItemWidth, 200)
                    local c = { o.plate[1], o.plate[2], o.plate[3] }
                    if imgui.ColorEdit3('##col_namebox', c) then o.plate = { c[1], c[2], c[3] }; changed = true end
                    pcall(imgui.PopItemWidth)
                end
                v = slider('Name box opacity', o.plate_a, 0.0, 1.0, '%.2f');    if v then o.plate_a = v end
            end

            section('NAMES', function()
                st.name = fresh().name
                if classic then S.lock_name_tint = true else
                    local d = TH_DEFAULT[theme].lockname
                    o.lockname = { d[1], d[2], d[3] }
                end
            end)
            text_options('Name', st.name)
            if classic then
                v = switch('Name turns orange while locked', S.lock_name_tint); if v ~= nil then S.lock_name_tint = v end
            else
                local function rgb(label, k)
                    if not shown(label) then return end
                    label_row(label, 200)
                    pcall(imgui.PushItemWidth, 200)
                    local c = { o[k][1], o[k][2], o[k][3] }
                    if imgui.ColorEdit3('##col_' .. label, c) then o[k] = { c[1], c[2], c[3] }; changed = true end
                    pcall(imgui.PopItemWidth)
                end
                rgb('Name colour while locked', 'lockname')
            end

            section('ON / OFF', function()
                local d = fresh()
                st.state, st.badge_text = d.state, d.badge_text
                if classic then
                    S.on_col, S.off_col, S.lock_col, S.badge_circle = d.on_col, d.off_col, d.lock_col, d.badge_circle
                else
                    local dd = TH_DEFAULT[theme]
                    for _, k in ipairs({ 'on', 'off', 'lock' }) do o[k] = { dd[k][1], dd[k][2], dd[k][3] } end
                    o.tagauto = true
                end
            end)
            if classic then
                v = seg('Badge shape', { { false, 'Square' }, { true, 'Circle' } }, S.badge_circle)
                if v ~= nil then S.badge_circle = v; circle_fail = false end
            end
            v = switch('Show ON / OFF / LOCK text', st.badge_text);          if v ~= nil then st.badge_text = v end
            if classic then
                colour('ON colour', S.on_col)
                colour('OFF colour', S.off_col)
                colour('LOCK colour', S.lock_col)
            else
                local function rgb(label, k)
                    if not shown(label) then return end
                    label_row(label, 200)
                    pcall(imgui.PushItemWidth, 200)
                    local c = { o[k][1], o[k][2], o[k][3] }
                    if imgui.ColorEdit3('##col_' .. label, c) then o[k] = { c[1], c[2], c[3] }; changed = true end
                    pcall(imgui.PopItemWidth)
                end
                rgb('ON colour', 'on')
                rgb('OFF colour', 'off')
                rgb('LOCK colour', 'lock')
                v = switch('Automatic tag text colour', o.tagauto);           if v ~= nil then o.tagauto = v end
                note('Automatic: dark text matched to each tag. Off: the ON / OFF text colour below.')
            end
            text_options('ON / OFF text', st.state)
            note('Test lock in the sidebar shows LOCK for 3 seconds.')
        end

        ------------------------------------------------------------------
        -- sidebar
        ------------------------------------------------------------------
        -- the sidebar: its own darker panel, padded, a hairline on its right
        local PADF = ImGuiWindowFlags_AlwaysUseWindowPadding or 0
        imgui.PushStyleColor(ImGuiCol_ChildBg, VC.side)
        local side_w = (v2(imgui.CalcTextSize('Save and load'))) + 76
        pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 12, 12 })
        local side_open = imgui.BeginChild('##sm_side', { side_w, 0 }, false, PADF)
        pcall(imgui.PopStyleVar, 1)
        if side_open then
            local base = imgui.GetCursorPosX()
            -- the search box, framed
            pcall(imgui.PushItemWidth, -1)
            local sx, sy = screen_pos()
            local buf = { CFG.search }
            local ok, res = pcall(imgui.InputTextWithHint, '##sm_search', 'Search', buf, 64)
            if not ok then ok, res = pcall(imgui.InputText, '##sm_search', buf, 64) end
            if ok and res then CFG.search = buf[1] or '' end
            pcall(imgui.PopItemWidth)
            pcall(function()
                local x1, y1 = v2(imgui.GetItemRectMax())
                imgui.GetWindowDrawList():AddRect({ sx, sy }, { x1, y1 }, U(VC.line), 6, 0, 1)
            end)
            imgui.Dummy({ 1, 6 })
            -- a top-level row: a line icon, then a white label (opens a page, or runs an action)
            local function head(icon, label, page)
                local on = page and (CFG.page == page) and not searching
                local ix, iy = screen_pos()
                imgui.SetCursorPosX(base + 22)
                imgui.PushStyleColor(ImGuiCol_Text, on and VC.acc or VC.text)
                local clicked = imgui.Selectable(label .. '##hd_' .. label, on)
                imgui.PopStyleColor(1)
                local _, y0 = v2(imgui.GetItemRectMin())
                local _, y1 = v2(imgui.GetItemRectMax())
                pcall(CFG.icon, imgui.GetWindowDrawList(), icon, ix, (y0 + y1) / 2, 13, U(on and VC.acc or VC.dim))
                if clicked and page then CFG.page = page; CFG.search = '' end
                return clicked
            end
            local function item(page, label)
                local on = (CFG.page == page) and not searching
                imgui.SetCursorPosX(base + 34)
                imgui.PushStyleColor(ImGuiCol_Text, on and VC.acc or VC.dim)
                if imgui.Selectable(label .. '##nav_' .. page, on) then CFG.page = page; CFG.search = '' end
                imgui.PopStyleColor(1)
                pcall(function()                   -- the tree line, lit beside the open page
                    local x0, y0 = v2(imgui.GetItemRectMin())
                    local _, y1 = v2(imgui.GetItemRectMax())
                    local dl = imgui.GetWindowDrawList()
                    dl:AddLine({ x0 - 10, y0 }, { x0 - 10, y1 + 2 }, U(VC.line), 1)
                    if on then dl:AddRectFilled({ x0 - 11, y0 + 2 }, { x0 - 9, y1 - 1 }, U(VC.acc), 0) end
                end)
            end
            head('about', 'About', 'about')
            imgui.Dummy({ 1, 4 })
            head('stop', 'StopMove', 'general')
            item('general', 'General'); item('casting', 'Casting'); item('follow', 'Follow'); item('timing', 'Timing')
            imgui.Dummy({ 1, 4 })
            head('widget', 'Widget', 'widget')
            item('widget', 'Appearance')
            imgui.Dummy({ 1, 12 })
            imgui.TextColored(VC.mute, 'TOOLS')
            imgui.Dummy({ 1, 2 })
            head('files', 'Save and load', 'files')
            if head('test', 'Test lock') then test_lock_until = os.clock() + 3 end
            pcall(function() if imgui.IsItemHovered() then imgui.SetTooltip('Show LOCK on your widget for 3 seconds (display only)') end end)
            if head('reset', 'Reset all') then CFG.ask_reset = true end
        end
        imgui.EndChild()
        imgui.PopStyleColor(1)
        pcall(function()                           -- the hairline between the sidebar and the page
            local x1, y0 = v2(imgui.GetItemRectMax())
            local _, ytop = v2(imgui.GetItemRectMin())
            imgui.GetWindowDrawList():AddLine({ x1, ytop }, { x1, y0 }, U(VC.line), 1)
        end)

        ------------------------------------------------------------------
        -- the page (or, while searching, every matching setting)
        ------------------------------------------------------------------
        imgui.SameLine(0, 0)
        pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 18, 12 })
        local page_open = imgui.BeginChild('##sm_page', { 0, 0 }, false, PADF)
        pcall(imgui.PopStyleVar, 1)
        if page_open then
            if searching then
                imgui.TextColored(VC.gold, 'Search: ' .. CFG.search)
                for _, id in ipairs({ 'general', 'casting', 'follow', 'timing', 'widget' }) do PAGES[id]() end
            else
                (PAGES[CFG.page] or PAGES.general)()
            end
        end
        imgui.EndChild()

        -- Reset all asks first, in its own window
        if CFG.ask_reset then
            CFG.ask_reset = false
            pcall(imgui.OpenPopup, 'Reset all settings?##sm_reset')
        end
        local okp, openp = pcall(imgui.BeginPopupModal, 'Reset all settings?##sm_reset', nil, ImGuiWindowFlags_AlwaysAutoResize or 0)
        if not okp then okp, openp = pcall(imgui.BeginPopup, 'Reset all settings?##sm_reset') end   -- (no modal in this build)
        if okp and openp then
            imgui.TextColored(VC.gold, 'This will revert ALL settings to addon defaults.')
            imgui.Dummy({ 1, 4 })
            imgui.TextColored(VC.dim, 'Themes, looks, casting, follow and timing settings all go back to how')
            imgui.TextColored(VC.dim, 'StopMove starts. Save a configuration first if you may want them back.')
            imgui.Dummy({ 1, 6 })
            imgui.PushStyleColor(ImGuiCol_Button, { 0.55, 0.16, 0.18, 1 })
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.68, 0.20, 0.22, 1 })
            if imgui.Button('Reset all##sm_reset_yes', { 120, 0 }) then
                CFG.reset_all()
                changed = true
                imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(2)
            imgui.SameLine()
            if imgui.Button('Cancel##sm_reset_no', { 120, 0 }) then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        if changed then save_settings() end
    end
    imgui.End()
    if nvar > 0 then imgui.PopStyleVar(nvar) end
    if ncol > 0 then imgui.PopStyleColor(ncol) end
end

----------------------------------------------------------------------
-- Per-frame: failsafe, multi-client sync, on-screen toggle
----------------------------------------------------------------------
-- each frame: held casts, follow coming back, and the lock's failsafes
local function cast_tick()
    track_position()

    if resending and (os.clock() - resend_clock) > 1 then
        resending = false
    end
    if pending then
        local waited = os.clock() - pending.since
        if (os.clock() - last_move) >= WAIT_STILL or waited > WAIT_MAX then
            send_pending()
        end
    end

    if resume_at and os.clock() >= resume_at then
        resume_at = nil
        resume_follow()
    end

    if casting then
        local elapsed = os.clock() - cast_started
        if not cast_confirmed and elapsed > CONFIRM_WITHIN then
            stop_cast('cast never began (request failed?)')
        elseif elapsed > math.max(MAX_LOCK, cast_need) then
            stop_cast('failsafe timeout')
        end
    end
end

ashita.events.register('d3d_present', 'stopmove_present', function()
    cast_tick()

    sync_tick()

    draw_config()

    if not show_ui then
        return
    end

    -- The box is resizable (ImGui draws the small triangle grip in the bottom-right
    -- corner). Content scales with the window width.
    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoNav or 0)     -- never take keyboard input away from the game
    if lock_pos then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize)
    elseif cfg_open[1] or shift_down() or wdrag then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove)    -- moved by widget_drag instead
    end
    -- letter-in-shape: no corner triangle (it would cover the tiny badges).
    -- Size it with the mouse wheel over the box, or Settings > Layout > Widget size.
    if low_profile and letter_badge then
        flags = bit.bor(flags, ImGuiWindowFlags_NoResize)
    end

    load_char()

    -- letter-in-shape: one small badge per character, letter inside, tight spacing
    local compact = low_profile and letter_badge
    PAD = compact and 2 or 6

    ------------------------------------------------------------------
    -- Work out what to show: this client first, then any other client(s)
    ------------------------------------------------------------------
    local function disp(n)
        if not low_profile then return n end
        if n:sub(1, 1) == '(' then return '-' end
        return n:sub(1, 1)
    end
    local entries = {}
    local blink = (math.floor(os.clock() * 4) % 2 == 0)     -- INT blinks
    entries[1] = { name = disp(my_name() or 'You'), full = my_name() or 'You', on = enabled,
                   locked = casting or os.clock() < test_lock_until, id = 'self',
                   int = blink and os.clock() < int_until,
                   active = true, click = function() set_enabled(not enabled) end }
    if other_count == 0 then
        entries[2] = { name = disp('(no 2nd client)'), full = '(no 2nd client)', on = false, locked = false, id = 'none', active = false }
    else
        for _, pname in ipairs(other_names) do
            local info = other_clients[pname]
            if info then
                entries[#entries + 1] = { name = disp(pname), full = pname, on = info.enabled, locked = info.locked,
                                          int = blink and info.int,
                                          id = 'peer_' .. pname, active = true,
                                          click = function() set_remote(pname, not info.enabled) end }
            end
        end
    end

    if theme ~= 'classic' then
        draw_themed(entries, flags)
        return
    end

    ------------------------------------------------------------------
    -- Text metrics at scale 1 (ImGui font, or the GDI font when that is on)
    ------------------------------------------------------------------
    local base_lh = 13
    pcall(function()
        local v = imgui.GetTextLineHeight()
        if v and v > 4 then base_lh = v end
    end)
    local function tw1(label)
        local tw = 0
        pcall(function()
            local a = imgui.CalcTextSize(label)
            if type(a) == 'table' then tw = a[1] else tw = a end
        end)
        if not tw or tw <= 0 then tw = #label * base_lh * 0.55 end
        return tw
    end

    local name_h1, state_h1
    local lbl_w1 = {}
    local labels = { 'ON', 'OFF', 'LOCK', 'INT', '--', 'U', 'M' }
    for _, e in ipairs(entries) do labels[#labels + 1] = e.name end

    local locked_any = (casting and enabled) or os.clock() < test_lock_until
    for _, info in pairs(other_clients) do if info.locked then locked_any = true end end

    for _, e in ipairs(entries) do e.nw1 = tw1(e.name) * S.name.size end
    name_h1  = base_lh * S.name.size
    state_h1 = base_lh * S.state.size
    for _, l in ipairs(labels) do lbl_w1[l] = tw1(l) * S.state.size end

    ------------------------------------------------------------------
    -- Grid layout. Every entry is two cells: a name cell and a status button.
    --   stacked: one row per entry     [name][status]
    --   inline : one long row          [name][status] [name][status] ...
    -- Rotation turns the whole grid by 0/90/180/270 degrees (text stays upright).
    ------------------------------------------------------------------
    local function build_grid(sc)
        local N = #entries
        local R, C
        if layout_mode == 0 then R, C = N, 2 else R, C = 1, 2 * N end
        if compact then
            -- badges (plus the U / M buttons) in a single column or row
            if show_cfg_btn then N = N + 1 end
            if show_move_btn then N = N + 1 end
            if layout_mode == 0 then R, C = N, 1 else R, C = 1, N end
        end

        local nh = name_h1  * sc
        local bh = state_h1 * sc
        local bw = bh * 3.4
        if S.badge_circle and not circle_fail then
            -- a circle just big enough for the widest label
            local lw = math.max(lbl_w1.ON or 0, lbl_w1.OFF or 0, lbl_w1.LOCK or 0)
            local d  = (math.sqrt(lw * lw + state_h1 * state_h1) + 2) * sc
            bw, bh = d, d
        end
        if compact then
            local d = state_h1 * 1.35 * sc
            bw, bh = d, d
        end

        local cells = {}
        if compact then
            local kinds = {}
            for i = 1, #entries do kinds[#kinds + 1] = 'b' end
            if show_cfg_btn then kinds[#kinds + 1] = 'u' end
            if show_move_btn then kinds[#kinds + 1] = 'm' end
            for i, k in ipairs(kinds) do
                local r, c = i - 1, 0
                if layout_mode == 1 then r, c = 0, i - 1 end
                cells[#cells + 1] = { e = i, kind = k, r = r, c = c, w = bw, h = bh }
            end
        end
        for i, e in ipairs(compact and {} or entries) do
            local nr, nc, br, bc
            if layout_mode == 0 then
                nr, nc, br, bc = i - 1, 0, i - 1, 1
            else
                nr, nc, br, bc = 0, 2 * (i - 1), 0, 2 * (i - 1) + 1
            end
            cells[#cells + 1] = { e = i, kind = 'n', r = nr, c = nc, w = e.nw1 * sc, h = nh }
            cells[#cells + 1] = { e = i, kind = 'b', r = br, c = bc, w = bw, h = bh }
        end

        local RR, CC = R, C
        for _, cell in ipairs(cells) do
            local r, c = cell.r, cell.c
            if     rot == 1 then cell.r, cell.c = c, R - 1 - r            -- 90
            elseif rot == 2 then cell.r, cell.c = R - 1 - r, C - 1 - c    -- 180
            elseif rot == 3 then cell.r, cell.c = C - 1 - c, r            -- 270
            end
        end
        if rot == 1 or rot == 3 then RR, CC = C, R end

        local colw, rowh, at, kinds = {}, {}, {}, {}
        for c = 0, CC - 1 do colw[c] = 0; kinds[c] = {} end
        for r = 0, RR - 1 do rowh[r] = 0 end
        for _, cell in ipairs(cells) do
            colw[cell.c] = math.max(colw[cell.c], cell.w)
            rowh[cell.r] = math.max(rowh[cell.r], cell.h)
            at[cell.r .. ',' .. cell.c] = cell
            kinds[cell.c][cell.kind] = true
        end
        local mixed = {}
        for c = 0, CC - 1 do mixed[c] = (kinds[c].n and kinds[c].b) and true or false end

        -- gaps: small between a name and its own status, bigger between entries
        local hg, vg = {}, {}
        local total_w, total_h = 0, 0
        for c = 0, CC - 1 do total_w = total_w + colw[c] end
        for r = 0, RR - 1 do total_h = total_h + rowh[r] end
        for c = 0, CC - 2 do
            local same = false
            for r = 0, RR - 1 do
                local a, b = at[r .. ',' .. c], at[r .. ',' .. (c + 1)]
                if a and b and a.e == b.e then same = true break end
            end
            hg[c] = (same and 4 or (compact and 3 or 14)) * sc
            total_w = total_w + hg[c]
        end
        for r = 0, RR - 2 do
            local same = false
            for c = 0, CC - 1 do
                local a, b = at[r .. ',' .. c], at[(r + 1) .. ',' .. c]
                if a and b and a.e == b.e then same = true break end
            end
            vg[r] = (same and 2 or (compact and 3 or 5)) * sc
            total_h = total_h + vg[r]
        end

        return { cells = cells, colw = colw, rowh = rowh, hg = hg, vg = vg, mixed = mixed,
                 RR = RR, CC = CC, content_w = total_w, content_h = total_h }
    end

    -- size of everything at scale 1 (used to derive the scale from the window width)
    local g1       = build_grid(1.0)
    local btn_lh1  = base_lh * 0.8
    local cfg_w1   = show_cfg_btn and (btn_lh1 * 2.6) or 0
    local mv_w1    = show_move_btn and (tw1('Allow Move') * 0.8 + btn_lh1) or 0
    local row_w1   = cfg_w1 + mv_w1 + ((show_cfg_btn and show_move_btn) and 4 or 0)
    local cfg_h1   = (show_cfg_btn or show_move_btn) and (btn_lh1 + 4) or 0
    if compact then row_w1, cfg_h1 = 0, 0 end      -- the buttons are grid cells instead
    local nat_w    = math.max(g1.content_w, row_w1, 1)
    local nat_h    = g1.content_h + cfg_h1

    -- re-fit the box when the layout / rotation / number of clients changes
    local sig = ('%d|%d|%d|%d'):format(layout_mode, rot, #entries,
        (show_cfg_btn and 1 or 0) + (show_move_btn and 2 or 0) + (compact and 4 or 0))
    if sig ~= last_sig then last_sig = sig; refit = true end
    if refit or compact then
        refit = false
        imgui.SetNextWindowSize({ nat_w * last_scale + 2 * PAD, nat_h * last_scale + 2 * PAD }, ImGuiCond_Always)
    else
        imgui.SetNextWindowSize({ nat_w + 2 * PAD, nat_h + 2 * PAD }, ImGuiCond_FirstUseEver)
    end

    -- We draw the background/border ourselves (draw list), so the window is transparent.
    local own_bg = not bg_fail
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, own_bg and 0 or S.border_w)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { PAD, PAD })
    imgui.PushStyleColor(ImGuiCol_WindowBg, own_bg and { 0, 0, 0, 0 } or S.bg)
    imgui.PushStyleColor(ImGuiCol_Border, S.border)
    imgui.PushStyleColor(ImGuiCol_ResizeGrip,        { 0.85, 0.85, 0.85, 0.60 })
    imgui.PushStyleColor(ImGuiCol_ResizeGripHovered, { 1.00, 1.00, 1.00, 0.90 })
    imgui.PushStyleColor(ImGuiCol_ResizeGripActive,  { 1.00, 1.00, 1.00, 1.00 })
    pcall(function() imgui.SetNextWindowSizeConstraints({ 12, 12 }, { 1400, 900 }) end)
    if char_pos then
        imgui.SetNextWindowPos({ char_pos[1], char_pos[2] }, ImGuiCond_Always)
        char_pos = nil
    else
        imgui.SetNextWindowPos({ 20, 200 }, ImGuiCond_FirstUseEver)
    end

    if imgui.Begin('stopmove_ui', true, flags) then
        local w     = imgui.GetWindowWidth()
        local h     = imgui.GetWindowHeight()
        local scale = math.max(compact and 0.3 or 0.5, math.min(4.0, (w - 2 * PAD) / nat_w))
        last_scale  = scale

        -- window position on screen (GDI objects are placed in screen coordinates)
        local wx, wy = 0, 0
        pcall(function()
            local a, b = imgui.GetWindowPos()
            if type(a) == 'table' then wx, wy = a[1], a[2] else wx, wy = a, b end
        end)

        -- remember where the box is and how big (at most once a second)
        if char_loaded and (os.clock() - last_char_write) > 1.0 then
            local moved = char_saved.x == nil or char_saved.y == nil
                or math.abs(wx - char_saved.x) > 0.5 or math.abs(wy - char_saved.y) > 0.5
                or math.abs(scale - (char_saved.scale or 0)) > 0.01
            if moved then save_char(wx, wy) end
        end

        local function set_scale(mult)
            pcall(function() imgui.SetWindowFontScale(scale * mult) end)
        end

        -- content opacity: scales the alpha of text and button colours
        local function fade(c) return { c[1], c[2], c[3], c[4] * ui_alpha } end

        -- ImGui text with optional outline (8 offset copies) and "bold" (drawn twice)
        local function draw_text(txt, part, x, y, tint)
            if part.shadow and not part.outline then
                local d = math.max(1, math.floor(scale + 0.5))
                imgui.PushStyleColor(ImGuiCol_Text, fade({ 0.02, 0.0, 0.10, 0.85 }))
                imgui.SetCursorPosX(x + d)
                imgui.SetCursorPosY(y + d)
                imgui.Text(txt)
                imgui.PopStyleColor(1)
            end
            if part.outline then
                local d = math.max(1, math.floor(part.outline_w * scale + 0.5))
                imgui.PushStyleColor(ImGuiCol_Text, fade(part.outline_color))
                local offs = { { -d, 0 }, { d, 0 }, { 0, -d }, { 0, d }, { -d, -d }, { d, -d }, { -d, d }, { d, d } }
                for _, o in ipairs(offs) do
                    imgui.SetCursorPosX(x + o[1])
                    imgui.SetCursorPosY(y + o[2])
                    imgui.Text(txt)
                end
                imgui.PopStyleColor(1)
            end
            imgui.PushStyleColor(ImGuiCol_Text, fade(tint or part.color))
            imgui.SetCursorPosX(x)
            imgui.SetCursorPosY(y)
            imgui.Text(txt)
            if part.bold then
                imgui.SetCursorPosX(x + 1)
                imgui.SetCursorPosY(y)
                imgui.Text(txt)
            end
            imgui.PopStyleColor(1)
        end

        local g = build_grid(scale)

        -- stacked layouts spread across the width (name left, status right)
        local extra = 0
        if layout_mode == 0 and g.CC > 1 then
            extra = math.max(0, (w - 2 * PAD) - g.content_w) / (g.CC - 1)
        end

        local colx, rowy = {}, {}
        local x = 0
        for c = 0, g.CC - 1 do
            colx[c] = x
            x = x + g.colw[c] + ((g.hg[c] or 0) + extra)
        end
        local y = 0
        for r = 0, g.RR - 1 do
            rowy[r] = y
            y = y + g.rowh[r] + (g.vg[r] or 0)
        end

        -- background and border (own size, see Settings > Box)
        draw_background(wx, wy, w, h)
        local suppress = widget_drag(wx, wy)

        local function draw_cells()
            for _, cell in ipairs(g.cells) do
                local e  = entries[cell.e]
                local cx = PAD + colx[cell.c]
                local cy = PAD + rowy[cell.r]
                if g.mixed[cell.c] then cx = cx + (g.colw[cell.c] - cell.w) / 2 end   -- centre in shared columns
                cy = cy + (g.rowh[cell.r] - cell.h) / 2

                if cell.kind == 'u' or cell.kind == 'm' then
                    -- tiny U (settings) / M (Allow Move) buttons in letter-in-shape mode
                    local is_m = (cell.kind == 'm')
                    local col = (is_m and locked_any) and S.lock_col or { 0.25, 0.25, 0.32, 1.0 }
                    set_scale(S.state.size)
                    imgui.SetCursorPosX(cx)
                    imgui.SetCursorPosY(cy)
                    imgui.PushStyleColor(ImGuiCol_Button, fade(col))
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, fade({ col[1] + 0.1, col[2] + 0.1, col[3] + 0.1, 1.0 }))
                    imgui.PushStyleColor(ImGuiCol_ButtonActive, fade({ col[1] + 0.2, col[2] + 0.2, col[3] + 0.2, 1.0 }))
                    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 0, 0 })
                    local clicked = imgui.Button('##sm_' .. cell.kind, { cell.w, cell.h })
                    imgui.PopStyleVar(1)
                    imgui.PopStyleColor(3)
                    pcall(function()
                        if imgui.IsItemHovered() then imgui.SetTooltip(is_m and 'Allow Move' or 'StopMove settings') end
                    end)
                    local lbl = is_m and 'M' or 'U'
                    draw_text(lbl, S.state, cx + (cell.w - lbl_w1[lbl] * scale) / 2, cy + (cell.h - state_h1 * scale) / 2)
                    if clicked and not suppress then
                        if is_m then allow_move() else cfg_open[1] = not cfg_open[1] end
                        pcall(function() imgui.SetWindowFocus() end)
                    end
                elseif cell.kind == 'n' then
                    set_scale(S.name.size)
                    draw_text(e.name, S.name, cx, cy, (S.lock_name_tint and e.locked and e.on) and { 0.95, 0.60, 0.15, 1 } or nil)
                else
                    local color, label
                    if not e.active then
                        color, label = { 0.30, 0.30, 0.30, 1.0 }, '--'
                    elseif not e.on then
                        color, label = S.off_col, 'OFF'
                    elseif e.locked then
                        color, label = S.lock_col, 'LOCK'
                    elseif e.int then
                        color, label = INT_COL, 'INT'
                    else
                        color, label = S.on_col, 'ON'
                    end
                    if compact then label = e.name end      -- the letter goes inside the shape
                    local tw = (lbl_w1[label] or tw1(label)) * scale
                    local clicked

                    set_scale(S.state.size)
                    local faded = fade(color)
                    if S.badge_circle and not circle_fail then
                        -- circle: filled with the draw list, plus an invisible button for clicks
                        local drawn = pcall(function()
                            local dl = imgui.GetWindowDrawList()
                            dl:AddCircleFilled({ wx + cx + cell.w / 2, wy + cy + cell.h / 2 },
                                cell.w / 2, imgui.GetColorU32(faded), 32)
                        end)
                        if not drawn then circle_fail = true end
                        imgui.SetCursorPosX(cx)
                        imgui.SetCursorPosY(cy)
                        clicked = imgui.InvisibleButton('##' .. e.id, { cell.w, cell.h })
                    else
                        imgui.SetCursorPosX(cx)
                        imgui.SetCursorPosY(cy)
                        imgui.PushStyleColor(ImGuiCol_Button, faded)
                        imgui.PushStyleColor(ImGuiCol_ButtonHovered, faded)
                        imgui.PushStyleColor(ImGuiCol_ButtonActive, faded)
                        imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 2, 0 })
                        clicked = imgui.Button('##' .. e.id, { cell.w, cell.h })
                        imgui.PopStyleVar(1)
                        imgui.PopStyleColor(3)
                    end
                    -- label centred on the badge (square or circle)
                    if S.badge_text or compact then
                        draw_text(label, S.state, cx + (cell.w - tw) / 2, cy + (cell.h - state_h1 * scale) / 2)
                    end

                    if clicked and not suppress and e.active and e.click then e.click() end
                end
            end
        end

        draw_cells()

        -- small "UI" button that opens the settings window, and "Allow Move"
        -- (ends the cast lock now; drawn in the LOCK colour while locked)
        local end_y = PAD + y
        if (show_cfg_btn or show_move_btn) and not compact then
            set_scale(0.8)
            local lh = base_lh * 0.8 * scale
            local bx = PAD
            local function small_button(label, w, col)
                imgui.SetCursorPosX(bx)
                imgui.SetCursorPosY(PAD + y + 4 * scale)
                imgui.PushStyleColor(ImGuiCol_Button, { col[1], col[2], col[3], 0.85 * ui_alpha })
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, { col[1] + 0.1, col[2] + 0.1, col[3] + 0.1, 0.95 * ui_alpha })
                imgui.PushStyleColor(ImGuiCol_ButtonActive,  { col[1] + 0.2, col[2] + 0.2, col[3] + 0.2, 1.00 * ui_alpha })
                imgui.PushStyleColor(ImGuiCol_Text, fade({ 1, 1, 1, 1 }))
                imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 2, 0 })
                local clicked = imgui.Button(label, { w, lh })
                imgui.PopStyleVar(1)
                imgui.PopStyleColor(4)
                bx = bx + w + 4 * scale
                return clicked
            end
            if show_cfg_btn and small_button('UI##open', lh * 2.6, { 0.25, 0.25, 0.32 }) and not suppress then
                cfg_open[1] = not cfg_open[1]
            end
            if show_move_btn then
                local col = (casting and enabled) and S.lock_col or { 0.25, 0.25, 0.32 }
                col = locked_any and S.lock_col or col
                if small_button('Allow Move##release', mv_w1 * scale, col) and not suppress then
                    allow_move()
                    pcall(function() imgui.SetWindowFocus() end)   -- hand the keyboard back to the game
                end
            end
            end_y = PAD + y + 4 * scale + lh
        end

        -- close out the layout so ImGui knows the extent of the content
        imgui.SetCursorPosX(PAD)
        imgui.SetCursorPosY(end_y)
        imgui.Dummy({ 1, 1 })

        -- mouse wheel over the box = bigger / smaller (not while the box is locked)
        if not lock_pos then
            pcall(function()
                local wheel = imgui.GetIO().MouseWheel
                if wheel ~= 0 and imgui.IsWindowHovered() then
                    last_scale = clamp(last_scale * (1 + 0.1 * wheel), compact and 0.3 or 0.5, 4.0)
                    refit = true
                end
            end)
        end

        -- right-click anywhere on the box to open the settings window
        pcall(function()
            if imgui.IsWindowHovered() and imgui.IsMouseClicked(1) then
                cfg_open[1] = not cfg_open[1]
            end
        end)
    end
    imgui.End()
    imgui.PopStyleColor(5)
    imgui.PopStyleVar(2)

end)

----------------------------------------------------------------------
-- Load / unload
----------------------------------------------------------------------
ashita.events.register('load', 'stopmove_load', function()
    init_sync()
end)

ashita.events.register('unload', 'stopmove_unload', function()
    pending = nil
    pcall(save_char)
    stop_cast('addon unloading')
    -- remove our heartbeat so the other client notices us leaving quickly
    if hb_file then os.remove(hb_file) end
end)
