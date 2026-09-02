--- PerformanceUI
-- @classmod PerformanceUI
--
-- A top-level page for live tweaking of the global controls: pitch and
-- filter cutoff, mapped to E2 and E3. Both map to params, so the values
-- are saved, MIDI-mappable, and arcify-able like any other.
--
-- K2 and K3 randomize the programmed steps (4-7 and all, respectively).
-- Neither is labelled on screen: they are deliberately undocumented here.

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
  local val_title_gap = font_size - 2
  i.pitch_title_label = Label.new({x=x1, y=y1, text="PITCH", font_size=font_size, level=active_lo_level})
  i.pitch_val_label = Label.new({x=x1, y=y1+val_title_gap, font_size=font_size, level=active_hi_level})
  i.filter_title_label = Label.new({x=x2, y=y1, text="FILTER", font_size=font_size, level=active_lo_level})
  i.filter_val_label = Label.new({x=x2, y=y1+val_title_gap, font_size=font_size, level=active_hi_level})
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
    sequencer:randomize_tracks(n == 3)
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
end

return PerformanceUI
