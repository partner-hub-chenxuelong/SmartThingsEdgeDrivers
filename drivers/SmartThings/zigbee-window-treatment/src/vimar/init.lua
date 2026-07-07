-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local capabilities = require "st.capabilities"
local utils = require "st.utils"
local window_shade_utils = require "window_shade_utils"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local WindowCovering = zcl_clusters.WindowCovering
local windowShade = capabilities.windowShade.windowShade

-- VIMAR WINDOW SHADES BEHAVIOR
-- 1. Open/Close/SetToLevel command is invoked normally
-- 2. When shades are moving there is no current position update
-- 3. When shades stops, a new position update is sent with the new lift position

local VIMAR_SHADES_OPENING = "_vimarShadesOpening"
local VIMAR_SHADES_CLOSING = "_vimarShadesClosing"

local utils = require "st.utils"
local LATEST_TARGET_LEVEL = "latest_target_level"
local TARGET_LEVEL_TIME_OUT = "_target_level_timeout"
local TARGET_LEVEL_TIME_OUT_SECONDS = 30 

-- UTILS to check manufacturer details

-- ATTRIBUTE HANDLER FOR CurrentPositionLiftPercentage
local function current_position_attr_handler(driver, device, value, zb_rx)
  -- Shade level is inverted
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
  -- Clear states
  device:set_field(VIMAR_SHADES_CLOSING, false)
  device:set_field(VIMAR_SHADES_OPENING, false)
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))

  -- Assumption: Vimar shades are not moving anymore because the device sent the notification
  local event = nil
  -- Current level is 0 or 100
  if level == 0 or level == 100 then
    event = level == 0 and windowShade.closed() or windowShade.open()
  else
  -- Ignore current_shades_level = level / current_shades_level != level
    device.thread:call_with_delay(2, function(d)
      local current_shades_level = device:get_latest_state(
        device:get_component_id_for_endpoint(zb_rx.address_header.src_endpoint.value),
        capabilities.windowShadeLevel.ID,
        capabilities.windowShadeLevel.shadeLevel.NAME,
        0
      )
      -- Set as partially open
      if current_shades_level > 0 and current_shades_level < 100 then
        device:emit_event(windowShade.partially_open())
      end
    end)
  end
  if event ~= nil then
    device:emit_event(event)
  end
end

-- COMMAND HANDLER for Pause
local function window_shade_pause_handler(driver, device, command)
    device:send_to_component(command.component, WindowCovering.server.commands.Stop(device))
end

-- COMMAND HANDLER for SetLevel
local function window_shade_set_level_handler(driver, device, command)
  local level = utils.clamp_value(command.args.shadeLevel, 0, 100)
  local current_shades_level = device:get_latest_state(command.component, capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME, 0)
  local vimar_opening = device:get_field(VIMAR_SHADES_OPENING)
  local vimar_closing = device:get_field(VIMAR_SHADES_CLOSING)

  -- User wants to change the current level when shades are currently moving
  -- in this case, the roller shutter ignores the command
  if current_shades_level ~= level and (vimar_opening or vimar_closing) then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(current_shades_level))
    return
  end

  if current_shades_level > level then
    device:set_field(VIMAR_SHADES_CLOSING, true)
    device:emit_event(windowShade.closing())
  elseif current_shades_level < level then
    device:set_field(VIMAR_SHADES_OPENING, true)
    device:emit_event(windowShade.opening())
  end

  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))

  level = 100 - level
  device:send_to_component(command.component, WindowCovering.server.commands.GoToLiftPercentage(device, level))
end

-- COMMAND HANDLER for Open
local function window_shade_open_handler(driver, device, command)
  command.args.shadeLevel = 100
  window_shade_set_level_handler(driver, device, command)
end

-- COMMAND HANDLER for Close
local function window_shade_close_handler(driver, device, command)
  command.args.shadeLevel = 0
  window_shade_set_level_handler(driver, device, command)
end

-- COMMAND HANDLER for PresetPosition
local function window_shade_preset_handler(driver, device, command)
  local level = window_shade_utils.get_preset_level(device, command.component)
  command.args.shadeLevel = level
  window_shade_set_level_handler(driver, device, command)
end

-- INIT HANDLER with status checker
local device_init = function(self, device)
  -- Reset Status
  device:set_field(VIMAR_SHADES_CLOSING, false)
  device:set_field(VIMAR_SHADES_OPENING, false)

  -- for windowshadepreset update migration
  if device:supports_capability_by_id(capabilities.windowShadePreset.ID) and
    device:get_latest_state("main", capabilities.windowShadePreset.ID, capabilities.windowShadePreset.position.NAME) == nil then

    -- These should only ever be nil once (and at the same time) for already-installed devices
    -- It can be removed after migration is complete
    device:emit_event(capabilities.windowShadePreset.supportedCommands({"presetPosition", "setPresetPosition"}, { visibility = { displayed = false }}))

    local preset_position = window_shade_utils.get_preset_level(device, "main")

    device:emit_event(capabilities.windowShadePreset.position(preset_position, { visibility = {displayed = false}}))
    device:set_field(window_shade_utils.PRESET_LEVEL_KEY, preset_position, {persist = true})
  end
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

  command.args.shadeLevel = target_level
  window_shade_set_level_handler(driver, device, command)
end
-- DRIVER HANDLER CONFIGURATION
local vimar_handler = {
  NAME = "Vimar Zigbee Window Shades",
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_set_level_handler
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = window_shade_open_handler,
      [capabilities.windowShade.commands.close.NAME] = window_shade_close_handler,
      [capabilities.windowShade.commands.pause.NAME] = window_shade_pause_handler,
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_handler
    },
    [capabilities.statelessWindowShadeLevelStep.ID] = {
      [capabilities.statelessWindowShadeLevelStep.commands.stepShadeLevel.NAME] = window_shade_step_level_cmd
    },
  },
  zigbee_handlers = {
    attr = {
      [WindowCovering.ID] = {
        [WindowCovering.attributes.CurrentPositionLiftPercentage.ID] = current_position_attr_handler
      },
    }
  },
  lifecycle_handlers = {
    init = device_init
  },
  can_handle = require("vimar.can_handle"),
}

return vimar_handler
