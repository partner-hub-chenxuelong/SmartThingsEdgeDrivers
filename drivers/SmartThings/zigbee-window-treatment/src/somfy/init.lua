-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local capabilities = require "st.capabilities"
local utils = require "st.utils"
local window_shade_utils = require "window_shade_utils"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local WindowCovering = zcl_clusters.WindowCovering

local GLYDEA_MOVE_THRESHOLD = 3


local MOVE_LESS_THAN_THRESHOLD = "_sameLevelEvent"
local FINAL_STATE_POLL_TIMER = "_finalStatePollTimer"

local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30 

local function overwrite_existing_timer_if_needed(device, new_timer)
  local old_timer = device:get_field(FINAL_STATE_POLL_TIMER)
  if old_timer ~= nil then
    device.thread:cancel_timer(old_timer)
  end
  device:set_field(FINAL_STATE_POLL_TIMER, new_timer)
end

local function current_position_attr_handler(driver, device, value, zb_rx)
  -- Somfy Device report as invert value
  local level = 100 - value.value
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  if  latest_target_level ~= nil then
    if utils.round(level) == utils.round(latest_target_level) then
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end
  local current_level = device:get_latest_state(device:get_component_id_for_endpoint(zb_rx.address_header.src_endpoint.value),
    capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
  local windowShade = capabilities.windowShade.windowShade
  local is_conditional_same_level_event = device:get_field(MOVE_LESS_THAN_THRESHOLD)
  -- If user wanted to change shadeLevel by value below acceptable threshold, accept same level event. In every other case, ignore it
  if (current_level == nil or current_level ~= level) or (is_conditional_same_level_event == nil or is_conditional_same_level_event ) then
    device:set_field(MOVE_LESS_THAN_THRESHOLD, false)
    current_level = current_level or 0
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
    local event = nil
    if level == 0 or level == 100 then
      event = level == 0 and windowShade.closed() or windowShade.open()
    elseif current_level ~= level then
      event = current_level < level and windowShade.opening() or windowShade.closing()
      local timer = device.thread:call_with_delay(2, function(d)
        device:set_field(FINAL_STATE_POLL_TIMER, nil)
        local current_level = device:get_latest_state(device:get_component_id_for_endpoint(zb_rx.address_header.src_endpoint.value),
          capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
        if current_level > 0 and current_level < 100 then
          device:emit_event(windowShade.partially_open())
        end
      end
      )
      overwrite_existing_timer_if_needed(device, timer)
    end
    if event ~= nil then
      device:emit_event(event)
    end
  end
end

--[[
 Observation from PKacprowiczS:
	I've been working recently with the device, and I've noticed that when setting a shadeLevel below
	"accepted" threshold (3 +/- currentLevel), it doesn't send any message with level, as it used to
	back then, when I was working on its DTH. Since my current sample has newer firmware, I'm guessing
	that behavior was changed by the manufacturer. Either way, in addition to including additional handler,
	I've also left "DTH style" of handling the scenario, just in case.
--]]
local function movement_ended_handler(driver, device, value, zb_rx)
  local is_conditional_same_level_event = device:get_field(MOVE_LESS_THAN_THRESHOLD)
  if is_conditional_same_level_event == nil or is_conditional_same_level_event then
    device:set_field(MOVE_LESS_THAN_THRESHOLD, false)
    local current_level = device:get_latest_state(device:get_component_id_for_endpoint(zb_rx.address_header.src_endpoint.value),
      capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME) or 0
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(current_level))
  end
end

local function window_shade_level_cmd(driver, device, command)
  local level = utils.clamp_value(command.args.shadeLevel, 0, 100)
  local current_level = device:get_latest_state(command.component, capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME, 0)
  if math.abs(level - current_level) <= GLYDEA_MOVE_THRESHOLD then
    device:set_field(MOVE_LESS_THAN_THRESHOLD, true)
  end
  level = 100 - level
  device:send_to_component(command.component, WindowCovering.server.commands.GoToLiftPercentage(device, level))
end

local function window_shade_preset_cmd(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  command.args.shadeLevel = level
  window_shade_level_cmd(driver, device, command)
end
local function window_shade_step_level_cmd(driver, device, command)
  local step = command.args.stepSize or command.args[1]

  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  local current_level = latest_target_level or
    device:get_latest_state("main", capabilities.windowShadeLevel.ID,
      capabilities.windowShadeLevel.shadeLevel.NAME) or 0

  local target_level = current_level + step
  if target_level > 100 then
    target_level = 100
  elseif target_level < 0 then
    target_level = 0
  end
  target_level = utils.round(target_level)

  device:set_field(LATEST_TARGET_LEVEL, target_level)

  local old_timer = device:get_field(TARGET_LEVEL_TIME_OUT)
  if old_timer ~= nil then
    device.thread:cancel_timer(old_timer)
  end

  local timer = device.thread:call_with_delay(TARGET_LEVEL_TIME_OUT_SECONDS, function(d)
    device:set_field(LATEST_TARGET_LEVEL, nil)
    device:set_field(TARGET_LEVEL_TIME_OUT, nil)
  end)
  device:set_field(TARGET_LEVEL_TIME_OUT, timer)

  local new_command = { args = { shadeLevel = target_level }, component = command.component }
  window_shade_level_cmd(driver, device, new_command)
end

local somfy_handler = {
  NAME = "SOMFY Device Handler",
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd
    },
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = window_shade_step_level_cmd
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_cmd
    },
  },
  zigbee_handlers = {
    attr = {
      [WindowCovering.ID] = {
        [WindowCovering.attributes.CurrentPositionLiftPercentage.ID] = current_position_attr_handler,
        [WindowCovering.attributes.PhysicalClosedLimitLift.ID] = movement_ended_handler
      }
    }
  },
  can_handle = require("somfy.can_handle"),
}

return somfy_handler
