--- PerformanceUI
-- @classmod PerformanceUI
--
-- A top-level page for live tweaking of the three global controls:
-- pitch, filter cutoff, and main output level. Each maps to a param so
-- the values are saved, MIDI-mappable, and arcify-able like any other.

local UI = require "ui"
local Label = require("cyrene/lib/ui/util/label")
local UIState = require('cyrene/lib/ui/util/devices')

local active_hi_level = 15
local active_lo_level = 6
local inactive_hi_level = 3
local inactive_lo_level = 1
local font_size = 16
local HOLD_DURATION = 0.7

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
  i.pitch_title_label = Label.new({x=x1, y=y1, text="PITCH", font_size=font_size})
  i.pitch_val_label = Label.new({x=x1, y=y1+val_title_gap, font_size=font_size})
  i.filter_title_label = Label.new({x=x2, y=y1, text="FILTER", font_size=font_size})
  i.filter_val_label = Label.new({x=x2, y=y1+val_title_gap, font_size=font_size})
  i.level_title_label = Label.new({x=x1, y=y2, text="LEVEL", font_size=font_size})
  i.level_val_label = Label.new({x=x1, y=y2+val_title_gap, font_size=font_size})
  i.reset_title_label = Label.new({x=x2, y=y2, text="RESET", font_size=font_size})
  i.reset_val_label = Label.new({x=x2, y=y2+val_title_gap, text="K3 HOLD", font_size=font_size})

  i._section = 0
  i._k3_down_time = nil
  i:_update_active_section()

  return i
end

-- Global pitch lives in its own feature; the page still works without it.
function PerformanceUI:_has_pitch()
  return params.lookup["cy_global_pitch"] ~= nil
end

function PerformanceUI:enc(n, delta, sequencer)
  if self._section == 0 then
    if n == 2 then
      if self:_has_pitch() then
        params:delta("cy_global_pitch", delta)
      end
    elseif n == 3 then
      params:delta("cy_global_filter", delta)
    end
  elseif self._section == 1 then
    if n == 2 then
      params:delta("main_level", delta)
    end
  end
  UIState.screen_dirty = true
end

function PerformanceUI:key(n, z, sequencer)
  -- K3 acts on key-up throughout, because on the second section the action
  -- depends on how long it was held: a hold resets all three globals to
  -- neutral, a short press switches section like it does everywhere else.
  if n == 3 then
    if z == 1 then
      self._k3_down_time = util.time()
      return
    end
    local held = self._k3_down_time and (util.time() - self._k3_down_time) or 0
    self._k3_down_time = nil
    if self._section == 1 and held > HOLD_DURATION then
      if self:_has_pitch() then params:set("cy_global_pitch", 0) end
      params:set("cy_global_filter", 0)
      params:set("main_level", 0)
      UIState.params_dirty = true
      UIState.screen_dirty = true
      return
    end
    self._section = (self._section + 1 + 2) % 2
    self:_update_active_section()
    return
  end
  if n == 2 and z == 0 then
    self._section = (self._section - 1 + 2) % 2
    self:_update_active_section()
  end
end

function PerformanceUI:_update_ui_from_params()
  if self:_has_pitch() then
    self.pitch_val_label.text = string.format("%+.1f", params:get("cy_global_pitch"))
  else
    self.pitch_val_label.text = "--"
  end
  self.filter_val_label.text = string.format("%+d", util.round(params:get("cy_global_filter")))
  self.level_val_label.text = string.format("%+.1f", params:get("main_level"))
end

function PerformanceUI:redraw(sequencer)
  if UIState.params_dirty then
    self:_update_ui_from_params()
  end

  self.pitch_title_label:redraw()
  self.pitch_val_label:redraw()
  self.filter_title_label:redraw()
  self.filter_val_label:redraw()
  self.level_title_label:redraw()
  self.level_val_label:redraw()
  self.reset_title_label:redraw()
  self.reset_val_label:redraw()
end

function PerformanceUI:_update_active_section()
  self.pitch_title_label.level = self._section == 0 and active_lo_level or inactive_lo_level
  self.pitch_val_label.level = self._section == 0 and active_hi_level or inactive_hi_level
  self.filter_title_label.level = self._section == 0 and active_lo_level or inactive_lo_level
  self.filter_val_label.level = self._section == 0 and active_hi_level or inactive_hi_level
  self.level_title_label.level = self._section == 1 and active_lo_level or inactive_lo_level
  self.level_val_label.level = self._section == 1 and active_hi_level or inactive_hi_level
  self.reset_title_label.level = self._section == 1 and active_lo_level or inactive_lo_level
  self.reset_val_label.level = self._section == 1 and active_hi_level or inactive_hi_level
  UIState.screen_dirty = true
end

return PerformanceUI
