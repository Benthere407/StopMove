--[[
    stopmove - Ashita v4 addon
    Blocks the numpad movement keys while you are casting a spell, so you can't
    accidentally interrupt the cast by walking. Optionally turns Multisend follow
    off for the length of the cast and back on afterwards.

    Multi-client: if you run a second FFXI client with this addon loaded, the two
    copies detect each other. The on-screen box shows one row per character, and
    each row's ON/OFF button controls that character independently.

    Commands:
        /stopmove            open / close the settings window
        /stopmove on|off     turn stopmove on or off for THIS character
        /stopmove resetbox   put the on-screen box back at normal size, top-left

    NOTE: Keyboard movement only. Gamepad / mouse movement is not blocked.
--]]

addon.name    = 'stopmove'
addon.author  = 'Claude'
addon.version = '1.8'
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
local CONFIRM_WITHIN = 3    -- seconds to see the cast actually begin before assuming the request failed
local inject   = true   -- on cast start, send a key-release for movement keys you are holding
local UNLOCK_DONE = 0.0   -- seconds before follow comes back after a COMPLETED cast
local UNLOCK_INT  = 10.0  -- seconds before follow comes back after an INTERRUPTED cast
local MAX_LOCK = 6      -- hard cap: movement lock / follow-off never lasts longer than this many seconds

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
local show_cfg_btn = true   -- small 'UI' button on the widget
local circle_fail  = false   -- set if drawing a circle failed (falls back to squares)
local bg_fail      = false   -- set if the ImGui draw-list background failed (falls back to a plain window)
local layout_mode  = 0      -- 0 = stacked rows, 1 = inline (name then status, long and skinny)
local rot          = 0      -- box rotation: 0, 1, 2, 3  =  0, 90, 180, 270 degrees
local refit        = true   -- resize the box to fit its content on the next frame
local last_sig     = nil
local last_scale   = 1.0
local PAD          = 6      -- window padding of the on-screen box

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

-- Position pin: the server interrupts a cast if your x/z changes by even ~0.05
-- between cast start and cast end. Small client-side nudges (a held key that
-- slips through for a frame) are enough to do it, so while casting we resend
-- the position the server already has, unless you have genuinely walked away.
local pin_pos     = true
local PIN_MAX     = 1.0     -- drift (yalms) above this is real movement: let it through
local sent_x, sent_y = nil, nil   -- last x / y we sent in a 0x0015 position packet
local anchor      = nil     -- { x, y } position pinned for the current cast

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

local follow_suspended = false
local resume_at          = nil   -- os.clock() time at which follow is turned back on
local cast_confirmed     = false

local function run_command(cmd)
    pcall(function() AshitaCore:GetChatManager():QueueCommand(-1, cmd) end)
end

-- Cast starts: turn Multisend follow off.
local function suspend_follow()
    if follow_suspended or not ms_enabled then return end
    follow_suspended = true
    if ms_off_cmd ~= '' then run_command(ms_off_cmd) end
end

-- Cast over (after any unlock wait): turn Multisend follow back on.
local function resume_follow()
    if not follow_suspended then return end
    follow_suspended = false
    if ms_on_cmd ~= '' then run_command(ms_on_cmd) end
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
        if sent_x then anchor = { sent_x, sent_y } end
        suspend_follow()
        release_held_keys()
    end
end

-- Ends the movement lock. follow_delay (seconds) = how long to wait before the
-- follow commands are turned back on; nil or 0 = right away.
local function stop_cast(reason, follow_delay)
    casting        = false
    cast_confirmed = false
    anchor         = nil
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

-- Settings are saved to config/addons/stopmove/settings.txt
-- (shared by both clients because they use the same Ashita folder)
local function f4(t) return ('%.3f,%.3f,%.3f,%.3f'):format(t[1], t[2], t[3], t[4]) end

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
        ('pin_pos=%d'):format(pin_pos and 1 or 0),
        ('lock_pos=%d'):format(lock_pos and 1 or 0),
        ('cfg_btn=%d'):format(show_cfg_btn and 1 or 0),
        ('low_profile=%d'):format(low_profile and 1 or 0),
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
    lines[#lines + 1] = 'ms_offcmd=>' .. ms_off_cmd      -- leading '>' keeps blank commands
    lines[#lines + 1] = 'ms_oncmd=>'  .. ms_on_cmd
    local blob = table.concat(lines, '\n') .. '\n'
    write_file(sync_dir .. 'settings.txt', blob)
    last_blob = blob
end

local function apply_settings(data)
    for k, v in data:gmatch('([%w_]+)=([^\r\n]+)') do
        local n = {}
        if k == 'ms_offcmd' then
            ms_off_cmd = (v:gsub('^>', ''))
            goto continue
        elseif k == 'ms_oncmd' then
            ms_on_cmd = (v:gsub('^>', ''))
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
            elseif k == 'inject'      then inject        = (x ~= 0)
            elseif k == 'pin_pos'     then pin_pos       = (x ~= 0)
            elseif k == 'lock_pos'    then lock_pos      = (x ~= 0)
            elseif k == 'cfg_btn'     then show_cfg_btn  = (x ~= 0)
            elseif k == 'low_profile' then low_profile   = (x ~= 0); refit = true
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

local function write_heartbeat()
    local me = my_name()
    if not me or not sync_dir then return end
    hb_file = sync_dir .. 'client_' .. me .. '.txt'
    pub_locked = (casting and enabled) and 1 or 0
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
    local data = read_file(path)
    if not data then return end
    local t = {}
    for k, v in data:gmatch('(%w+)=([%-%d%.]+)') do t[k] = tonumber(v) end
    if t.x and t.y then char_pos = { t.x, t.y } end
    if t.scale then last_scale = clamp(t.scale, 0.5, 4.0); refit = true end
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
    write_file(sync_dir .. 'cmd_' .. name .. '.txt',
        ('%d|%d.%d|%s'):format(value and 1 or 0, os.time(), cmd_counter, my_name() or '?'))
    if other_clients[name] then other_clients[name].enabled = value end  -- optimistic UI
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
                    found[who] = { enabled = (st == '1'), locked = (lk == '1') }
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
    local now_lock = (casting and enabled) and 1 or 0
    if now_lock ~= pub_locked then write_heartbeat() end

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
            pcall(apply_settings, blob)
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
        local data = read_file(sync_dir .. 'cmd_' .. me .. '.txt')
        if data then
            if not cmd_primed then
                last_cmd   = data       -- stale file from an earlier session: ignore it
                cmd_primed = true
            elseif data ~= last_cmd then
                last_cmd = data
                local st = data:match('^(%d)|')
                if st then
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
    elseif sub == 'resetbox' then
        last_scale = 1.0
        char_pos   = { 20, 200 }
        refit      = true
        save_char(20, 200)
    end
end)

----------------------------------------------------------------------
-- Detect casting from incoming action packets (0x0028)
--   category 8 + param 24931 = you began casting
--   category 8 + other param  = cast interrupted
--   category 4                = spell finished
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
        stop_cast('finished', UNLOCK_DONE)
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
    -- 0x0015 position update: x at 0x04, height at 0x08, y at 0x0C
    if e.id == 0x0015 then
        local p = ffi.cast('float*', ffi.cast('uint8_t*', e.data_modified_raw) + 4)
        if casting and anchor and enabled and pin_pos then
            local dx, dy = p[0] - anchor[1], p[2] - anchor[2]
            if (dx * dx + dy * dy) <= PIN_MAX * PIN_MAX then
                p[0], p[2] = anchor[1], anchor[2]
            else
                anchor = nil       -- you really walked off; stop pinning
            end
        end
        sent_x, sent_y = p[0], p[2]
        return
    end

    if e.id ~= 0x001A then
        return
    end
    if not enabled then
        return
    end
    local cat_lo = ashita.bits.unpack_be(e.data_raw, 10, 0, 8)
    local cat_hi = ashita.bits.unpack_be(e.data_raw, 11, 0, 8)
    if cat_lo == 3 and cat_hi == 0 then
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

----------------------------------------------------------------------
-- Settings window (/stopmove config, or right-click the on-screen box)
----------------------------------------------------------------------
local function draw_config()
    if not cfg_open[1] then return end

    -- same resize triangle as the toggle box
    imgui.PushStyleColor(ImGuiCol_ResizeGrip,        { 0.85, 0.85, 0.85, 0.60 })
    imgui.PushStyleColor(ImGuiCol_ResizeGripHovered, { 1.00, 1.00, 1.00, 0.90 })
    imgui.PushStyleColor(ImGuiCol_ResizeGripActive,  { 1.00, 1.00, 1.00, 1.00 })
    imgui.SetNextWindowSize({ 380, 520 }, ImGuiCond_FirstUseEver)
    pcall(function() imgui.SetNextWindowSizeConstraints({ 300, 200 }, { 800, 1000 }) end)

    if imgui.Begin('StopMove Settings', cfg_open, 0) then
        local changed = false

        -- colour picker that edits a { r, g, b, a } table in place
        -- slider with a number box beside it, so a value can be typed instead of dragged
        local function slider(label, a, lo, hi, fmt)
            local ch = false
            local box = { a[1] }
            pcall(imgui.PushItemWidth, 70)
            if imgui.InputFloat('##in_' .. label, box, 0, 0, fmt) then
                a[1] = math.max(lo, math.min(hi, box[1])); ch = true
            end
            pcall(imgui.PopItemWidth)
            imgui.SameLine()
            if imgui.SliderFloat(label, a, lo, hi, fmt) then ch = true end
            return ch
        end

        local function color_edit(label, t)
            local c = { t[1], t[2], t[3], t[4] }
            if imgui.ColorEdit4(label, c) then
                t[1], t[2], t[3], t[4] = c[1], c[2], c[3], c[4]
                changed = true
            end
        end

        -- name / ON-OFF text options
        local function text_options(id, p)
            color_edit('Text colour##' .. id, p.color)
            local b = { p.bold }
            if imgui.Checkbox('Bold##' .. id, b) then p.bold = b[1]; changed = true; refit = true end
            local z = { p.size }
            if slider('Size##' .. id, z, 0.1, 2.5, '%.2f') then
                p.size = clamp(z[1], 0.1, 2.5); changed = true; refit = true
            end
            local sh = { p.shadow }
            if imgui.Checkbox('Drop shadow##' .. id, sh) then p.shadow = sh[1]; changed = true end
            local ol = { p.outline }
            if imgui.Checkbox('Outline##' .. id, ol) then p.outline = ol[1]; changed = true end
            if p.outline then
                color_edit('Outline colour##' .. id, p.outline_color)
                local ow = { p.outline_w }
                if slider('Outline width##' .. id, ow, 0.5, 4.0, '%.1f') then
                    p.outline_w = clamp(ow[1], 0.5, 4); changed = true
                end
            end
        end

        -- text input box (wrapped in case this build's InputText differs)
        local function text_box(label, value)
            local buf = { value }
            local ok, res = pcall(imgui.InputText, label, buf, 128)
            if ok and res then return buf[1] end
            return nil
        end

        ------------------------------------------------------------------
        if imgui.CollapsingHeader('General', ImGuiTreeNodeFlags_DefaultOpen) then
            local en = { enabled }
            if imgui.Checkbox('Enabled for this character', en) then set_enabled(en[1]) end
            local c1 = { show_ui }
            if imgui.Checkbox('Turn On/Off Widget', c1) then show_ui = c1[1]; changed = true end
            local c2 = { lock_pos }
            if imgui.Checkbox('Lock box position and size', c2) then lock_pos = c2[1]; changed = true end
            local lp = { low_profile }
            if imgui.Checkbox('Low profile widget', lp) then low_profile = lp[1]; refit = true; changed = true end
            imgui.SameLine()
            imgui.TextDisabled('first letter of each name + ON/OFF only')
            local c4 = { show_cfg_btn }
            if imgui.Checkbox('UI button', c4) then show_cfg_btn = c4[1]; changed = true end
            imgui.SameLine()
            imgui.TextDisabled('puts a UI button on the widget')
            if imgui.Button('Release now') then stop_cast('manual release') end
            imgui.SameLine()
            imgui.TextDisabled('releases the stop-cast lock and allows movement when pushed')
        end

        if imgui.CollapsingHeader('Casting actions (each can be on or off)', ImGuiTreeNodeFlags_DefaultOpen) then
            local k1 = { block_keys }
            if imgui.Checkbox('Disable keyboard movement (numpad 8/2/4/6)', k1) then
                block_keys = k1[1]; changed = true
            end
            local kw = { block_wasd }
            if imgui.Checkbox('Also disable WASD keys', kw) then
                block_wasd = kw[1]; changed = true
            end
            imgui.TextDisabled('  While casting, W/A/S/D are blocked too (so you cannot type those letters in chat mid-cast).')
            local k2 = { inject }
            if imgui.Checkbox('Release held movement keys at cast start', k2) then
                inject = k2[1]; changed = true
            end
            local k3 = { pin_pos }
            if imgui.Checkbox('Hold position while casting', k3) then
                pin_pos = k3[1]; changed = true
            end
            imgui.TextDisabled('  Tiny slips (under 1 yalm) are not sent to the server, so they cannot interrupt the cast.')
            imgui.Separator()

            local m = { ms_enabled }
            if imgui.Checkbox('Multisend follow', m) then
                ms_enabled = m[1]
                if not ms_enabled and follow_suspended then resume_follow() end
                changed = true
            end
            if ms_enabled then
                local off = text_box('Cast starts##ms_off', ms_off_cmd)
                if off ~= nil then ms_off_cmd = off; changed = true end
                local on = text_box('Cast ends##ms_on', ms_on_cmd)
                if on ~= nil then ms_on_cmd = on; changed = true end
                imgui.TextDisabled('  Blank command = send nothing. Commands start with / (e.g. /ms follow off).')
            end
        end

        if imgui.CollapsingHeader('Timing', ImGuiTreeNodeFlags_DefaultOpen) then
            local w = { wait_for_stop }
            if imgui.Checkbox('Wait until stopped before casting', w) then
                wait_for_stop = w[1]; pending = nil; changed = true
            end

            local v1 = { WAIT_STILL }
            if imgui.InputFloat('Spell cast delay (s)', v1, 0.05, 0.1, '%.2f') then
                WAIT_STILL = clamp(v1[1], 0.05, 1.0); changed = true
            end
            imgui.TextDisabled('  Spell cast delay: how long you must stand still before the cast is sent.')

            local v2 = { WAIT_MAX }
            if imgui.InputFloat('Max hold (s)', v2, 0.1, 0.5, '%.1f') then
                WAIT_MAX = clamp(v2[1], 0.1, 5.0); changed = true
            end
            imgui.TextDisabled('  Longest a cast is held; it is sent anyway after this.')

            local v3 = { MAX_LOCK }
            if imgui.InputFloat('Max cast lock (s)', v3, 0.5, 1.0, '%.1f') then
                MAX_LOCK = clamp(v3[1], 1, 30); changed = true
            end
            imgui.TextDisabled('  Hard cap: lock and follow-off never last longer than this after a cast begins.')

            local v4 = { UNLOCK_DONE }
            if imgui.InputFloat('Unlock wait: cast completed (s)', v4, 0.5, 1.0, '%.1f') then
                UNLOCK_DONE = clamp(v4[1], 0, 60); changed = true
            end
            local v5 = { UNLOCK_INT }
            if imgui.InputFloat('Unlock wait: cast interrupted (s)', v5, 0.5, 1.0, '%.1f') then
                UNLOCK_INT = clamp(v5[1], 0, 60); changed = true
            end
            imgui.TextDisabled('  Unlock wait: delay before follow turns back on. Keys unlock right away.')
        end

        if imgui.CollapsingHeader('Layout', ImGuiTreeNodeFlags_DefaultOpen) then
            -- little button-style selector; the active choice is highlighted
            local function choice(label, active, apply)
                local col = active and { 0.20, 0.45, 0.80, 1.0 } or { 0.25, 0.25, 0.30, 1.0 }
                imgui.PushStyleColor(ImGuiCol_Button, col)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, { col[1] + 0.1, col[2] + 0.1, col[3] + 0.1, 1.0 })
                imgui.PushStyleColor(ImGuiCol_ButtonActive, { col[1] + 0.2, col[2] + 0.2, col[3] + 0.2, 1.0 })
                if imgui.Button(label) then apply(); refit = true; changed = true end
                imgui.PopStyleColor(3)
            end

            imgui.Text('Arrangement')
            choice('Stacked (one row each)##lay0', layout_mode == 0, function() layout_mode = 0 end)
            imgui.SameLine()
            choice('Inline (long and skinny)##lay1', layout_mode == 1, function() layout_mode = 1 end)

            imgui.Text('Rotation')
            choice('0##rot0',     rot == 0, function() rot = 0 end)
            imgui.SameLine()
            choice('90##rot1',    rot == 1, function() rot = 1 end)
            imgui.SameLine()
            choice('180##rot2',   rot == 2, function() rot = 2 end)
            imgui.SameLine()
            choice('270##rot3',   rot == 3, function() rot = 3 end)
            imgui.TextDisabled('  Rotation rearranges the box; the text itself stays upright.')

            if imgui.Button('Fit box to content') then refit = true end
        end

        if imgui.CollapsingHeader('Box', ImGuiTreeNodeFlags_DefaultOpen) then
            local ba = { S.bg[4] }
            if slider('Background opacity', ba, 0.0, 1.0, '%.2f') then
                S.bg[4] = clamp(ba[1], 0, 1); changed = true
            end
            local ca = { ui_alpha }
            if slider('Content opacity', ca, 0.2, 1.0, '%.2f') then
                ui_alpha = clamp(ca[1], 0.2, 1.0); changed = true
            end
            imgui.TextDisabled('  Content = the names, ON/OFF text and buttons.')
            -- background colour (opacity has its own slider above)
            do
                local c = { S.bg[1], S.bg[2], S.bg[3] }
                if imgui.ColorEdit3('Background colour##bg', c) then
                    S.bg[1], S.bg[2], S.bg[3] = c[1], c[2], c[3]; changed = true
                end
            end
            color_edit('Border colour##bd', S.border)
            local bw = { S.border_w }
            if slider('Border width', bw, 0.0, 6.0, '%.1f') then
                S.border_w = clamp(bw[1], 0, 6); changed = true
            end

            imgui.Separator()
            imgui.Text('Background style')
            local function style_pick(label, active, apply)
                local col = active and { 0.20, 0.45, 0.80, 1.0 } or { 0.25, 0.25, 0.30, 1.0 }
                imgui.PushStyleColor(ImGuiCol_Button, col)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, { col[1] + 0.1, col[2] + 0.1, col[3] + 0.1, 1.0 })
                imgui.PushStyleColor(ImGuiCol_ButtonActive, { col[1] + 0.2, col[2] + 0.2, col[3] + 0.2, 1.0 })
                if imgui.Button(label) then apply(); changed = true end
                imgui.PopStyleColor(3)
            end
            style_pick('Solid colour##bs0', S.bg_style == 0, function() S.bg_style = 0 end)
            imgui.SameLine()
            style_pick('FFXI menu (striped blue)##bs1', S.bg_style == 1, function() S.bg_style = 1; reset_menu_colors() end)
            if S.bg_style == 1 then
                color_edit('Menu top colour##mt', S.menu_top)
                color_edit('Menu middle colour##mm', S.menu_mid)
                color_edit('Menu bottom colour##mb', S.menu_bottom)
                if imgui.Button('Reset menu colours to default##rmc') then reset_menu_colors(); changed = true end
                local fr = { S.menu_frame }
                if imgui.Checkbox('Classic FFXI window frame', fr) then S.menu_frame = fr[1]; changed = true end
                local lt = { S.lock_name_tint }
                if imgui.Checkbox('Name turns orange while locked', lt) then S.lock_name_tint = lt[1]; changed = true end
                local st = { S.menu_stripes }
                if imgui.Checkbox('Stripes', st) then S.menu_stripes = st[1]; changed = true end
                local sa = { S.menu_stripe_a }
                if slider('Stripe strength', sa, 0.0, 0.8, '%.2f') then
                    S.menu_stripe_a = clamp(sa[1], 0, 1); changed = true
                end
            end

            imgui.Separator()
            imgui.Text('Background size (relative to the box)')
            local aw = { S.bg_w_add }
            if slider('Width +/- (px)', aw, -100, 400, '%.0f') then
                S.bg_w_add = math.floor(clamp(aw[1], -300, 800)); changed = true
            end
            local ah = { S.bg_h_add }
            if slider('Height +/- (px)', ah, -100, 400, '%.0f') then
                S.bg_h_add = math.floor(clamp(ah[1], -300, 800)); changed = true
            end
            if imgui.Button('Match background to box') then S.bg_w_add = 0; S.bg_h_add = 0; changed = true end
        end

        if imgui.CollapsingHeader('Character name text', ImGuiTreeNodeFlags_DefaultOpen) then
            text_options('name', S.name)
        end

        if imgui.CollapsingHeader('ON / OFF text', ImGuiTreeNodeFlags_DefaultOpen) then
            imgui.Text('ON / OFF shape')
            local function shape_pick(label, active, apply)
                local col = active and { 0.20, 0.45, 0.80, 1.0 } or { 0.25, 0.25, 0.30, 1.0 }
                imgui.PushStyleColor(ImGuiCol_Button, col)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, { col[1] + 0.1, col[2] + 0.1, col[3] + 0.1, 1.0 })
                imgui.PushStyleColor(ImGuiCol_ButtonActive, { col[1] + 0.2, col[2] + 0.2, col[3] + 0.2, 1.0 })
                if imgui.Button(label) then apply(); refit = true; changed = true end
                imgui.PopStyleColor(3)
            end
            shape_pick('Square##shp0', not S.badge_circle, function() S.badge_circle = false end)
            imgui.SameLine()
            shape_pick('Circle##shp1', S.badge_circle, function() S.badge_circle = true; circle_fail = false end)
            local bt = { S.badge_text }
            if imgui.Checkbox('Show ON / OFF / LOCK text in the badge', bt) then S.badge_text = bt[1]; changed = true end
            imgui.TextDisabled('  Off = colour only: green ON, red OFF, orange LOCK.')
            text_options('state', S.state)
            color_edit('ON button##on',    S.on_col)
            color_edit('OFF button##off',  S.off_col)
            color_edit('LOCK button##lk',  S.lock_col)
        end

        imgui.Separator()
        if imgui.Button('Reset appearance to defaults') then
            S = default_style()
            ui_alpha = 1.0
            changed = true
        end

        if changed then save_settings() end
    end
    imgui.End()
    imgui.PopStyleColor(3)
end

----------------------------------------------------------------------
-- Per-frame: failsafe, multi-client sync, on-screen toggle
----------------------------------------------------------------------
ashita.events.register('d3d_present', 'stopmove_present', function()
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
        elseif elapsed > MAX_LOCK then
            stop_cast('failsafe timeout')
        end
    end

    sync_tick()

    draw_config()

    if not show_ui then
        return
    end

    -- The box is resizable (ImGui draws the small triangle grip in the bottom-right
    -- corner). Content scales with the window width.
    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoScrollbar)
    if lock_pos then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize)
    end

    load_char()

    ------------------------------------------------------------------
    -- Work out what to show: this client first, then any other client(s)
    ------------------------------------------------------------------
    local function disp(n)
        if not low_profile then return n end
        if n:sub(1, 1) == '(' then return '-' end
        return n:sub(1, 1)
    end
    local entries = {}
    entries[1] = { name = disp(my_name() or 'You'), on = enabled, locked = casting, id = 'self',
                   active = true, click = function() set_enabled(not enabled) end }
    if other_count == 0 then
        entries[2] = { name = disp('(no 2nd client)'), on = false, locked = false, id = 'none', active = false }
    else
        for _, pname in ipairs(other_names) do
            local info = other_clients[pname]
            if info then
                entries[#entries + 1] = { name = disp(pname), on = info.enabled, locked = info.locked,
                                          id = 'peer_' .. pname, active = true,
                                          click = function() set_remote(pname, not info.enabled) end }
            end
        end
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
    local labels = { 'ON', 'OFF', 'LOCK', '--' }

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

        local nh = name_h1  * sc
        local bh = state_h1 * sc
        local bw = bh * 3.4
        if S.badge_circle and not circle_fail then
            -- a circle just big enough for the widest label
            local lw = math.max(lbl_w1.ON or 0, lbl_w1.OFF or 0, lbl_w1.LOCK or 0)
            local d  = (math.sqrt(lw * lw + state_h1 * state_h1) + 2) * sc
            bw, bh = d, d
        end

        local cells = {}
        for i, e in ipairs(entries) do
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
            hg[c] = (same and 4 or 14) * sc
            total_w = total_w + hg[c]
        end
        for r = 0, RR - 2 do
            local same = false
            for c = 0, CC - 1 do
                local a, b = at[r .. ',' .. c], at[(r + 1) .. ',' .. c]
                if a and b and a.e == b.e then same = true break end
            end
            vg[r] = (same and 2 or 5) * sc
            total_h = total_h + vg[r]
        end

        return { cells = cells, colw = colw, rowh = rowh, hg = hg, vg = vg, mixed = mixed,
                 RR = RR, CC = CC, content_w = total_w, content_h = total_h }
    end

    -- size of everything at scale 1 (used to derive the scale from the window width)
    local g1       = build_grid(1.0)
    local cfg_w1   = show_cfg_btn and (base_lh * 0.8 * 2.6) or 0
    local cfg_h1   = show_cfg_btn and (base_lh * 0.8 + 4) or 0
    local nat_w    = math.max(g1.content_w, cfg_w1, 1)
    local nat_h    = g1.content_h + cfg_h1

    -- re-fit the box when the layout / rotation / number of clients changes
    local sig = ('%d|%d|%d'):format(layout_mode, rot, #entries)
    if sig ~= last_sig then last_sig = sig; refit = true end
    if refit then
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
    pcall(function() imgui.SetNextWindowSizeConstraints({ 50, 24 }, { 1400, 900 }) end)
    if char_pos then
        imgui.SetNextWindowPos({ char_pos[1], char_pos[2] }, ImGuiCond_Always)
        char_pos = nil
    else
        imgui.SetNextWindowPos({ 20, 200 }, ImGuiCond_FirstUseEver)
    end

    if imgui.Begin('stopmove_ui', true, flags) then
        local w     = imgui.GetWindowWidth()
        local h     = imgui.GetWindowHeight()
        local scale = math.max(0.5, math.min(4.0, (w - 2 * PAD) / nat_w))
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

        local function draw_cells()
            for _, cell in ipairs(g.cells) do
                local e  = entries[cell.e]
                local cx = PAD + colx[cell.c]
                local cy = PAD + rowy[cell.r]
                if g.mixed[cell.c] then cx = cx + (g.colw[cell.c] - cell.w) / 2 end   -- centre in shared columns
                cy = cy + (g.rowh[cell.r] - cell.h) / 2

                if cell.kind == 'n' then
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
                    else
                        color, label = S.on_col, 'ON'
                    end
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
                    if S.badge_text then
                        draw_text(label, S.state, cx + (cell.w - tw) / 2, cy + (cell.h - state_h1 * scale) / 2)
                    end

                    if clicked and e.active and e.click then e.click() end
                end
            end
        end

        draw_cells()

        -- small "UI" button that opens the settings window
        local end_y = PAD + y
        if show_cfg_btn then
            set_scale(0.8)
            local lh = base_lh * 0.8 * scale
            imgui.SetCursorPosX(PAD)
            imgui.SetCursorPosY(PAD + y + 4 * scale)
            imgui.PushStyleColor(ImGuiCol_Button, { 0.25, 0.25, 0.32, 0.85 * ui_alpha })
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.35, 0.35, 0.45, 0.95 * ui_alpha })
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.45, 0.45, 0.55, 1.00 * ui_alpha })
            imgui.PushStyleColor(ImGuiCol_Text, fade({ 1, 1, 1, 1 }))
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 2, 0 })
            if imgui.Button('UI##open', { lh * 2.6, lh }) then cfg_open[1] = not cfg_open[1] end
            imgui.PopStyleVar(1)
            imgui.PopStyleColor(4)
            end_y = PAD + y + 4 * scale + lh
        end

        -- close out the layout so ImGui knows the extent of the content
        imgui.SetCursorPosX(PAD)
        imgui.SetCursorPosY(end_y)
        imgui.Dummy({ 1, 1 })

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
