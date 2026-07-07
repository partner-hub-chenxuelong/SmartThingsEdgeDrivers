-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local zcl_global_commands = require "st.zigbee.zcl.global_commands"
local Status = require "st.zigbee.generated.types.ZclStatus"
local WindowCovering = zcl_clusters.WindowCovering
local window_shade_utils = require "window_shade_utils"

local device_management = require "st.zigbee.device_management"

local LEVEL_UPDATE_TIMEOUT = "__level_update_timeout"
local MOST_RECENT_SETLEVEL = "__most_recent_setlevel"

local utils = require "st.utils"
local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30 

local function default_response_handler(driver, device, zb_message)
  local is_success = zb_message.body.zcl_body.status.value
  local command = zb_message.body.zcl_body.cmd.value

  if is_success == Status.SUCCESS and command == WindowCovering.server.commands.GoToLiftPercentage.ID then
    local current_level = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
    if current_level then current_level = 100 - current_level end -- convert to the zigbee value
    local most_recent_setlevel = device:get_field(MOST_RECENT_SETLEVEL)
    if current_level and most_recent_setlevel and current_level ~= most_recent_setlevel then
      if current_level > most_recent_setlevel then
        device:emit_event(capabilities.windowShade.windowShade.opening())
      else
        device:emit_event(capabilities.windowShade.windowShade.closing())
      end
    end
  end
end

local function set_shade_level(driver, device, value, command)
  local level = 100 - value
  device:send_to_component(command.component, WindowCovering.server.commands.GoToLiftPercentage(device, level))
  device:set_field(MOST_RECENT_SETLEVEL, level) -- set the value to the zigbee protocol value

  local timer = device:get_field(LEVEL_UPDATE_TIMEOUT)
  if timer then
    device.thread.cancel_timer(timer)
  end
  timer = device.thread:call_with_delay(30, function ()
    -- for some reason the device isn't updating us about its state so we'll send another bind request
    device:send(device_management.build_bind_request(device, WindowCovering.ID, driver.environment_info.hub_zigbee_eui))
    device:send(WindowCovering.attributes.CurrentPositionLiftPercentage:configure_reporting(device, 0, 600, 1))
    device:send_to_component(command.component, WindowCovering.attributes.CurrentPositionLiftPercentage:read(device))
    device:set_field(LEVEL_UPDATE_TIMEOUT, nil)
  end)
  device:set_field(LEVEL_UPDATE_TIMEOUT, timer)
end

local function window_shade_level_cmd(driver, device, command)
  set_shade_level(driver, device, command.value, command)
end

local function window_shade_preset_cmd(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  set_shade_level(driver, device, level, command)
end

local function set_window_shade_level(level)
  return function(driver, device, cmd)
    set_shade_level(driver, device, level, cmd)
  end
end

local function current_position_attr_handler(driver, device, value, zb_rx)
  local current_level = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
  
  local latest_target_level = device:get_field(LATEST_TARGET_LEVEL)
  if  latest_target_level ~= nil then
    if utils.round(current_level) == utils.round(latest_target_level) then
      device:set_field(LATEST_TARGET_LEVEL, nil)
      local timer = device:get_field(TARGET_LEVEL_TIME_OUT)
      if timer ~= nil then
        device.thread:cancel_timer(timer)
        device:set_field(TARGET_LEVEL_TIME_OUT, nil)
      end
    end
  end

  if current_level then current_level = 100 - current_level end -- convert to the zigbee value

  if value.value == 0 then
    device:emit_event(capabilities.windowShade.windowShade.open())
  elseif value.value == 100 then
    device:emit_event(capabilities.windowShade.windowShade.closed())
  elseif current_level == nil then
    -- our first level change to a non-open/closed value
    device:emit_event(capabilities.windowShade.windowShade.partially_open())
  end

  local most_recent_setlevel = device:get_field(MOST_RECENT_SETLEVEL)
  if most_recent_setlevel and value.value == most_recent_setlevel then
    -- this is a report matching our most recent set level command, assume we've stopped
    device:set_field(MOST_RECENT_SETLEVEL, nil)
    if value.value ~= 0 and value.value ~= 100 then
      device:emit_event(capabilities.windowShade.windowShade.partially_open())
    end
    local timer = device:get_field(LEVEL_UPDATE_TIMEOUT)
    if timer then
      device.thread:cancel_timer(timer)
      device:set_field(LEVEL_UPDATE_TIMEOUT, nil)
    end
  elseif most_recent_setlevel == nil then
    -- this is a spontaneous level change
    if current_level and current_level ~= value.value then
      if current_level > value.value then
        device:emit_event(capabilities.windowShade.windowShade.opening())
      else
        device:emit_event(capabilities.windowShade.windowShade.closing())
      end
      device.thread:call_with_delay(2, function()
        -- if we don't have a changed level value within the next 2s, assume we've stopped moving
        local current_level_now = device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
        if current_level_now then current_level_now = 100 - current_level_now end -- convert to the zigbee value
        if current_level_now == value.value and current_level_now ~= 0 and current_level_now ~= 100 then
          device:emit_event(capabilities.windowShade.windowShade.partially_open())
        end
      end)
    end
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(100 - value.value))
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

  set_shade_level(driver, device, target_level, command)
end

local yoolax_window_shade = {
  NAME = "yoolax window shade",
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd,
      [capabilities.windowShade.commands.open.NAME] = set_window_shade_level(100), -- a report of 0 = open
      [capabilities.windowShade.commands.close.NAME] = set_window_shade_level(0), -- a report of 100 = closed
    },
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = window_shade_step_level_cmd
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_cmd
    }
  },
  zigbee_handlers = {
    attr = {
      [WindowCovering.ID] = {
        [WindowCovering.attributes.CurrentPositionLiftPercentage.ID] = current_position_attr_handler
      }
    },
    global = {
      [WindowCovering.ID] = {
        [zcl_global_commands.DEFAULT_RESPONSE_ID] = default_response_handler
      }
    },
  },
  can_handle = require("yoolax.can_handle"),
}

return yoolax_window_shade
