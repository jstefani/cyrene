local UIState = require('cyrene/lib/ui/util/devices')

-- Make sure there's only one copy
if _Grid ~= nil then return _Grid end

local MAX_GRID_WIDTH = 16
local HEIGHT = 8
local CLICK_DURATION = 0.7

-- Varibright levels. Monobright grids quantize these to on/off at a
-- threshold of 8, so anything dimmer than that is invisible on such a
-- grid -- notably the playhead at 7. See Grid.set_monobright.
local TRIG_LEVEL = 15
local MIN_TRIG_LEVEL = 2
local PLAYPOS_LEVEL = 7
local ACTIVE_ALT_LEVEL = 15
local INACTIVE_ALT_LEVEL = 4
local ACTIVE_PAGE_LEVEL = 15
local INACTIVE_PAGE_LEVEL = 4
local CLEAR_LEVEL = 0

-- On a monobright grid every lit LED is full brightness, so the dim levels
-- above are pushed up to 15 and brightness can no longer encode anything.
local MONO_TRIG_LEVEL = 15
local MONO_MIN_TRIG_LEVEL = 15
local MONO_PLAYPOS_LEVEL = 15
local MONO_INACTIVE_ALT_LEVEL = 15
local MONO_INACTIVE_PAGE_LEVEL = 15

-- Serial prefixes of grids without variable brightness. Monome serials are
-- model-prefixed: the 40h series and the pre-2011 m64/m128/m256 walnut and
-- greyscale editions are all monobright. Varibright grids (2011+) report
-- m1000xxx / m360xxx style serials, so anything unmatched is assumed
-- varibright and can be corrected with the Monobright Grid param.
-- The hyphen is optional: serials appear both as "m128-0123" and "m1280123"
-- depending on era and firmware.
local MONOBRIGHT_SERIAL_PATTERNS = {
  "^m40h",     -- 40h series
  "^m64%-?%d", -- 64 (walnut / greyscale)
  "^m128%-?%d",-- 128 (walnut / greyscale)
  "^m256%-?%d",-- 256 (walnut / greyscale)
  "^m0000",    -- early 40h-era serials
}

local Trigs = {}
local Probabilities = {track=1}

local Grid = {
  connected_grid = nil,
  grid_width = MAX_GRID_WIDTH,
  page_number = 1,
  grid_alt_key_down_time = nil,
  grid_alt_action_taken = false,
  mode = Trigs,
  -- Resolved brightness mode: true once we've decided the grid is monobright
  is_monobright = false,
}

-- Does this grid's serial/name match a known monobright model?
-- Accepts either a vport or a raw grid device; serial lives on the
-- underlying .device, while the vport only carries a name.
-- The serial and name as the detector sees them, for troubleshooting.
function Grid.identify()
  local device = Grid.connected_grid
  if not device then return "no grid connected" end
  local dev = device.device or device
  return string.format("serial=%q name=%q %dx%d -> %s",
    tostring(dev.serial or device.serial or ""),
    tostring(dev.name or device.name or ""),
    tonumber(device.cols) or 0, tonumber(device.rows) or 0,
    Grid.detect_monobright(device) and "monobright" or "varibright")
end

function Grid.detect_monobright(device)
  if not device then return false end
  local dev = device.device or device
  -- Match serial and name separately: g.name is "<friendly name> <serial>",
  -- so an anchored pattern tested against the two concatenated would only
  -- ever match the serial, never a model that shows up in the name.
  local serial = (dev.serial or device.serial or ""):lower()
  local name = (dev.name or device.name or ""):lower()
  for _, pattern in ipairs(MONOBRIGHT_SERIAL_PATTERNS) do
    if serial:match(pattern) or name:match(pattern) then return true end
    -- The name carries the serial appended, so also look for the model
    -- anywhere in it rather than only at the start.
    if name:match("%f[%w]" .. pattern:gsub("^%^", "")) then return true end
  end
  return false
end

-- Re-apply the current param setting (used when a grid is (re)connected).
function Grid.refresh_monobright()
  local setting = params.lookup["cy_monobright_grid"]
    and params:get("cy_monobright_grid") or 1
  Grid.set_monobright(setting)
end

-- Apply the Monobright Grid param: 1 = Auto (detect), 2 = No, 3 = Yes
function Grid.set_monobright(setting)
  if setting == 2 then
    Grid.is_monobright = false
  elseif setting == 3 then
    Grid.is_monobright = true
  else
    Grid.is_monobright = Grid.detect_monobright(Grid.connected_grid)
  end
  UIState.grid_dirty = true
end

-- Brightness accessors: every LED level goes through these so a single
-- switch flips the whole UI between varibright and monobright palettes.
function Grid._trig_level() return Grid.is_monobright and MONO_TRIG_LEVEL or TRIG_LEVEL end
function Grid._min_trig_level() return Grid.is_monobright and MONO_MIN_TRIG_LEVEL or MIN_TRIG_LEVEL end
function Grid._playpos_level() return Grid.is_monobright and MONO_PLAYPOS_LEVEL or PLAYPOS_LEVEL end
function Grid._inactive_alt_level() return Grid.is_monobright and MONO_INACTIVE_ALT_LEVEL or INACTIVE_ALT_LEVEL end
function Grid._inactive_page_level() return Grid.is_monobright and MONO_INACTIVE_PAGE_LEVEL or INACTIVE_PAGE_LEVEL end

function Grid.init(sequencer)
  UIState.init_grid {
    device = grid.connect(),
    key_callback = function(x, y, state)
      if y == 8 then
        local last_row_click = false
        -- The bottom right key is an "alt" key
        if x == Grid.grid_width then
          if state == 1 then
            Grid.grid_alt_key_down_time = util.time()
          else
            if Grid.grid_alt_key_down_time then
              local key_down_duration = util.time() - Grid.grid_alt_key_down_time
              Grid.grid_alt_key_down_time = nil
              -- only count this as a click if no alt action was taken, and if the hold was short enough
              if not (Grid.grid_alt_action_taken or key_down_duration > CLICK_DURATION) then
                last_row_click = true
              end
              Grid.grid_alt_action_taken = false
            end
          end
        elseif state == 1 then
          -- Otherwise we only care about key downs
          -- Key downs in the last row while holding alt are attempts at pagination
          if Grid.grid_alt_key_down_time then
            -- Only paginate if they clicked a valid page
            if x <= Grid._last_page_number(sequencer) then
              Grid.page_number = x
              Grid.grid_alt_action_taken = true
            end
          else
            -- If we weren't in alt mode, this is your standard jumpcut
            last_row_click = true
          end
        end
        if last_row_click then
          Grid.mode.key_callback(x, y, 1, sequencer)
          UIState.screen_dirty = true
        end
      else
        Grid.mode.key_callback(x, y, state, sequencer)
      end
      UIState.grid_dirty = true
      UIState.flash_event()
    end,
    refresh_callback = function(my_grid)
      Grid.connected_grid = my_grid
      for x=1,Grid.grid_width do
        for y=1,HEIGHT do
          if y == 8 then
            if x == Grid.grid_width then
              -- Bottom right is the alt key. Always show it slightly glowing (or full glow when held)
              if Grid.grid_alt_key_down_time then
                Grid.connected_grid:led(x, y, ACTIVE_ALT_LEVEL)
              else
                Grid.connected_grid:led(x, y, Grid._inactive_alt_level())
              end
            elseif Grid.grid_alt_key_down_time then
              -- If the alt key is being held, use the bottom left corner to show pagination options
              if x == Grid.page_number then
                Grid.connected_grid:led(x, y, ACTIVE_PAGE_LEVEL)
              elseif x <= Grid._last_page_number(sequencer) then
                Grid.connected_grid:led(x, y, Grid._inactive_page_level())
              else
                Grid.connected_grid:led(x, y, CLEAR_LEVEL)
              end
            else
              -- Otherwise the last row is just normal tiles
              Grid.mode.refresh_grid_button(x, y, sequencer)
            end
          else
            Grid.mode.refresh_grid_button(x, y, sequencer)
          end
        end
      end
    end,
    width_changed_callback = function(new_width)
      Grid.grid_width = new_width
      -- A width change means a different grid was connected, so re-run
      -- auto-detection against the new device.
      Grid.refresh_monobright()
      UIState.grid_dirty = true
    end
  }
end

function Grid.cleanup()
  if Grid.connected_grid and Grid.connected_grid.device then
    Grid.connected_grid:all(0)
    Grid.connected_grid:refresh()
  end
end

function Grid._sequencer_pos(grid_x)
  return grid_x + (Grid.grid_width * (Grid.page_number - 1))
end

function Grid._last_page_number(sequencer)
  return math.ceil(sequencer:get_pattern_length() / Grid.grid_width)
end

------------------
-- Trigger mode --
------------------

function Trigs.key_callback(x, y, state, sequencer)
  -- Only count key downs
  if state ~= 1 then return end
  if y == 8 then
    if not Grid.grid_alt_key_down_time then
      -- If we weren't in alt mode, this is your standard jumpcut
      -- Handle jumpcuts by telling the sequencer where to cut to
      local trig_x = Grid._sequencer_pos(x)
      sequencer.queued_playpos = trig_x-1
    end
  else
    if Grid.grid_alt_key_down_time then
      -- Switch to probability mode for the clicked track
      Probabilities.track = y
      Grid.mode = Probabilities
    else
      -- Clicks in rows 1-7 while not holding the alt key toggle the trigger in that slot
      local trig_x = Grid._sequencer_pos(x)
      sequencer:set_trig(
        params:get("cy_pattern"),
        trig_x,
        y,
        sequencer:trig_level(params:get("cy_pattern"), trig_x, y) == 0 and 255 or 0
      )
    end
  end
end

function Trigs.refresh_grid_button(x, y, sequencer)
  -- All rows that aren't the bottom row show triggers if active, or the play position otherwise
  local trig_x = Grid._sequencer_pos(x)
  local trig_level = y ~= 8 and sequencer:trig_level(params:get("cy_pattern"), trig_x, y) or 0
  if trig_level == 0 then
    -- If there's no trigger in the slot, show the playhead if it's in our column, otherwise show empty
    if trig_x-1 == sequencer.playpos then
      Grid.connected_grid:led(x, y, Grid._playpos_level())
    else
      Grid.connected_grid:led(x, y, CLEAR_LEVEL)
    end
  else
    -- Show the likelihood of a trigger firing via its brightness (down to some minimum brightness).
    -- On a monobright grid both ends of the range are 15, so skip the interpolation
    -- (linexp with equal endpoints is degenerate) and just light the LED.
    local grid_trig_level
    if Grid.is_monobright then
      grid_trig_level = Grid._trig_level()
    else
      grid_trig_level = math.ceil(util.linexp(0, 255, Grid._min_trig_level(), Grid._trig_level(), trig_level))
      -- Fade out the columns beyond the end of the pattern. There is no dimmer
      -- shade available on a monobright grid, so it stays lit there instead.
      local is_beyond_pattern_end = trig_x > sequencer:get_pattern_length()
      grid_trig_level = is_beyond_pattern_end and math.ceil(grid_trig_level * 0.33) or grid_trig_level
    end
    Grid.connected_grid:led(x, y, grid_trig_level)
  end
end

------------------------
-- Probabilities mode --
------------------------

function Probabilities.key_callback(x, y, state, sequencer)
  -- Only count key downs
  if state ~= 1 then return end
  if y == 8 then
    if x == Grid.grid_width - 1 and not Grid.grid_alt_key_down_time then
      -- Key next to alt key takes back to Trigs mode
      Grid.mode = Trigs
    end
  elseif not Grid.grid_alt_key_down_time then
    -- Clicks in rows 1-7 set the trig level based on the row clicked
    local trig_x = Grid._sequencer_pos(x)
    local trig_level = math.floor(255 * (7 - y) / 6)
    sequencer:set_trig(params:get("cy_pattern"), trig_x, Probabilities.track, trig_level)
  end
end

function Probabilities.refresh_grid_button(x, y, sequencer)
  -- Show a page back button next to the alt button
  if y == 8 and x == Grid.grid_width - 1 then
    Grid.connected_grid:led(x, y, Grid._inactive_alt_level())
    return
  end
  -- All rows that aren't the bottom row show the trig_level in the appropriate row, or the play position otherwise
  local show_playhead = true
  local trig_x = Grid._sequencer_pos(x)
  if y ~= 8 then
    local trig_level = sequencer:trig_level(params:get("cy_pattern"), trig_x, Probabilities.track)
    local row_for_level = math.floor(-1 * (((trig_level/255) * 6) - 7))
    show_playhead = y ~= row_for_level
  end
  if show_playhead then
    -- If there's no trigger in the slot, show the playhead if it's in our column, otherwise show empty
    if trig_x-1 == sequencer.playpos then
      Grid.connected_grid:led(x, y, Grid._playpos_level())
    else
      Grid.connected_grid:led(x, y, CLEAR_LEVEL)
    end
  else
    local is_beyond_pattern_end = trig_x > sequencer:get_pattern_length()
    local grid_trig_level = Grid._trig_level()
    if is_beyond_pattern_end and not Grid.is_monobright then
      grid_trig_level = math.ceil(grid_trig_level * 0.33)
    end
    Grid.connected_grid:led(x, y, grid_trig_level)
  end
end

-- Make sure there's only one copy
if _Grid == nil then
  _Grid = Grid
end
return _Grid
