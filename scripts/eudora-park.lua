-- eudora-park.lua — Hammerspoon
--
-- Park Eudora's main window on the BetterDisplay virtual display when the main
-- external display is powered off, and put it back when it returns.
--
-- Why: the iPad reads mail through a Screens session pinned to a virtual
-- display. A macOS window lives on exactly one display, so Eudora has to
-- physically be on that display to be visible from bed — and dragging it there
-- by hand only works while the iPad is next to you, where you can see what you
-- are doing.
--
-- Install:
--   cp scripts/eudora-park.lua ~/.hammerspoon/
--   echo 'require("eudora-park")' >> ~/.hammerspoon/init.lua
-- then Reload Config from the Hammerspoon menu.
--
-- Drive it by hand from the console. A manual call is respected for 30 seconds
-- before the automatic policy resumes; suspend() buys longer.
--   eudoraPark.status()   eudoraPark.park()   eudoraPark.unpark()
--   eudoraPark.suspend(60)   -- minutes

-- A re-require is a no-op, but a dofile from the console isn't: stop the old
-- timers before installing new ones.
if _G.eudoraPark then
  for _, k in ipairs({ "watcher", "ticker", "power", "pending" }) do
    local t = _G.eudoraPark[k]
    if t then t:stop() end
  end
end

local M = {}

-- Screen names as macOS reports them. To see them:
--   for _, s in ipairs(hs.screen.allScreens()) do print(s:name()) end
local WATCH_SCREEN  = "DELL U4320Q"    -- powering this one off is the signal
local TARGET_SCREEN = "Virtual 16:12"  -- where Eudora goes
local APP_NAME      = "Eudora"         -- the binary is Eudora, not EudoraApp
local WINDOW_TITLE  = "Eudora"         -- ContentView's .navigationTitle

-- Auxiliary windows, never the one to move.
local AUXILIARY = { ["Find Messages"] = true, ["Blacklist"] = true, ["Settings"] = true }

local SETTLE     = 6.0   -- a display change arrives as a burst, and macOS does
                         -- its own window reflow first; acting immediately
                         -- means racing it
local TICK       = 5.0   -- the poll is the safety net: it recovers from a
                         -- missed notification, from an error, and from Eudora
                         -- not running when the change happened
local WAKE_QUIET = 20.0  -- a display can be absent for several seconds during
                         -- wake or a DisplayPort renegotiation without being
                         -- off; parking on that would be a false positive
local BACKOFF    = 60.0  -- after a move that didn't take, rather than spinning
local MANUAL     = 30.0  -- a hand-driven call gets this long before the policy
                         -- takes over again

-- Persisted so the restore survives a reload or a crash. Stored as a screen
-- UUID plus a unit rect rather than absolute coordinates: absolute frames are
-- anchored to whichever display is primary at the time, so a frame recorded
-- while the U4320Q is off means something different once it is back, and
-- setFrame does no clamping — the window could land wholly off-screen.
-- Against fullFrame(), not frame(): toUnitRect clips to the rect it is given,
-- so a window overhanging the Dock would shrink a little on every save.
local kFrame = "eudoraPark_savedFrame"  -- no dot: hs.settings.watchKey can't watch one

local function log(...) print("[eudora-park]", ...) end

local function now() return hs.timer.secondsSinceEpoch() end

local quietUntil, pending, lastSeen, lastComplaint = 0, nil, nil, 0

-- Never shortens an existing quiet period: the wake suppression must not be
-- undercut by the settle delay of a display arriving during that same wake.
local function quietFor(seconds) quietUntil = math.max(quietUntil, now() + seconds) end

local function screenNamed(name)
  for _, s in ipairs(hs.screen.allScreens()) do
    if s:name() == name then return s end
  end
  return nil
end

local function screenWithUUID(uuid)
  for _, s in ipairs(hs.screen.allScreens()) do
    if s:getUUID() == uuid then return s end
  end
  return nil
end

local function sameScreen(a, b) return a and b and a:id() == b:id() end

-- The main window specifically. Compose windows carry the draft's subject.
-- The fallbacks exist because an exact title match fails silently, and a
-- silent failure here is discovered from bed; each logs which rule matched.
--
-- The observed title is "Eudora – Eudora — 6645 mailboxes": SwiftUI appends the
-- subtitle after an en dash. Matching the separator rather than just the prefix
-- keeps a compose window whose subject happens to start with "Eudora" out.
local function isMainTitle(t)
  if not t then return false end
  if t == WINDOW_TITLE then return true end
  return t:find(WINDOW_TITLE .. " – ", 1, true) == 1   -- en dash
      or t:find(WINDOW_TITLE .. " — ", 1, true) == 1   -- em dash, in case
end

local lastRule = nil
local function ruleLog(rule, title)
  if lastRule ~= rule then
    lastRule = rule
    log(rule .. ": " .. tostring(title))
  end
end

local function eudoraWindow()
  local app = hs.application.get(APP_NAME)
  if not app then return nil end
  local wins = app:allWindows()
  for _, w in ipairs(wins) do
    if w:isStandard() and isMainTitle(w:title()) then
      lastRule = "title"
      return w
    end
  end
  local main = app:mainWindow()
  if main and main:isStandard() and not AUXILIARY[main:title()] then
    ruleLog("title match failed; using mainWindow", main:title())
    return main
  end
  for _, w in ipairs(wins) do
    if w:isStandard() and not AUXILIARY[w:title()] then
      ruleLog("title and mainWindow failed; using first standard window", w:title())
      return w
    end
  end
  return nil
end

-- Identity of the current display set, so a frame recorded under one
-- arrangement is never confused with one recorded under another.
local function screenFingerprint()
  local ids = {}
  for _, s in ipairs(hs.screen.allScreens()) do ids[#ids + 1] = s:getUUID() or s:name() or "?" end
  table.sort(ids)
  return table.concat(ids, ",")
end

-- Only a position that has held still for a full tick, under an unchanged
-- display set, is worth saving. macOS relocates windows itself when a display
-- goes away — including when the *virtual* display goes away, which the watch
-- screen tells us nothing about — and a position it chose is the one place the
-- window was never wanted.
local function remember(win)
  local scr = win:screen()
  if not scr then return end
  local f = win:frame()
  local cand = { fp = screenFingerprint(), uuid = scr:getUUID(),
                 x = f.x, y = f.y, w = f.w, h = f.h }

  local steady = lastSeen and lastSeen.fp == cand.fp and lastSeen.uuid == cand.uuid
    and math.abs(lastSeen.x - cand.x) < 1 and math.abs(lastSeen.y - cand.y) < 1
    and math.abs(lastSeen.w - cand.w) < 1 and math.abs(lastSeen.h - cand.h) < 1

  if steady then
    local u = f:toUnitRect(scr:fullFrame())
    hs.settings.set(kFrame, { uuid = cand.uuid, x = u.x, y = u.y, w = u.w, h = u.h })
  end
  lastSeen = cand
end

-- `auto` is set when the policy calls these; a hand call from the console gets
-- a grace period so it isn't undone by the next tick.
function M.park(auto)
  if not auto then quietFor(MANUAL) end

  local target = screenNamed(TARGET_SCREEN)
  if not target then log("no display named " .. TARGET_SCREEN .. "; doing nothing") return end
  local win = eudoraWindow()
  if not win then log("no Eudora main window; will retry on the next tick") return end
  -- setFrame on a full-screen window fights macOS and loses.
  if win:isFullScreen() then log("window is full screen; leaving it alone") return end
  if sameScreen(win:screen(), target) then return end

  win:setFrame(target:frame(), 0)  -- frame(), not fullFrame(): clear of the menu bar
  if not sameScreen(win:screen(), target) then
    -- Cross-display setFrame issues position and size separately and macOS can
    -- clamp the size against the old screen. One retry the other way round.
    win:moveToScreen(target, false, true, 0)
    win:setFrame(target:frame(), 0)
  end
  if not sameScreen(win:screen(), target) then
    log(string.format("park did not take; backing off %.0fs", BACKOFF))
    quietFor(BACKOFF)
    return
  end
  local got = win:frame()
  log(string.format("parked on %s at %.0f,%.0f %.0fx%.0f",
                    TARGET_SCREEN, got.x, got.y, got.w, got.h))
end

function M.unpark(auto)
  if not auto then quietFor(MANUAL) end

  local win = eudoraWindow()
  if not win then log("no Eudora main window; will retry on the next tick") return end
  if win:isFullScreen() then log("window is full screen; leaving it alone") return end

  local saved = hs.settings.get(kFrame)
  if type(saved) == "table" and saved.uuid and saved.x and saved.y and saved.w and saved.h then
    local scr = screenWithUUID(saved.uuid)
    if scr then
      local rect = hs.geometry.rect(saved.x, saved.y, saved.w, saved.h)
      win:setFrame(rect:fromUnitRect(scr:fullFrame()), 0)
      log("restored to " .. tostring(scr:name()))
      lastSeen = nil  -- don't let the pre-move sample count as "steady"
      return
    end
    log("saved display is not present; falling back")
  end

  -- No usable saved frame: at least get it off the virtual display.
  local watch = screenNamed(WATCH_SCREEN)
  if not watch then log("no saved frame and no " .. WATCH_SCREEN .. "; leaving it alone") return end
  win:moveToScreen(watch, false, true, 0)
  if sameScreen(win:screen(), watch) then
    log("no saved frame; moved to " .. WATCH_SCREEN)
    lastSeen = nil
  else
    log(string.format("fallback move did not take; backing off %.0fs", BACKOFF))
    quietFor(BACKOFF)
  end
end

function M.suspend(minutes)
  quietFor((minutes or 30) * 60)
  log(string.format("suspended for %.0f minutes", minutes or 30))
end

function M.status()
  local win = eudoraWindow()
  local scr = win and win:screen()
  local saved = hs.settings.get(kFrame)
  log(string.format("%s %s | %s %s | window %s | saved %s | quiet %s",
      WATCH_SCREEN,  screenNamed(WATCH_SCREEN)  and "present" or "absent",
      TARGET_SCREEN, screenNamed(TARGET_SCREEN) and "present" or "absent",
      win and (tostring(scr and scr:name()) .. " " .. tostring(win:frame())) or "not found",
      type(saved) == "table" and tostring(saved.uuid) or "none",
      now() < quietUntil and string.format("%.0fs", quietUntil - now()) or "no"))
end

-- Whether the window is parked is derived from where it actually is, never
-- from a remembered flag: a flag and a window can disagree silently, and did.
local function reconcile()
  if pending then pending:stop() pending = nil end
  if now() < quietUntil then return end

  local win = eudoraWindow()
  if not win or win:isFullScreen() then return end
  -- A window wholly outside every display has no screen and is unreachable;
  -- unpark's moveToScreen(..., ensureInScreenBounds) is the way back.
  if not win:screen() then M.unpark(true) return end

  local target = screenNamed(TARGET_SCREEN)
  local onTarget = sameScreen(win:screen(), target)

  if screenNamed(WATCH_SCREEN) then
    if onTarget then M.unpark(true) else remember(win) end
  elseif target then
    if not onTarget then M.park(true) end
  elseif now() - lastComplaint > 60 then
    lastComplaint = now()
    log(WATCH_SCREEN .. " is absent but so is " .. TARGET_SCREEN .. "; is BetterDisplay running?")
  end
end

-- An error inside a repeating timer stops it for good unless it is created
-- with continueOnError; the pcall keeps the log readable either way.
M.reconcile = function()
  local ok, err = pcall(reconcile)
  if not ok then log("error:", tostring(err)) end
end

local function defer()
  quietFor(SETTLE)
  if pending then pending:stop() end
  pending = hs.timer.doAfter(SETTLE + 0.5, M.reconcile)
  M.pending = pending
end

M.watcher = hs.screen.watcher.new(defer)
M.watcher:start()

M.ticker = hs.timer.new(TICK, M.reconcile, true):start()

-- hs.screen.watcher can miss changes that happen while the system is asleep,
-- and displays come back one at a time.
M.power = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
    quietFor(WAKE_QUIET)
  end
end)
M.power:start()

-- Reconcile at load, but through the settle delay: a reload can coincide with
-- the very change it is meant to wait out.
defer()

-- Deliberately global, so the console can drive it by hand.
eudoraPark = M

return M
