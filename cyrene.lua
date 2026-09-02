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
-- K2 & K3 switch sections
-- E2 & E3 change values
-- Global pitch, filter,
--  and main output level
-- Hold K3 on section 2
--  to reset all to neutral
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

-- Global filter: a per-octave offset applied on top of each track's own
-- filter cutoff. Cutoff is a frequency, so the offset is multiplicative
-- rather than a flat Hz shift, and each track keeps a "base" cutoff so
-- sweeping to the extremes and back is non-destructive (same approach as
-- the global pitch control).
local global_filter_spec = ControlSpec.new(-36, 36, 'lin', 0, 0, 'st')
-- Each track's unshifted base cutoff lives in a hidden param so that the
-- base, not the derived value, is what gets written to the PSET.
-- params:read() is not silent -- it fires actions as it loads -- so saving
-- the shifted cutoff would apply the offset a second time on load and
-- compound across save/load cycles.
local is_applying_global_filter = false

local function _base_cutoff_id(track) return "cy_" .. track .. "_base_cutoff" end

local function _get_base_cutoff(track)
  local id = _base_cutoff_id(track)
  if params.lookup[id] then return params:get(id) end
  return params:get(track .. "_filter_cutoff")
end

function _apply_global_filter(value)
  local ratio = 2 ^ (value / 12)
  is_applying_global_filter = true
  for track = 1, NUM_TRACKS do
    local cutoff_id = track .. "_filter_cutoff"
    if params.lookup[cutoff_id] then
      local spec = params:lookup_param(cutoff_id).controlspec
      params:set(cutoff_id, util.clamp(_get_base_cutoff(track) * ratio, spec.minval, spec.maxval))
    end
  end
  is_applying_global_filter = false
  UIState.params_dirty = true
  UIState.screen_dirty = true
end

-- A direct edit to a track's cutoff rebases it at the current global offset.
function _track_cutoff_changed(track, value)
  if is_applying_global_filter then return end
  local offset = params.lookup["cy_global_filter"]
    and params:get("cy_global_filter") or 0
  local id = _base_cutoff_id(track)
  if params.lookup[id] then
    params:set(id, value / (2 ^ (offset / 12)), true) -- silent: no re-derive
  end
end

-- PSETs written before the base params existed store the already-shifted
-- cutoff; divide the saved offset back out once so it is not applied twice.
function _migrate_base_cutoffs()
  if params:get("cy_base_cutoffs_saved") == 1 then return end
  local ratio = 2 ^ (params:get("cy_global_filter") / 12)
  for track = 1, NUM_TRACKS do
    local id = _base_cutoff_id(track)
    if params.lookup[id] then
      params:set(id, params:get(track .. "_filter_cutoff") / ratio, true)
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
    params:add_group(group_name, 28)
    -- All the pages together add 5 params per track
    sequencer:add_params_for_track(track, arcify)
    Ack.add_channel_params(track) -- 22 params
    -- Hidden param holding this track's unshifted base cutoff (see above)
    params:add {
      type="control",
      id=_base_cutoff_id(track),
      name=track..": base cutoff",
      controlspec=params:lookup_param(track.."_filter_cutoff").controlspec,
    }
    params:hide(params.lookup[_base_cutoff_id(track)])
    -- Track direct cutoff edits so the global filter stays relative to them
    local ack_cutoff_action = params:lookup_param(track.."_filter_cutoff").action
    params:set_action(track.."_filter_cutoff", function(value)
      ack_cutoff_action(value)
      _track_cutoff_changed(track, value)
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
  -- Marks a PSET as containing the hidden base cutoff params.
  params:add {
    type="number",
    id="cy_base_cutoffs_saved",
    name="Base Cutoffs Saved",
    min=0,
    max=1,
    default=0,
  }
  params:hide(params.lookup["cy_base_cutoffs_saved"])

  params:add_separator("Performance")
  params:add {
    type="control",
    id="cy_global_filter",
    name="Global Filter",
    controlspec=global_filter_spec,
    formatter=function(param)
      return string.format("%+.1f st", param:get())
    end,
    action=function(value) _apply_global_filter(value) end,
  }
  arcify:register("cy_global_filter")
  -- Ack provides a main output level that Cyrene never exposed
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
  _migrate_base_cutoffs()
  params:bang()
  -- Re-derive cutoffs from the saved bases after bang(), so this does not
  -- depend on bang() ordering (ParamSet:bang iterates with pairs()).
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
    params:set("cy_play", 0)
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
