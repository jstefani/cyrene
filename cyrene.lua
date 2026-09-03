-- Cyrene, a drummer in a box
--
-- E1 controls page
--
-- Landing page:
-- E2 controls volume
-- E3 controls tempo
-- K2 stops playback
-- K3 resumes playback
-- K2 while stopped
--  resets to beat 1
--
-- Swing page:
-- K2 & K3 switch sections
-- E2 & E3 change values
-- (check README or wiki
--  for more swing info)
--
-- Performance page:
-- E2 changes global pitch
-- E3 changes global filter
--
-- Pattern & Density page:
-- K2 & K3 switch sections
-- E2 & E3 change values
--
-- More Densities page:
-- K2 & K3 switch sections
-- E2 & E3 change values
--
-- Euclidean page:
-- K2 & K3 switch track
-- E2 changes fill
-- E3 changes length
-- K2+E2 changes rotation
-- K2+E3 enables/disables
--   euclidean mode
--    (when off, changes
--     have no effect)
--
-- Grid (optional):
-- Rows are tracks
-- First 3: kick, snare, hat
-- Columns are beats
-- Key toggles trigger
-- Last row changes
--  playback position
-- Bottom right is alt,
--  hold & click bottom left
--    to change page
--  hold & click a track
--    for probability editing
--    then click next to alt
--    to go back
--  hold & click next to alt
--    for the pattern picker
--    (keys select the current
--     pattern, in rows across;
--     same key exits)
--
-- Crow (optional):
-- Configurable
--  via params menu
-- Outputs are gates
--  or envelopes
--  per track
-- Inputs modulate
--  selected params
--
-- Arc (optional):
-- Use the params page
-- to choose which params
-- are controled by which enc
-- Defaults:
-- E1: Tempo
-- E2: Swing percentage
-- E3: Pattern X
-- E4: Pattern Y
--
-- Track lengths:
-- Each track has its own
--  length (params menu,
--  "N: Length") and runs
--  free of the others
-- Stop resets them all
-- Each pattern remembers
--  its own track lengths
--
-- Change samples, fx, etc
--  via the params menu
--
--
-- Adapted from Grids
--   by Emilie Gillet
-- and Step, by @jah
-- and Playfair, by @tehn
--
--
-- v1.9.1 @21echoes
local current_version = "1.9.1"

engine.name = 'Ack'

local Ack = require 'ack/lib/ack'
local ControlSpec = require 'controlspec'
local UI = require 'ui'
local Sequencer = require('cyrene/lib/sequencer')
local MidiOut = require('cyrene/lib/midi_out')
local PlaybackUI = require('cyrene/lib/ui/playback')
local SwingUI = require('cyrene/lib/ui/swing')
local PerformanceUI = require('cyrene/lib/ui/performance')
local PatternAndDensityUI = require('cyrene/lib/ui/pattern_and_density')
local MoreDensityUI = require('cyrene/lib/ui/more_density')
local EuclideanUI = require('cyrene/lib/ui/euclidean')
local UIState = require('cyrene/lib/ui/util/devices')
local GridUI = require('cyrene/lib/ui/grid')
local CrowIO = require('cyrene/lib/crow_io')
local Arcify = require("cyrene/lib/arcify")

local launch_version

local sequencer
local pages
local pages_table
local ui_refresh_metro
local NUM_TRACKS = 7

-- Global pitch: a semitone offset applied on top of each track's own speed.
--
-- Each track's unshifted "base" speed is held in its own hidden param
-- (cy_<n>_base_speed) so that the base is what gets written to the PSET.
-- The audible <n>_speed is always derived as base * 2^(semitones/12).
--
-- Storing the base rather than the derived value is what makes reload
-- correct. params:read() is NOT silent -- it fires each param's action as
-- it loads -- so if the shifted speed were the saved value, loading it and
-- then applying the saved offset on top would shift it twice, compounding
-- on every save/load cycle until it hit the clamp. With the base saved,
-- the offset is re-derived from scratch and is idempotent.
--
-- Deriving from the base also means clamping at the edges of Ack's speed
-- range is non-destructive: pitching back down restores the original speed.
local global_pitch_spec = ControlSpec.new(-24, 24, 'lin', 0, 0, 'st')
local is_applying_global_pitch = false

local function _base_speed_id(track) return "cy_" .. track .. "_base_speed" end

local function _get_base_speed(track)
  local id = _base_speed_id(track)
  if params.lookup[id] then return params:get(id) end
  return params:get(track .. "_speed")
end

function _apply_global_pitch(value)
  local ratio = 2 ^ (value / 12)
  is_applying_global_pitch = true
  for track = 1, NUM_TRACKS do
    local speed_id = track .. "_speed"
    if params.lookup[speed_id] then
      local spec = params:lookup_param(speed_id).controlspec
      params:set(speed_id, util.clamp(_get_base_speed(track) * ratio, spec.minval, spec.maxval))
    end
  end
  is_applying_global_pitch = false
end

-- When the user edits a track's speed directly, that becomes its new base
-- (interpreted at the current global pitch).
function _track_speed_changed(track, value)
  if is_applying_global_pitch then return end
  -- cy_global_pitch is registered after the track groups, so it may not
  -- exist yet the first time an Ack speed action fires.
  local pitch = params.lookup["cy_global_pitch"] and params:get("cy_global_pitch") or 0
  local id = _base_speed_id(track)
  if params.lookup[id] then
    params:set(id, value / (2 ^ (pitch / 12)), true) -- silent: no re-derive
  end
end

-- A PSET written before the base params existed stores the already-shifted
-- speed and carries no base values. cy_base_params_saved is written as 1 by
-- any PSET that does have them, so if it comes back 0 we divide the saved
-- offset back out once, rather than shifting the value a second time.
function _migrate_base_params()
  if params:get("cy_base_params_saved") == 1 then return end
  local pitch_ratio = 2 ^ (params:get("cy_global_pitch") / 12)
  for track = 1, NUM_TRACKS do
    local base_speed = _base_speed_id(track)
    if params.lookup[base_speed] then
      params:set(base_speed, params:get(track .. "_speed") / pitch_ratio, true)
    end
  end
  params:set("cy_base_params_saved", 1, true)
end

-- Randomize Pan: tracks 1-3 (kick, snare, hi-hat) always keep their pan;
-- only tracks 4+ are randomized. Successive presses widen the spread in a
-- 4-step cycle, then loop back to modest positions.
--
-- Each stage has a curve and a max width. A raw uniform value in [-1, 1] is
-- shaped as sign(r) * |r|^curve * width. curve > 1 biases toward center,
-- curve = 1 is uniform, curve < 1 biases outward. So stage 1 clusters near
-- the middle and later stages make hard-panned values progressively more
-- likely -- but never certain, since the full inner range stays reachable.
local FIRST_RANDOMIZED_PAN_TRACK = 4
local PAN_RANDOMIZE_STAGES = {
  {curve = 2.5, width = 0.35}, -- 1: subtle, hugs the center
  {curve = 1.6, width = 0.60}, -- 2: opening up
  {curve = 1.1, width = 0.85}, -- 3: wide, near-uniform
  {curve = 0.7, width = 1.00}, -- 4: full field, favors the edges
}
local pan_randomize_stage = 0

function _randomize_pan()
  -- Advance first, so the very first press uses stage 1.
  pan_randomize_stage = (pan_randomize_stage % #PAN_RANDOMIZE_STAGES) + 1
  local stage = PAN_RANDOMIZE_STAGES[pan_randomize_stage]
  for track = FIRST_RANDOMIZED_PAN_TRACK, NUM_TRACKS do
    local pan_id = track .. "_pan"
    if params.lookup[pan_id] then
      local raw = (math.random() * 2) - 1
      local shaped = (raw < 0 and -1 or 1) * (math.abs(raw) ^ stage.curve) * stage.width
      params:set(pan_id, util.clamp(shaped, -1, 1))
    end
  end
  UIState.screen_dirty = true
end

-- Global filter: a DJ-style single-knob filter across all tracks.
--
--   < 0  every track switches to lowpass, sweeping down from 20kHz
--   = 0  hands each track back its own filter mode and cutoff, untouched
--   > 0  every track switches to highpass, sweeping up from 20Hz
--
-- At exactly zero the script writes nothing of its own: each track uses the
-- filter type and cutoff the user set for it. Moving off zero takes over
-- both, and returning to zero restores them, so the control is completely
-- non-destructive.
--
-- The sweep is exponential in frequency (each unit is a constant ratio),
-- because a linear Hz sweep spends nearly all its travel in a range the ear
-- barely registers.
local FILTER_MODE_LOWPASS = 1
local FILTER_MODE_HIGHPASS = 3
local FILTER_MIN_HZ = 20
local FILTER_MAX_HZ = 20000
-- How far the knob travels in each direction
local global_filter_spec = ControlSpec.new(-100, 100, 'lin', 0, 0, '')

-- Each track's own cutoff and mode live in hidden params so that they, not
-- the swept values, are what get written to the PSET. params:read() is not
-- silent -- it fires actions as it loads -- so saving the swept cutoff would
-- lose the user's real setting the first time a PSET was saved mid-sweep.
local is_applying_global_filter = false

local function _base_cutoff_id(track) return "cy_" .. track .. "_base_cutoff" end
local function _base_mode_id(track) return "cy_" .. track .. "_base_filter_mode" end

local function _get_base_cutoff(track)
  local id = _base_cutoff_id(track)
  if params.lookup[id] then return params:get(id) end
  return params:get(track .. "_filter_cutoff")
end

local function _get_base_mode(track)
  local id = _base_mode_id(track)
  if params.lookup[id] then return params:get(id) end
  return params:get(track .. "_filter_mode")
end

-- Map knob travel (0..1 away from center) onto a frequency sweep.
-- Lowpass closes 20kHz -> 20Hz; highpass opens 20Hz -> 20kHz.
local function _sweep_hz(amount, is_highpass)
  local ratio = FILTER_MAX_HZ / FILTER_MIN_HZ
  if is_highpass then
    return FILTER_MIN_HZ * (ratio ^ amount)
  end
  return FILTER_MAX_HZ * (ratio ^ -amount)
end

function _apply_global_filter(value)
  is_applying_global_filter = true
  local spec_max = math.abs(global_filter_spec.maxval)
  local amount = math.abs(value) / spec_max
  for track = 1, NUM_TRACKS do
    local cutoff_id = track .. "_filter_cutoff"
    local mode_id = track .. "_filter_mode"
    if params.lookup[cutoff_id] then
      if value == 0 then
        -- Neutral: hand the track back its own filter, untouched
        params:set(cutoff_id, _get_base_cutoff(track))
        if params.lookup[mode_id] then
          params:set(mode_id, _get_base_mode(track))
        end
      else
        local is_highpass = value > 0
        if params.lookup[mode_id] then
          params:set(mode_id, is_highpass and FILTER_MODE_HIGHPASS or FILTER_MODE_LOWPASS)
        end
        local spec = params:lookup_param(cutoff_id).controlspec
        params:set(cutoff_id, util.clamp(_sweep_hz(amount, is_highpass), spec.minval, spec.maxval))
      end
    end
  end
  is_applying_global_filter = false
  UIState.params_dirty = true
  UIState.screen_dirty = true
end

-- A direct edit to a track's cutoff or mode becomes its new base, but only
-- while the global filter is neutral. Mid-sweep the script owns those
-- params, so an edit then is the sweep writing, not the user.
function _track_cutoff_changed(track, value)
  if is_applying_global_filter then return end
  if (params.lookup["cy_global_filter"] and params:get("cy_global_filter") or 0) ~= 0 then return end
  local id = _base_cutoff_id(track)
  if params.lookup[id] then
    params:set(id, value, true) -- silent: no re-derive
  end
end

function _track_filter_mode_changed(track, value)
  if is_applying_global_filter then return end
  if (params.lookup["cy_global_filter"] and params:get("cy_global_filter") or 0) ~= 0 then return end
  local id = _base_mode_id(track)
  if params.lookup[id] then
    params:set(id, value, true)
  end
end

-- PSETs written before the base params existed store the already-shifted
-- cutoff; divide the saved offset back out once so it is not applied twice.
function _migrate_base_cutoffs()
  if params:get("cy_base_cutoffs_saved") == 1 then return end
  -- Only trust the live values as the user's own when the filter is neutral;
  -- mid-sweep they are the sweep's, and the real settings are unrecoverable,
  -- so fall back to leaving whatever the track already has.
  for track = 1, NUM_TRACKS do
    local cutoff_id = _base_cutoff_id(track)
    if params.lookup[cutoff_id] then
      params:set(cutoff_id, params:get(track .. "_filter_cutoff"), true)
    end
    local mode_id = _base_mode_id(track)
    if params.lookup[mode_id] then
      params:set(mode_id, params:get(track .. "_filter_mode"), true)
    end
  end
  params:set("cy_base_cutoffs_saved", 1, true)
end

local arc_device = arc.connect()
local arcify = Arcify.new(arc_device, false)

local function init_params()
  sequencer:add_params(arcify)
  for track=1,sequencer.num_tracks do
    local group_name = "Track "..track
    if track == 1 then group_name = "Kick"
    elseif track == 2 then group_name = "Snare"
    elseif track == 3 then group_name = "Hi-Hat"
    end
    params:add_group(group_name, 30)
    -- All the pages together add 5 params per track
    sequencer:add_params_for_track(track, arcify)
    Ack.add_channel_params(track) -- 22 params
    -- Hidden params holding this track's own speed, cutoff and filter mode.
    -- These are what land in the PSET: the global pitch offset is re-derived
    -- from the base speed on load, and the DJ filter hands the cutoff and
    -- mode back when it returns to neutral.
    params:add {
      type="control",
      id=_base_speed_id(track),
      name=track..": base speed",
      controlspec=params:lookup_param(track.."_speed").controlspec,
    }
    params:hide(params.lookup[_base_speed_id(track)])
    params:add {
      type="control",
      id=_base_cutoff_id(track),
      name=track..": base cutoff",
      controlspec=params:lookup_param(track.."_filter_cutoff").controlspec,
    }
    params:hide(params.lookup[_base_cutoff_id(track)])
    params:add {
      type="number",
      id=_base_mode_id(track),
      name=track..": base filter mode",
      min=1,
      max=5,
      default=params:get(track.."_filter_mode"),
    }
    params:hide(params.lookup[_base_mode_id(track)])
    -- Track direct edits to speed so global pitch stays relative to them
    local ack_speed_action = params:lookup_param(track.."_speed").action
    params:set_action(track.."_speed", function(value)
      ack_speed_action(value)
      _track_speed_changed(track, value)
    end)
    -- Track direct cutoff edits so the global filter stays relative to them
    local ack_cutoff_action = params:lookup_param(track.."_filter_cutoff").action
    params:set_action(track.."_filter_cutoff", function(value)
      ack_cutoff_action(value)
      _track_cutoff_changed(track, value)
    end)
    local ack_mode_action = params:lookup_param(track.."_filter_mode").action
    params:set_action(track.."_filter_mode", function(value)
      ack_mode_action(value)
      _track_filter_mode_changed(track, value)
    end)
    -- all params except the file are arcifyed
    arcify:register(track.."_start_pos")
    arcify:register(track.."_end_pos")
    arcify:register(track.."_loop")
    arcify:register(track.."_loop_point")
    arcify:register(track.."_speed")
    arcify:register(track.."_vol")
    arcify:register(track.."_vol_env_atk")
    arcify:register(track.."_vol_env_rel")
    arcify:register(track.."_pan")
    arcify:register(track.."_filter_cutoff")
    arcify:register(track.."_filter_res")
    arcify:register(track.."_filter_mode")
    arcify:register(track.."_filter_env_atk")
    arcify:register(track.."_filter_env_rel")
    arcify:register(track.."_filter_env_mod")
    arcify:register(track.."_sample_rate")
    arcify:register(track.."_bit_depth")
    arcify:register(track.."_dist")
    arcify:register(track.."_in_mutegroup")
    arcify:register(track.."_delay_send")
    arcify:register(track.."_reverb_send")
  end
  -- Marks a PSET as containing the hidden base speed params.
  -- Absent (0) means the PSET predates them and needs migrating.
  params:add {
    type="number",
    id="cy_base_params_saved",
    name="Base Params Saved",
    min=0,
    max=1,
    default=0,
  }
  params:hide(params.lookup["cy_base_params_saved"])

  -- Marks a PSET as containing the hidden base cutoff params.
  params:add {
    type="number",
    id="cy_base_cutoffs_saved",
    name="Base Cutoffs Saved",
    min=0,
    max=1,
    default=0,
  }
  params:hide(params.lookup["cy_base_params_saved"])

  params:add_separator("Global Pitch")
  params:add {
    type="control",
    id="cy_global_pitch",
    name="Global Pitch",
    controlspec=global_pitch_spec,
    formatter=function(param)
      local val = param:get()
      return string.format("%+.2f st", val)
    end,
    action=function(value)
      _apply_global_pitch(value)
    end,
  }
  arcify:register("cy_global_pitch")

  params:add_separator("Randomize Pan")
  params:add {
    type="trigger",
    id="cy_randomize_pan",
    name="Randomize Pan",
    action=function() _randomize_pan() end,
  }

  params:add_separator("Grid")
  params:add {
    type="option",
    id="cy_monobright_grid",
    name="Monobright Grid",
    options={"Auto", "No", "Yes"},
    default=1,
    action=function(value)
      -- On a monobright grid the dim playhead (level 7) is below the
      -- on/off threshold and therefore invisible; this lights it fully.
      GridUI.set_monobright(value)
    end,
  }

  params:hide(params.lookup["cy_base_cutoffs_saved"])

  params:add_separator("Performance")
  params:add {
    type="control",
    id="cy_global_filter",
    name="Global Filter",
    controlspec=global_filter_spec,
    formatter=function(param)
      local v = param:get()
      if math.abs(v) < 0.5 then return "off" end
      return string.format("%s %d%%", v > 0 and "HP" or "LP", util.round(math.abs(v)))
    end,
    action=function(value) _apply_global_filter(value) end,
  }
  arcify:register("cy_global_filter")
  -- Ack provides a main output level that Cyrene never exposed. It is not on
  -- the Performance page (the system output_level next to the tempo on the
  -- first page already covers master volume in practice), but it is free and
  -- MIDI/arc mappable, so it stays available here.
  Ack.add_main_level_param() -- 1 param
  arcify:register("main_level")

  params:add_group("Effects", 6)
  Ack.add_effects_params() -- 6 params
  arcify:register("delay_time")
  arcify:register("delay_feedback")
  arcify:register("delay_level")
  arcify:register("reverb_room_size")
  arcify:register("reverb_damp")
  arcify:register("reverb_level")
  MidiOut:add_params(sequencer.num_tracks, arcify, false)
  CrowIO:add_params(sequencer.num_tracks, arcify, false)
  arcify:add_params()

  local is_first_launch = not sequencer:has_pattern_file()
  if is_first_launch then
    _set_sample(1, "audio/x0x/808/808-BD.wav", -10.0)
    _set_sample(2, "audio/x0x/808/808-SD.wav", -15.0)
    _set_sample(3, "audio/x0x/808/808-CH.wav", -10.0)
    _set_sample(4, "audio/x0x/808/808-OH.wav", -17.0)
    _set_sample(5, "audio/x0x/808/808-MA.wav", -10.0)
    _set_sample(6, "audio/x0x/808/808-RS.wav", -16.0)
    _set_sample(7, "audio/x0x/808/808-HC.wav", -20.0)

    arcify:map_encoder_via_params(1, "cy_clock_tempo")
    arcify:map_encoder_via_params(2, "cy_swing_amount")
    arcify:map_encoder_via_params(3, "cy_grids_pattern_x")
    arcify:map_encoder_via_params(4, "cy_grids_pattern_y")
  end
end

local function init_ui_refresh_metro()
  ui_refresh_metro = metro.init()
  if ui_refresh_metro == nil then
    print("unable to start ui refresh metro")
  end
  ui_refresh_metro.event = UIState.refresh
  ui_refresh_metro.time = 1/24
  ui_refresh_metro:start()
end

local function init_ui()
  pages = UI.Pages.new(1, #pages_table)

  UIState.init_arc {
    device = arc_device,
    delta_callback = function(n, delta)
      -- Ignore attempts to change the tempo when the tempo source is external
      if arcify:param_id_at_encoder(n) == "clock_tempo" and params:get("clock_source") ~= 1 then
        return
      end
      arcify:update(n, delta)
    end,
    refresh_callback = function(my_arc)
      arcify:redraw()
    end
  }

  GridUI.init(sequencer)

  UIState.init_screen {
    refresh_callback = function()
      redraw()
    end
  }

  init_ui_refresh_metro()
end

function init()
  math.randomseed(os.time())
  -- Once we care about comparing launch and current versions, use this:
  _check_launch_version()
  _run_migrations()

  sequencer = Sequencer:new()
  pages_table = {
    PlaybackUI:new(),
    SwingUI:new(),
    PerformanceUI:new(),
    PatternAndDensityUI:new(),
    MoreDensityUI:new(),
    EuclideanUI:new(sequencer),
  }

  init_params()
  init_ui()
  MidiOut:start_at_beginning()
  CrowIO:initialize()

  params:read()
  -- Set up the default arcify
  if _version_gt("1.6.-1", launch_version) then
    _upgrade_to_1_6_0()
  end
  params:set("cyrene_version", current_version)
  _migrate_base_params()
  _migrate_base_cutoffs()
  params:bang()
  -- Re-derive the audible speeds and cutoffs from the saved base values.
  -- This runs after bang() so it wins regardless of the order bang() used
  -- (ParamSet:bang iterates with pairs(), which is unordered).
  _apply_global_pitch(params:get("cy_global_pitch"))
  _apply_global_filter(params:get("cy_global_filter"))

  _set_encoder_sensitivities()

  sequencer:initialize()
  params:set("cy_play", 1)
  -- if our params saved as "already playing", then
  -- setting cy_play=1 doesn't trigger a change,
  -- so it won't start without us manually calling _start()
  if not sequencer.playing then
    sequencer:_start()
  end

  -- Working around a strange bug where the param value is changed after boot without changing playback state
  clock.run(function()
    clock.sleep(1)
    params:lookup_param("cy_play").value = sequencer.playing and 1 or 0
  end)
end

function cleanup()
  -- Mark this PSET as carrying base speed/cutoff values so it is not
  -- treated as a pre-base-param PSET when it is loaded back.
  params:set("cy_base_params_saved", 1, true)
  params:set("cy_base_cutoffs_saved", 1, true)
  params:write()

  sequencer:save_patterns()

  GridUI.cleanup()

  metro.free(ui_refresh_metro.id)
  ui_refresh_metro = nil
  -- for i, page in ipairs(pages_table) do
  --   pages_table[i]:cleanup()
  --   pages_table[i] = nil
  -- end
  pages_table = nil
  pages = nil
end

local function current_page()
  return pages_table[pages.index]
end

function redraw()
  screen.clear()
  pages:redraw()
  current_page():redraw(sequencer)
  UI.params_dirty = false
  screen.update()
end

function enc(n, delta)
  if n == 1 then
    -- E1 changes page
    pages:set_index_delta(util.clamp(delta, -1, 1), false)
    -- current_page():enter()
    UIState.screen_dirty = true
  else
    -- Other encoders are routed to the current page's class
    current_page():enc(n, delta, sequencer)
  end
end

function key(n, z)
  -- All key presses are routed to the current page's class.
  current_page():key(n, z, sequencer)
end

function clock.transport.start()
  if sequencer then
    sequencer:_start(true)
    -- this is a no-op, but keeps the param in sync.
    -- (We need to call :_start directly above
    -- so we can pass immediately=true)
    params:set("cy_play", 1, true)
  end
end

function clock.transport.stop()
  if sequencer then
    if sequencer.playing then
      params:set("cy_play", 0)
    else
      -- Already stopped: a second stop rewinds to the start,
      -- matching K2 on the playback page.
      params:set("cy_reset", 1)
      UIState.grid_dirty = true
    end
  end
end

function _set_sample(track, path, volume)
  local full_path = _path.dust .. path
  if util.file_exists(full_path) then
    params:set(track .. "_sample", full_path)
    params:set(track .. "_vol", volume)
  end
end

function _set_encoder_sensitivities()
  -- 1 sensitivity should be a bit slower
  norns.enc.sens(1, 5)
end

-- Version management

function _check_launch_version()
  local filename = norns.state.data .. norns.state.shortname
  filename = filename .. "-" .. string.format("%02d",1) .. ".pset"
  local fd = io.open(filename, "r")
  if fd then
    io.close(fd)
    for line in io.lines(filename) do
      if not util.string_starts(line, "--") then
        local id, value = string.match(line, "(\".-\")%s*:%s*(.*)")
        if id and value then
          if id == "\"cyrene_version\"" then
            launch_version = value
          end
        end
      end
    end
  end
end

function _version_gt(a, b)
  if type(a) ~= "string" then return false end
  if type(b) ~= "string" then return true end
  local a_table = {a:match("([^.]+).([^.]+).([^.]+)")}
  local b_table = {b:match("([^.]+).([^.]+).([^.]+)")}
  if a_table == nil or #a_table ~= 3 then return false end
  if b_table == nil or #b_table ~= 3 then return true end
  for i, v in ipairs(a_table) do
    if v > b_table[i] then return true end
    if v < b_table[i] then return false end
  end
  return false
end

function _run_migrations()
  if _version_gt("1.1.-1", launch_version) then
    _upgrade_to_1_1_0()
  end
  if _version_gt("1.2.-1", launch_version) then
    _upgrade_to_1_2_0()
  end
  if _version_gt("1.7.-1", launch_version) then
    _upgrade_to_1_7_0()
  end
  if _version_gt("1.9.-1", launch_version) then
    _upgrade_to_1_9_0()
  end
end

function scandir(directory)
  local i, t = 0, {}
  local pfile = io.popen('ls -a "'..directory..'"')
  if not pfile then return t end
  for filename in pfile:lines() do
    if filename ~= '.' and filename ~= '..' then
      i = i + 1
      t[i] = filename
    end
  end
  pfile:close()
  return t
end

function _rewrite_pset(transform_func)
  local dir = norns.state.data
  local files = scandir(dir)
  for i, local_filename in ipairs(files) do
    local filename = dir .. local_filename
    if filename:sub(-#".pset") == ".pset" then
      local fd = io.open(filename, "r")
      if fd then
        local contents = fd:read("*all")
        local new_contents = transform_func(contents)
        io.close(fd)
        if new_contents then
          fd = io.open(filename,"w+")
          if fd then
            io.output(fd)
            io.write(new_contents)
            io.close(fd)
          end
        end
      end
    end
  end
end

function _upgrade_to_1_1_0()
  _rewrite_pset(function(contents)
    return contents:gsub("\"8_(%S*):%s(%S*)", "")
  end)
end

function _upgrade_to_1_2_0()
  _rewrite_pset(function(contents)
    local old_pattern_length = contents:match("\"pattern_length\": (%d+)")
    if not old_pattern_length then
      return nil
    end
    local new_pattern_length = 16
    if old_pattern_length == "1" then new_pattern_length = 8
    elseif old_pattern_length == "2" then new_pattern_length = 16
    elseif old_pattern_length == "3" then new_pattern_length = 32 end
    return contents:gsub(
      "\"pattern_length\": "..old_pattern_length,
      "\"pattern_length\": "..new_pattern_length
    )
  end)
end

function _upgrade_to_1_6_0()
  arcify:map_encoder_via_params(1, "cy_swing_amount")
  arcify:map_encoder_via_params(2, "cy_grids_pattern_x")
  arcify:map_encoder_via_params(3, "cy_grids_pattern_y")
  arcify:map_encoder_via_params(4, "cy_pattern_chaos")
end

function _upgrade_to_1_7_0()
  _rewrite_pset(function(contents)
    return contents:gsub("audio/common/", "audio/x0x/")
  end)
end

-- Taken from norns/lua/core/paramset.lua
local function unquote(s)
  return s:gsub('^"', ''):gsub('"$', ''):gsub('\\"', '"')
end
local function quote(s)
  return '"'..s:gsub('"', '\\"')..'"'
end

-- Basically, prefix cy_ to everything that is ours
local _version_1_9_0_rename_map = {
  pattern = "cy_pattern",
  pattern_length = "cy_pattern_length",
  grid_resolution = "cy_grid_resolution",
  shuffle_basis = "cy_shuffle_basis",
  shuffle_feel = "cy_shuffle_feel",
  swing_amount = "cy_swing_amount",
  cut_quant = "cy_cut_quant",
  grids_pattern_x = "cy_grids_pattern_x",
  grids_pattern_y = "cy_grids_pattern_y",
  pattern_chaos = "cy_pattern_chaos",
  midi_out = "cy_midi_out",
  crow_out = "cy_crow_out",
  crow_in = "cy_crow_in",
}
for track=1,7 do
  _version_1_9_0_rename_map[track.."_density"] = "cy_"..track.."_density"
  _version_1_9_0_rename_map[track.."_euclidean_enabled"] = "cy_"..track.."_euclidean_enabled"
  _version_1_9_0_rename_map[track.."_euclidean_length"] = "cy_"..track.."_euclidean_length"
  _version_1_9_0_rename_map[track.."_euclidean_trigs"] = "cy_"..track.."_euclidean_trigs"
  _version_1_9_0_rename_map[track.."_euclidean_rotation"] = "cy_"..track.."_euclidean_rotation"
end
for track=1,7 do
  _version_1_9_0_rename_map[track.."_midi_note"] = "cy_"..track.."_midi_note"
  _version_1_9_0_rename_map[track.."_midi_chan"] = "cy_"..track.."_midi_chan"
end
for track=1,4 do
  _version_1_9_0_rename_map["crow_out_"..track.."_track"] = "cy_".."crow_out_"..track.."_track"
  _version_1_9_0_rename_map["crow_out_"..track.."_mode"] = "cy_".."crow_out_"..track.."_mode"
  _version_1_9_0_rename_map["crow_out_"..track.."_attack"] = "cy_".."crow_out_"..track.."_attack"
  _version_1_9_0_rename_map["crow_out_"..track.."_release"] = "cy_".."crow_out_"..track.."_release"
end
for track=1,2 do
  _version_1_9_0_rename_map["crow_in_"..track.."_param"] = "cy_".."crow_in_"..track.."_param"
end

function _upgrade_to_1_9_0()
  _rewrite_pset(function(contents)
    lines = {}
    for s in contents:gmatch("[^\r\n]+") do
      table.insert(lines, s)
    end
    edited_lines = {}
    for i, line in ipairs(lines) do
      if not util.string_starts(line, "--") then
        local id, value = string.match(line, "(\".-\")%s*:%s*(.*)")
        if id and value then
          unquoted_id = unquote(id)
          renamed_id = _version_1_9_0_rename_map[unquoted_id]
          -- Some of our params have other params as their values
          renamed_value = _version_1_9_0_rename_map[value]
          if renamed_id then
            line = line:gsub(id, quote(renamed_id), 1)
          end
          if renamed_value then
            -- TODO: do we need to be worried about the global-ness of this gsub?
            line = line:gsub(value, renamed_value)
          end
        end
      end
      table.insert(edited_lines, line)
    end
    result = ""
    for i, line in ipairs(edited_lines) do
      result = result..line.."\n"
    end
    return result
  end)
end
