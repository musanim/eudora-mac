-- night-mode.lua — Hammerspoon
--
-- One click darkens the desk and puts Eudora where it can be read from bed.
-- The space bar on the MacBook's own keyboard puts everything back.
--
-- Night mode deliberately changes *nothing* about the display configuration:
-- all four displays stay connected and live, so macOS never reconfigures and
-- the Screens session from the iPad keeps working. It shows the whole
-- four-display desktop; Stephen works in the built-in display's area of it.
--
-- That constraint is the lesson of a long detour. Powering the externals off
-- puts them in a connected-but-not-scanning-out state that Screens cannot cope
-- with — it stalls on "Reconnecting…" forever — and the three monitors don't
-- even agree on what powering off means: the U4320Q disconnects, the 3008WFP
-- disconnects and then re-announces itself, and the 3007WFPHC never leaves the
-- display list at all. Unplugging works but is a nightly chore. Dimming and
-- covering leave everything exactly as macOS already has it.
--
-- What each display gets, being what it can actually do:
--   Built-in       — real backlight control, taken to 0. The iPad still sees it
--                    perfectly: Screens captures the framebuffer, not the
--                    backlight. This is the display worked in from bed.
--   Every external — an opaque black cover, plus DDC luminance and contrast to
--                    zero underneath where the monitor answers DDC (the U4320Q
--                    and the 3008WFP do; the DELL3007WFPHC answers nothing).
--
-- Standby would be better — the backlight would actually go off — but it is out
-- of reach: DDC has a power-mode command, m1ddc does not implement it, ddcctl
-- is Intel-only, and BetterDisplay, which does, is uninstalled for cause.
--
-- The covers are ordinary windows, so Screens sees them too: from the iPad the
-- three externals are black rectangles. That is the trade, and it is why Eudora
-- is moved to the built-in.
--
-- Getting back out is the part that has to be bulletproof, because a failure
-- means a desk that cannot be seen. Four independent ways:
--   1. Any input from a device in the office — either keyboard, the numeric
--      keypad, the trackpad, the mouse. Touching any of them means wanting the
--      computer normally again; nothing else would touch them. Only *hardware*
--      events count: Screens injects keystrokes and pointer moves as though
--      they were made here, and those must not end night mode in the middle of
--      answering a message. The discriminator is the event's source — hardware
--      reports process 0 and the HID system state, injected events do not.
--   2. ctrl-alt-cmd-D, as a backup.
--   3. The menu-bar item, which is still clickable: the covers carry no mouse
--      callback, and the built-in at brightness 0 is faintly readable.
--   4. Failing all of that, night mode ends by itself at RESTORE_AT.
--
-- Hence GRACE: the moon is clicked with the mouse, and the hand coming off it
-- is itself local input. Night mode ignores the office for that long first,
-- which is also about how long it takes to leave the room.
-- Every DDC call is asynchronous, because hs.execute blocks Hammerspoon's main
-- thread and a monitor that doesn't answer would wedge routes 1, 2 and 3 at
-- once. That is the suspected cause of the night the hotkey did nothing.
--
-- Install:
--   cp scripts/night-mode.lua ~/.hammerspoon/
--   echo 'require("night-mode")' >> ~/.hammerspoon/init.lua
-- To reload from the console without restarting Hammerspoon:
--   package.loaded["night-mode"] = nil; require("night-mode")

if _G.nightMode then
  -- The canvases first: a re-require leaves the Lua state intact, so the old
  -- chunk's covers would otherwise stay on screen with nothing able to remove
  -- them.
  for _, c in ipairs(_G.nightMode.covers or {}) do pcall(function() c:delete() end) end
  for _, k in ipairs({ "ticker", "watchdog", "morning", "tap", "hotkey", "menu", "screenWatcher" }) do
    local t = _G.nightMode[k]
    -- hs.menubar and hs.hotkey have delete(); timers, taps and watchers have
    -- stop(). An already-deleted hotkey has neither, hence the pcall.
    if t then pcall(function() if t.delete then t:delete() else t:stop() end end) end
  end
  _G.nightMode = nil
end

local M = {}

local BUILTIN      = "Built-in Retina Display"
local M1DDC        = "/opt/homebrew/bin/m1ddc"
local APP_NAME     = "Eudora"        -- the binary is Eudora, not EudoraApp
local WINDOW_TITLE = "Eudora"        -- ContentView's .navigationTitle
local AUXILIARY    = { ["Find Messages"] = true, ["Blacklist"] = true, ["Settings"] = true }

local INSET        = 8      -- points of margin, so the parked window has grabbable edges
local SWEEP        = 5.0    -- seconds between sweeps for newly opened windows
local DDC_TIMEOUT  = 5      -- seconds before a DDC call is abandoned
local NIGHT_LEVEL  = 0      -- built-in brightness at night: fully off
local PANIC_LEVEL  = 0.6    -- built-in brightness when there is nothing to restore
local PANIC_FRAC   = 0.75   -- fraction of max luminance/contrast, likewise
local RESTORE_AT   = "07:00"  -- night mode ends by itself, whatever else failed
local GRACE        = 45     -- seconds of ignoring the office's input devices
                            -- after night mode starts — time to let go of the
                            -- mouse and walk out

local EXIT_MODS, EXIT_KEY = { "cmd", "alt", "ctrl" }, "D"   -- D for Day

-- Persisted, so a Hammerspoon reload in the middle of the night doesn't strand
-- the displays dark with no record of what to restore them to.
local kState = "nightMode_state"

local function log(...) print("[night-mode]", ...) end

local function state()  return hs.settings.get(kState) end
local function active() local s = state() return type(s) == "table" and s.active == true end
local function save(s)  hs.settings.set(kState, s) end

-- The same answer as active(), held in memory. The event tap must not call
-- active(): hs.settings.get is an IPC round-trip to cfprefsd, and doing one per
-- mouse-move event makes the callback slow enough that macOS switches the tap
-- off — silently, and within moments of night mode starting. That is why
-- nothing at the desk would restore it.
local isNight = false

--------------------------------------------------------------------------------
-- DDC, asynchronously
--------------------------------------------------------------------------------

-- m1ddc addresses displays by system UUID by default, which is exactly what
-- hs.screen:getUUID() returns — so no index juggling, and an absent display
-- fails rather than being mistaken for another one.
--
-- perl's alarm supplies the timeout, macOS having no timeout(1). `exec @ARGV`
-- with a list execs directly, without a nested shell.
local function ddcAsync(uuid, args, fn)
  if not uuid then return fn(nil) end
  local argv = { "-e", "alarm shift; exec @ARGV", tostring(DDC_TIMEOUT), M1DDC, "display", uuid }
  for _, a in ipairs(args) do argv[#argv + 1] = a end

  local task = hs.task.new("/usr/bin/perl", function(_, stdout, _)
    fn((tostring(stdout or ""):gsub("%s+$", "")))
  end, argv)
  if task then task:start() else fn(nil) end
end

-- nil is a perfectly good answer: it means this display doesn't speak DDC.
local function ddcRead(uuid, what, fn)
  ddcAsync(uuid, { "get", what }, function(out) fn(tonumber(out)) end)
end

-- Runs a list of functions, each taking a continuation, strictly in order.
-- Nesting DDC callbacks by hand gets unreadable at three levels.
local function series(jobs, done)
  local i = 0
  local function step()
    i = i + 1
    if jobs[i] then jobs[i](step) else done() end
  end
  step()
end

--------------------------------------------------------------------------------
-- Screens
--------------------------------------------------------------------------------

local function screenNamed(name)
  for _, s in ipairs(hs.screen.allScreens()) do
    if s:name() == name then return s end
  end
  return nil
end

local function screenWithUUID(uuid)
  if not uuid then return nil end
  for _, s in ipairs(hs.screen.allScreens()) do
    if s:getUUID() == uuid then return s end
  end
  return nil
end

local function sameScreen(a, b) return (a and b and a:id() == b:id()) == true end

-- Identifying the built-in wrongly is the one unrecoverable mistake — it is the
-- display that stays visible — so this tries the name, then the saved UUID,
-- then a laptop-looking name that answers a brightness query, and only then any
-- display that answers at all. On Apple Silicon some externals answer too.
local function builtinScreen(savedUUID)
  local s = screenNamed(BUILTIN) or screenWithUUID(savedUUID)
  if s then return s end
  for _, scr in ipairs(hs.screen.allScreens()) do
    local n = scr:name() or ""
    if (n:find("Built%-in") or n:find("Liquid Retina") or n:find("Color LCD"))
       and scr:getBrightness() ~= nil then return scr end
  end
  for _, scr in ipairs(hs.screen.allScreens()) do
    if scr:getBrightness() ~= nil then return scr end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Black covers
--------------------------------------------------------------------------------

-- Never give these a mouseCallback. Setting one clears the window's
-- ignoresMouseEvents, and every covered display would stop accepting clicks
-- rather than merely being dark — which from the iPad is much worse.
--
-- The cursor is drawn above every window, so a pointer left on a covered
-- display stays visible. That is macOS, not a broken cover.
--
-- Exposed on M so a re-require can delete the previous chunk's canvases.
local covers = {}
M.covers = covers

local function uncover()
  for i = #covers, 1, -1 do            -- emptied in place: M.covers must stay valid
    local c = covers[i]
    covers[i] = nil
    pcall(function() c:delete() end)
  end
end

local function cover(builtin)
  uncover()
  -- Without a known built-in, every display would match "not the built-in" and
  -- the whole desk would go black. Refuse instead.
  if not builtin then
    log("WARNING: no built-in display identified; refusing to cover anything")
    return
  end
  for _, scr in ipairs(hs.screen.allScreens()) do
    if not sameScreen(scr, builtin) then
      local f = scr:fullFrame()        -- fullFrame: over the menu bar and Dock too
      local c = hs.canvas.new(f)
      if c then
        c:appendElements({ type = "rectangle", action = "fill",
                           fillColor = { red = 0, green = 0, blue = 0, alpha = 1 },
                           frame = { x = 0, y = 0, w = f.w, h = f.h } })
        c:level(hs.canvas.windowLevels.screenSaver)
        c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
        c:show()
        covers[#covers + 1] = c
      else
        log("could not cover " .. tostring(scr:name()))
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Eudora's windows
--------------------------------------------------------------------------------

-- The observed title is "Eudora – Eudora — 6645 mailboxes": SwiftUI appends the
-- subtitle after an en dash. Matching the separator rather than the bare prefix
-- keeps out a compose window whose subject happens to start with "Eudora".
local function isMainTitle(t)
  if not t then return false end
  if t == WINDOW_TITLE then return true end
  return t:find(WINDOW_TITLE .. " – ", 1, true) == 1
      or t:find(WINDOW_TITLE .. " — ", 1, true) == 1
end

local function eudoraWindow()
  local app = hs.application.get(APP_NAME)
  if not app then return nil end
  for _, w in ipairs(app:allWindows()) do
    if w:isStandard() and isMainTitle(w:title()) then return w end
  end
  local main = app:mainWindow()
  if main and main:isStandard() and not AUXILIARY[main:title()] then
    log("title match failed; using mainWindow: " .. tostring(main:title()))
    return main
  end
  return nil
end

-- An offset from the screen's origin, not absolute coordinates: an absolute
-- frame is anchored to whichever display is primary at the time. Not a unit
-- rect either — toUnitRect clips to the frame it is given, so a window even
-- slightly overhanging its screen would come back smaller every cycle.
local function saveFrame(win)
  local scr = win:screen()
  if not scr then return nil end
  local f, sf = win:frame(), scr:fullFrame()
  return { uuid = scr:getUUID(), dx = f.x - sf.x, dy = f.y - sf.y, w = f.w, h = f.h }
end

local function restoreFrame(win, saved)
  if type(saved) ~= "table" or not (saved.uuid and saved.dx and saved.dy and saved.w and saved.h) then
    return false
  end
  local scr = screenWithUUID(saved.uuid)
  if not scr then return false end
  local sf = scr:fullFrame()
  win:setFrame(hs.geometry.rect(sf.x + saved.dx, sf.y + saved.dy, saved.w, saved.h), 0)
  if not win:screen() then win:moveToScreen(scr, true, true, 0) end   -- never off every display
  return true
end

-- frame(), not fullFrame(): clear of the menu bar and the Dock.
local function filledFrame(screen)
  local f = screen:frame()
  return hs.geometry.rect(f.x + INSET, f.y + INSET, f.w - 2 * INSET, f.h - 2 * INSET)
end

-- Compose windows open on whichever display holds the menu bar, which at night
-- is not the one being worked in. They are pulled over as they appear, once
-- each, so a deliberate move afterwards stands. They are not put back on exit,
-- being transient and having no saved frame.
local swept = {}

local function sweep()
  local builtin = screenNamed(BUILTIN)
  local app = hs.application.get(APP_NAME)
  if not builtin or not app then return end
  local live = {}
  for _, w in ipairs(app:allWindows()) do
    local id = w:id()
    if id then
      live[id] = true
      if not swept[id] and w:isStandard() and not w:isFullScreen()
         and not w:isMinimized() and not sameScreen(w:screen(), builtin) then
        swept[id] = true
        w:moveToScreen(builtin, true, true, 0)
        log("moved to the built-in: " .. tostring(w:title()))
      end
    end
  end
  for id in pairs(swept) do if not live[id] then swept[id] = nil end end
end

--------------------------------------------------------------------------------
-- Night
--------------------------------------------------------------------------------

function M.night()
  if active() then log("already in night mode") return end

  local builtin = builtinScreen(nil)
  if not builtin then log("no display with brightness control; is the lid closed?") return end

  local s = { active = true, covered = true, displays = {}, builtin = nil, window = nil }
  s.builtin = { uuid = builtin:getUUID(), brightness = builtin:getBrightness() }

  -- Read everything first. Nothing is darkened until the record of how to undo
  -- it has been written.
  local jobs = {}
  for _, scr in ipairs(hs.screen.allScreens()) do
    local uuid, name = scr:getUUID(), scr:name()
    if uuid and not sameScreen(scr, builtin) then
      jobs[#jobs + 1] = function(next)
        ddcRead(uuid, "luminance", function(lum)
          if not lum then
            log("no DDC: " .. tostring(name) .. " is covered but not dimmed")
            return next()
          end
          ddcRead(uuid, "contrast", function(con)
            ddcAsync(uuid, { "max", "luminance" }, function(maxOut)
              local maxLum = tonumber(maxOut) or 100
              if lum == 0 then
                -- Already dark: an earlier night mode lost its record.
                -- Recording 0 as "previous" would make it permanent.
                log("WARNING: " .. tostring(name) .. " already reads 0; will restore to " .. maxLum)
                lum = maxLum
              end
              s.displays[uuid] = { name = name, luminance = lum, contrast = con, max = maxLum }
              next()
            end)
          end)
        end)
      end
    end
  end

  local win = eudoraWindow()
  if win and not win:isFullScreen() then s.window = saveFrame(win) end

  series(jobs, function()
    save(s)
    isNight = true

    -- Windows next, while there is still light to see by.
    if win and not win:isFullScreen() then
      swept = {}
      sweep()
      win:setFrame(filledFrame(builtin), 0)    -- absolute coordinates: this moves it too
      win:focus()
    else
      log("no Eudora main window to move")
    end

    -- Then the light: covers first, then the backlights under them.
    cover(builtin)
    for uuid, d in pairs(s.displays) do
      ddcAsync(uuid, { "set", "luminance", "0" }, function() end)
      if d.contrast then ddcAsync(uuid, { "set", "contrast", "0" }, function() end) end
    end
    builtin:setBrightness(NIGHT_LEVEL)

    M.ticker:start()
    M.armedAt = hs.timer.secondsSinceEpoch() + GRACE
    if M.tap then M.tap:start() end
    M.updateMenu()
    log(string.format("night mode on; anything done at the desk after %d seconds restores it (tap enabled=%s)",
                      GRACE, tostring(M.tap and M.tap:isEnabled())))
  end)
end

--------------------------------------------------------------------------------
-- Day
--------------------------------------------------------------------------------

-- Driven from the saved record, not from the displays present: a monitor
-- unplugged since last night must keep its entry, or it comes back dark with
-- nothing to restore it to.
function M.day()
  local s = state()
  if type(s) ~= "table" or not s.active then
    log("not in night mode; restoring what can be restored anyway")
    return M.panic()
  end

  -- Sight back first, and by the two means that cannot fail the way a DDC
  -- message can. Everything else happens afterwards, asynchronously.
  isNight = false          -- before anything slow: stops the tap re-entering
  uncover()
  local builtin = builtinScreen(s.builtin and s.builtin.uuid)
  if builtin then
    local b = s.builtin and s.builtin.brightness
    if type(b) ~= "number" or b < 0.05 then b = PANIC_LEVEL end
    pcall(function() builtin:setBrightness(b) end)
  else
    log("WARNING: no display with brightness control to restore")
  end

  M.ticker:stop()
  if M.tap then M.tap:stop() end
  swept = {}

  local win = eudoraWindow()
  if win and s.window and not restoreFrame(win, s.window) then
    log("the display Eudora came from is not present; leaving the window where it is")
  end

  -- Each display is verified by reading the value back: m1ddc's exit status is
  -- not evidence that the monitor acted on the message.
  local remaining, failed, jobs = {}, {}, {}
  for uuid, d in pairs(s.displays or {}) do
    jobs[#jobs + 1] = function(next)
      local lum = math.floor(tonumber(d.luminance) or 0)
      ddcAsync(uuid, { "set", "luminance", tostring(lum) }, function()
        local function verify()
          ddcRead(uuid, "luminance", function(got)
            if not (got and math.abs(got - lum) <= 2) then
              remaining[uuid] = d
              failed[#failed + 1] = tostring(d.name or uuid)
            end
            next()
          end)
        end
        if d.contrast then
          ddcAsync(uuid, { "set", "contrast", tostring(math.floor(d.contrast)) }, verify)
        else
          verify()
        end
      end)
    end
  end

  series(jobs, function()
    if next(remaining) then
      -- Still "night" as far as the record goes: those displays are dark and
      -- the record is the only way back. But covered = false — the covers are
      -- off, and a reload must not put them back over restored displays.
      save({ active = true, covered = false, displays = remaining,
             builtin = s.builtin, window = nil })
      local msg = "night-mode: not restored — " .. table.concat(failed, ", ")
      log(msg)
      hs.alert.show(msg, 5)
    else
      save({ active = false })
      log("day mode restored")
    end
    M.updateMenu()
  end)
end

-- For when the record is gone: displays dark, nothing saved. Guesses rather
-- than gives up.
function M.panic()
  isNight = false
  uncover()
  local builtin = builtinScreen(nil)
  if builtin then pcall(function() builtin:setBrightness(PANIC_LEVEL) end) end

  for _, scr in ipairs(hs.screen.allScreens()) do
    local uuid, name = scr:getUUID(), scr:name()
    if uuid and not sameScreen(scr, builtin) then
      ddcAsync(uuid, { "max", "luminance" }, function(out)
        local maxLum = tonumber(out)
        if maxLum then
          ddcAsync(uuid, { "set", "luminance", tostring(math.floor(maxLum * PANIC_FRAC)) }, function() end)
          ddcAsync(uuid, { "max", "contrast" }, function(cOut)
            local maxCon = tonumber(cOut)
            if maxCon then
              ddcAsync(uuid, { "set", "contrast", tostring(math.floor(maxCon * PANIC_FRAC)) }, function() end)
            end
          end)
          log("guessed a level for " .. tostring(name))
        end
      end)
    end
  end

  M.ticker:stop()
  if M.tap then M.tap:stop() end
  save({ active = false })
  M.updateMenu()
end

function M.toggle() if active() then M.day() else M.night() end end

function M.status()
  local s = state()
  local n = 0
  if type(s) == "table" and type(s.displays) == "table" then
    for _ in pairs(s.displays) do n = n + 1 end
  end
  log(string.format("active=%s (in memory %s) | covers=%d | saved displays=%d | tap enabled=%s | armed in %ds",
      tostring(active()), tostring(isNight), #covers, n,
      M.tap and tostring(M.tap:isEnabled()) or "none",
      math.max(0, math.ceil(M.armedAt - hs.timer.secondsSinceEpoch()))))
end

--------------------------------------------------------------------------------
-- Ways out, built before anything that could throw
--------------------------------------------------------------------------------

M.hotkey = hs.hotkey.bind(EXIT_MODS, EXIT_KEY, function()
  log("restore: ctrl-alt-cmd-" .. EXIT_KEY)
  M.day()
end)
if not M.hotkey then log("WARNING: could not bind the restore hotkey") end

-- Anything done on a device in the office ends night mode. Two tests
-- distinguish a hand on the desk from Screens replaying the iPad's input: a
-- CGEvent carries the PID of the process that posted it — hardware reports 0 —
-- and its source state, which for hardware is the HID system rather than the
-- combined session state that CGEventPost uses.
local props     = hs.eventtap.event.properties
local types     = hs.eventtap.event.types
local HID_STATE = 1     -- kCGEventSourceStateHIDSystemState

local function fromTheDesk(e)
  if e:getProperty(props.eventSourceUnixProcessID) ~= 0 then return false end
  if props.eventSourceStateID then
    local sid = e:getProperty(props.eventSourceStateID)
    if sid and sid ~= HID_STATE then return false end
  end
  return true
end

M.armedAt = 0

M.tap = hs.eventtap.new({
  types.keyDown, types.flagsChanged,                 -- either keyboard, the keypad
  types.leftMouseDown, types.rightMouseDown, types.otherMouseDown,
  types.leftMouseDragged, types.rightMouseDragged,
  types.mouseMoved, types.scrollWheel,               -- trackpad and mouse
}, function(e)
  -- Everything on this path is a plain memory read or a C call. Nothing here
  -- may touch hs.settings, the file system, or anything else that can block.
  if not isNight then return false end
  if hs.timer.secondsSinceEpoch() < M.armedAt then return false end
  if not fromTheDesk(e) then return false end
  log("restore: local input")
  M.day()
  -- A keystroke is swallowed so it isn't typed into whatever had focus;
  -- pointer events pass through, being harmless and awkward to suppress.
  return e:getType() == types.keyDown
end)

-- macOS disables an event tap that takes too long to answer. Nothing here
-- blocks any more, but this is the way back out if it ever happens again.
M.watchdog = hs.timer.new(10, function()
  if isNight and M.tap and not M.tap:isEnabled() then
    log("event tap had been disabled; restarting it")
    M.tap:start()
  end
end, true):start()

-- Whatever else failed, morning happens.
M.morning = hs.timer.doAt(RESTORE_AT, "1d", function()
  if active() then
    log("automatic restore at " .. RESTORE_AT)
    M.day()
  end
end)

M.ticker = hs.timer.new(SWEEP, function()
  local ok, err = pcall(sweep)
  if not ok then log("sweep error: " .. tostring(err)) end
end, true)

M.menu = hs.menubar.new()
function M.updateMenu()
  if not M.menu then return end
  M.menu:setTitle(active() and "☀" or "☾")
  M.menu:setTooltip(active() and "Night mode is on — touch the keyboard or mouse to restore"
                              or "Click for night mode")
end
if M.menu then
  M.menu:setClickCallback(function() M.toggle() end)
  M.updateMenu()
else
  log("WARNING: no menu bar item; use nightMode.night() and nightMode.day()")
end

-- The covers are absolute-framed windows. If a covered display drops or changes
-- resolution, macOS relocates the orphaned cover onto a surviving display —
-- possibly the built-in. Re-laying them out on any change avoids that.
M.screenWatcher = hs.screen.watcher.new(function()
  if not active() then return end
  local s = state()
  if type(s) == "table" and s.covered == false then return end
  local b = builtinScreen(type(s) == "table" and s.builtin and s.builtin.uuid or nil)
  if b then pcall(cover, b) end
end)
M.screenWatcher:start()

-- Published before the reload block below, so that if anything there throws,
-- the console still has nightMode.day().
nightMode = M

-- A reload while night mode is on leaves the displays dim and the record
-- intact, but takes the covers with it. Put them back and pick the sweep up,
-- rather than pretending it is daytime.
if active() then
  isNight = true
  M.ticker:start()
  -- The same grace as on entry: a reload is usually done from this keyboard,
  -- and the next keystroke shouldn't end the night before the covers are back.
  M.armedAt = hs.timer.secondsSinceEpoch() + GRACE
  if M.tap then M.tap:start() end
  local s = state()
  local b = builtinScreen(type(s) == "table" and s.builtin and s.builtin.uuid or nil)
  if type(s) == "table" and s.covered == false then
    log("night mode is on but the covers were already off; leaving them off")
  elseif b then
    local ok, err = pcall(cover, b)
    if not ok then log("cover failed on reload: " .. tostring(err)) end
  else
    log("WARNING: built-in not found on reload; leaving the externals uncovered")
  end
end

return M
