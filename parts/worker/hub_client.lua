-- Hub Client Module
-- Provides functions for turtles to communicate with the mining hub

local HUB_CHANNEL = 1337  -- Must match the hub channel

-- Initialize module
local hubClient = {
  modemSide = nil,
  turtleId = os.getComputerID(),
  label = os.getComputerLabel() or ("Turtle_" .. os.getComputerID()),
  registered = false,
  position = {x = 0, y = 0, z = 0},
  cycle = 0,
  phase = "initializing",
  heartbeatTimer = nil,
  hasBuddy = false  -- Track buddy connection status
}

-- Find modem peripheral
function hubClient.findModem()
  local sides = {"left", "right", "top", "bottom", "front", "back"}
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
      hubClient.modemSide = side
      return peripheral.wrap(side)
    end
  end
  return nil
end

-- Initialize the hub client
function hubClient.initialize()
  local modem = hubClient.findModem()
  if not modem then
    print("Warning: No modem found for hub communication")
    return false
  end
  
  modem.open(HUB_CHANNEL)
  print("Hub client initialized on channel " .. HUB_CHANNEL)
  
  return true
end

-- Register with the hub
function hubClient.register()
  local modem = peripheral.wrap(hubClient.modemSide)
  if not modem then return false end
  
  -- Get position from GPS if available
  local x, y, z = gps.locate()
  if x then
    hubClient.position = {x = x, y = y, z = z}
  end
  
  -- Send registration message
  local message = {
    type = "register",
    id = hubClient.turtleId,
    label = hubClient.label,
    x = hubClient.position.x,
    y = hubClient.position.y,
    z = hubClient.position.z,
    timestamp = os.clock()
  }
  
  modem.transmit(HUB_CHANNEL, hubClient.turtleId, textutils.serialise(message))
  print("Sent registration to hub")
  
  -- Wait for acknowledgment
  local timer = os.startTimer(5)
  while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    
    if event == "modem_message" then
      local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
      
      if channel == HUB_CHANNEL then
        local data = textutils.unserialise(message)
        if data and data.type == "register_ack" then
          hubClient.registered = true
          
          -- Update our label if one was assigned
          if data.assignedName then
            hubClient.label = data.assignedName
            os.setComputerLabel(data.assignedName)
          end
          
          print("Registration acknowledged by hub")
          print("Hub assigned name: " .. hubClient.label)
          
          -- Start heartbeat AFTER successful registration
          hubClient.startHeartbeat()
          
          return true
        end
      end
    elseif event == "timer" and p1 == timer then
      print("Registration timed out")
      return false
    end
  end
end

-- Update status on the hub
function hubClient.updateStatus(status, cycle, phase, hasBuddy)
  if not hubClient.modemSide then return false end
  
  -- Update local data
  hubClient.cycle = cycle or hubClient.cycle
  hubClient.phase = phase or hubClient.phase
  
  -- Update buddy status if provided
  if hasBuddy ~= nil then
    hubClient.hasBuddy = hasBuddy
  end
  
  -- Get current position
  local x, y, z = gps.locate()
  if x then
    hubClient.position = {x = x, y = y, z = z}
  end
  
  -- Send status update
  local message = {
    type = "status_update",
    id = hubClient.turtleId,
    status = status or "online",
    cycle = hubClient.cycle,
    phase = hubClient.phase,
    x = hubClient.position.x,
    y = hubClient.position.y,
    z = hubClient.position.z,
    fuel = turtle.getFuelLevel(),
    hasBuddy = hubClient.hasBuddy,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubClient.modemSide)
  modem.transmit(HUB_CHANNEL, hubClient.turtleId, textutils.serialise(message))
  return true
end

-- Send heartbeat to hub
function hubClient.sendHeartbeat()
  if not hubClient.modemSide then return false end
  
  local data = {
    type = "heartbeat",
    id = hubClient.turtleId,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubClient.modemSide)
  modem.transmit(HUB_CHANNEL, hubClient.turtleId, textutils.serialise(data))
  return true
end

-- Start heartbeat timer
function hubClient.startHeartbeat()
  -- This function should NOT block with parallel.waitForAny
  -- Instead, we'll just start the timer and return
  hubClient.sendHeartbeat() -- Send initial heartbeat
  hubClient.heartbeatTimer = os.startTimer(15)
  print("Started heartbeat service")
end

-- Process heartbeat timer events (call this in the main event loop)
function hubClient.processEvents(event, param)
  if event == "timer" and param == hubClient.heartbeatTimer then
    hubClient.sendHeartbeat()
    hubClient.heartbeatTimer = os.startTimer(15)
    return true
  end
  return false
end

-- Set buddy status
function hubClient.setBuddyStatus(connected)
  hubClient.hasBuddy = connected
  -- Also update the hub
  return hubClient.updateStatus()
end

-- Send a log message to the hub
function hubClient.log(message)
  if not hubClient.modemSide then return false end
  
  local data = {
    type = "log",
    id = hubClient.turtleId,
    message = message,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubClient.modemSide)
  modem.transmit(HUB_CHANNEL, hubClient.turtleId, textutils.serialise(data))
  return true
end

-- Listen for commands from hub
function hubClient.listenForCommands(event, side, channel, replyChannel, message, commandHandler)
  if channel ~= HUB_CHANNEL then return false end
  
  local data = textutils.unserialise(message)
  if data and data.type == "command" and commandHandler then
    commandHandler(data.command)
    return true
  end
  
  return false
end

return hubClient