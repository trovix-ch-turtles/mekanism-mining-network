-- Hub Communication Library
-- Standardized functions for communicating with the mining hub

local HUB_CHANNEL = 1337  -- Default hub channel

-- Initialize module
local hubComm = {
  modemSide = nil,
  computerID = os.getComputerID(),
  computerLabel = os.getComputerLabel() or ("Computer_" .. os.getComputerID()),
  registered = false,
  position = {x = 0, y = 0, z = 0},
  cycle = 0,
  phase = "initializing",
  heartbeatTimer = nil,
  buddyStatus = false,  -- Track buddy connection status
  channel = HUB_CHANNEL
}

-- Find modem peripheral
function hubComm.findModem()
  local sides = {"left", "right", "top", "bottom", "front", "back"}
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
      hubComm.modemSide = side
      return peripheral.wrap(side)
    end
  end
  return nil
end

-- Initialize the hub communication
function hubComm.initialize(customChannel)
  -- Allow custom channel if specified
  if customChannel then
    hubComm.channel = customChannel
  end
  
  local modem = hubComm.findModem()
  if not modem then
    print("Warning: No modem found for hub communication")
    return false
  end
  
  modem.open(hubComm.channel)
  print("Hub communication initialized on channel " .. hubComm.channel)
  
  return true
end

-- Register with the hub
function hubComm.register(computerType)
  local modem = peripheral.wrap(hubComm.modemSide)
  if not modem then return false end
  
  -- Get position from GPS if available
  local x, y, z = gps.locate()
  if x then
    hubComm.position = {x = x, y = y, z = z}
  end
  
  -- Send registration message
  local message = {
    type = "register",
    id = hubComm.computerID,
    label = hubComm.computerLabel,
    computerType = computerType or "worker",  -- Default type is worker
    x = hubComm.position.x,
    y = hubComm.position.y,
    z = hubComm.position.z,
    timestamp = os.clock()
  }
  
  modem.transmit(hubComm.channel, hubComm.computerID, textutils.serialise(message))
  print("Sent registration to hub")
  
  -- Wait for acknowledgment
  local timer = os.startTimer(5)
  while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    
    if event == "modem_message" then
      local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
      
      if channel == hubComm.channel then
        local data = textutils.unserialise(message)
        if data and data.type == "register_ack" then
          hubComm.registered = true
          
          -- Update our label if one was assigned
          if data.assignedName then
            hubComm.computerLabel = data.assignedName
            os.setComputerLabel(data.assignedName)
          end
          
          print("Registration acknowledged by hub")
          print("Hub assigned name: " .. hubComm.computerLabel)
          
          -- Start heartbeat AFTER successful registration
          hubComm.startHeartbeat()
          
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
function hubComm.updateStatus(status, cycle, phase, extraData)
  if not hubComm.modemSide then return false end
  
  -- Update local data
  if cycle then hubComm.cycle = cycle end
  if phase then hubComm.phase = phase end
  
  -- Get current position
  local x, y, z = gps.locate()
  if x then
    hubComm.position = {x = x, y = y, z = z}
  end
  
  -- Send status update
  local message = {
    type = "status_update",
    id = hubComm.computerID,
    status = status or "online",
    cycle = hubComm.cycle,
    phase = hubComm.phase,
    x = hubComm.position.x,
    y = hubComm.position.y,
    z = hubComm.position.z,
    fuel = turtle and turtle.getFuelLevel() or nil, -- Only include fuel if it's a turtle
    timestamp = os.clock()
  }
  
  -- Add any extra data fields
  if extraData then
    for k, v in pairs(extraData) do
      message[k] = v
    end
  end
  
  local modem = peripheral.wrap(hubComm.modemSide)
  modem.transmit(hubComm.channel, hubComm.computerID, textutils.serialise(message))
  return true
end

-- Send heartbeat to hub
function hubComm.sendHeartbeat()
  if not hubComm.modemSide then return false end
  
  local data = {
    type = "heartbeat",
    id = hubComm.computerID,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubComm.modemSide)
  modem.transmit(hubComm.channel, hubComm.computerID, textutils.serialise(data))
  return true
end

-- Start heartbeat timer
function hubComm.startHeartbeat(interval)
  -- Set default interval if not provided
  interval = interval or 15
  
  -- Send initial heartbeat
  hubComm.sendHeartbeat()
  
  -- Start the timer
  hubComm.heartbeatTimer = os.startTimer(interval)
  print("Started heartbeat service (interval: " .. interval .. "s)")
  
  return true
end

-- Process heartbeat timer events (call this in the main event loop)
function hubComm.processEvents(event, param)
  if event == "timer" and param == hubComm.heartbeatTimer then
    hubComm.sendHeartbeat()
    hubComm.heartbeatTimer = os.startTimer(15)
    return true
  end
  return false
end

-- Set buddy status
function hubComm.setBuddyStatus(connected)
  hubComm.buddyStatus = connected
  -- Also update the hub
  return hubComm.updateStatus(nil, nil, nil, {hasBuddy = connected})
end

-- Send a log message to the hub
function hubComm.log(message)
  if not hubComm.modemSide then return false end
  
  local data = {
    type = "log",
    id = hubComm.computerID,
    message = message,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubComm.modemSide)
  modem.transmit(hubComm.channel, hubComm.computerID, textutils.serialise(data))
  return true
end

-- Listen for commands from hub
function hubComm.listenForCommands(event, side, channel, replyChannel, message, commandHandler)
  if channel ~= hubComm.channel then return false end
  
  local data = textutils.unserialise(message)
  if data and data.type == "command" and data.id == hubComm.computerID and commandHandler then
    commandHandler(data.command)
    return true
  end
  
  return false
end

return hubComm