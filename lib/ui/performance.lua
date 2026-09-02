--- PerformanceUI
-- @classmod PerformanceUI
--
-- A top-level page for live tweaking of the global controls: pitch and
-- filter cutoff, mapped to E2 and E3. Both map to params, so the values
-- are saved, MIDI-mappable, and arcify-able like any other.
--
-- K2 randomizes tracks 4-7; K3 randomizes all tracks including the drums.

local UI = require "ui"
local Label = require("cyrene/lib/ui/util/label")
local UIState = require('cyrene/lib/ui/util/devices')

local active_hi_level = 15
local active_lo_level = 6
local font_size = 16

local PerformanceUI = {}

function PerformanceUI:new()
  i = {}
  setmetatable(i, self)
  self.__index = self

  local x1 = 4
  local x2 = 68
  local y1 = 14
  local y2 = 49
  local val_title_gap = font_size - 2
  i.pitch_title_label = Label.new({x=x1, y=y1, text="PITCH", font_size=font_size, level=active_lo_level})
  i.pitch_val_label = Label.new({x=x1, y=y1+val_title_gap, font_size=font_size, level=active_hi_level})
  i.filter_title_label = Label.new({x=x2, y=y1, text="FILTER", font_size=font_size, level=active_lo_level})
  i.filter_val_label = Label.new({x=x2, y=y1+val_title_gap, font_size=font_size, level=active_hi_level})
  i.random_title_label = Label.new({x=x1, y=y2, text="RANDOM", font_size=font_size, level=active_lo_level})
  i.random_val_label = Label.new({x=x1, y=y2+val_title_gap, text="K2 4-7", font_size=font_size, level=active_hi_level})
  i.random_all_label = Label.new({x=x2, y=y2+val_title_gap, text="K3 ALL", font_size=font_size, level=active_hi_level})

  i._last_stage = nil
  i._last_scope = nil
  i._randomized_count = nil
  i._stage_count = 4 -- overwritten from the sequencer on first randomize
  i._labels_dirty = true

  return i
end

-- Global pitch lives in its own feature; the page still works without it.
function PerformanceUI:_has_pitch()
  return params.lookup["cy_global_pitch"] ~= nil
end

function PerformanceUI:enc(n, delta, sequencer)
  if n == 2 then
    if self:_has_pitch() then
      params:delta("cy_global_pitch", delta)
    end
  elseif n == 3 then
    params:delta("cy_global_filter", delta)
  end
  UIState.screen_dirty = true
end

function PerformanceUI:key(n, z, sequencer)
  -- K2 randomizes only the tracks Cyrene does not generate; K3 also takes
  -- over the kick, snare and hat, holding the Grids drum map off them.
  if (n == 2 or n == 3) and z == 1 then
    local include_drum_tracks = (n == 3)
    local stage, randomized = sequencer:randomize_tracks(include_drum_tracks)
    self._last_stage = stage
    self._randomized_count = randomized
    self._last_scope = include_drum_tracks and "ALL" or "4-7"
    self._stage_count = sequencer:randomize_stage_count()
    self._labels_dirty = true
    UIState.screen_dirty = true
  end
end

function PerformanceUI:_update_ui_from_params()
  if self:_has_pitch() then
    self.pitch_val_label.text = string.format("%+.1f", params:get("cy_global_pitch"))
  else
    self.pitch_val_label.text = "--"
  end
  self.filter_val_label.text = string.format("%+d", util.round(params:get("cy_global_filter")))
  if self._last_stage == nil then
    -- Nothing randomized yet: show the key hints
    self.random_val_label.text = "K2 4-7"
    self.random_all_label.text = "K3 ALL"
  elseif self._randomized_count == 0 then
    -- Every track in scope is euclidean, so there was nothing to do
    self.random_val_label.text = "NONE"
    self.random_all_label.text = ""
  else
    self.random_val_label.text = self._last_scope
    self.random_all_label.text = self._last_stage .. "/" .. self._stage_count
  end
end

function PerformanceUI:redraw(sequencer)
  if UIState.params_dirty or self._labels_dirty then
    self._labels_dirty = false
    self:_update_ui_from_params()
  end

  self.pitch_title_label:redraw()
  self.pitch_val_label:redraw()
  self.filter_title_label:redraw()
  self.filter_val_label:redraw()
  self.random_title_label:redraw()
  self.random_val_label:redraw()
  self.random_all_label:redraw()
end

return PerformanceUI
