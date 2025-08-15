-- Direction constants
local DIRECTIONS = {
  NORTH = 0,
  EAST = 1,
  SOUTH = 2,
  WEST = 3
}

-- Movement events
local EVENTS = {
  MOVE_FORWARD = "move_forward",
  MOVE_BACK = "move_back",
  TURN_LEFT = "turn_left",
  TURN_RIGHT = "turn_right",
  MOVE_UP = "move_up",
  MOVE_DOWN = "move_down",
  POSITION_UPDATE = "position_update",
  CONNECTION_CHECK = "connection_check",
  CONNECTION_RESPONSE = "connection_response",
  BUDDY_REQUEST = "buddy_request",
  BUDDY_RESPONSE = "buddy_response",
  BUDDY_READY = "buddy_ready",
  HEARTBEAT = "heartbeat",
  HEARTBEAT_RESPONSE = "heartbeat_response",
  CLEANUP_STARTED = "cleanup_started",  -- New event for cleanup notification
  FUEL_CHECK = "fuel_check"             -- New event for fuel checks
}

-- Channels
local CHANNELS = {
  DISCOVERY = "discovery",
  COMMAND = "command",
  HEARTBEAT = "heartbeat"
}

-- Find a peripheral by type on any side
local function findPeripheral(peripheralType)
  local sides = {"left", "right", "top", "bottom", "front", "back"}
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) and peripheral.getType(side) == peripheralType then
      return side
    end
  end
  return nil
end

-- Get direction based on coordinate change
local function getDirectionFromMove(x1, z1, x2, z2)
  if x2 > x1 then return DIRECTIONS.EAST
  elseif x2 < x1 then return DIRECTIONS.WEST
  elseif z2 > z1 then return DIRECTIONS.SOUTH
  elseif z2 < z1 then return DIRECTIONS.NORTH
  else return nil
  end
end

-- Get new position after moving in a direction
local function getNewPosition(x, y, z, direction, moveType)
  if moveType == EVENTS.MOVE_FORWARD then
    if direction == DIRECTIONS.NORTH then return x, y, z-1
    elseif direction == DIRECTIONS.EAST then return x+1, y, z
    elseif direction == DIRECTIONS.SOUTH then return x, y, z+1
    elseif direction == DIRECTIONS.WEST then return x-1, y, z
    end
  elseif moveType == EVENTS.MOVE_BACK then
    if direction == DIRECTIONS.NORTH then return x, y, z+1
    elseif direction == DIRECTIONS.EAST then return x-1, y, z
    elseif direction == DIRECTIONS.SOUTH then return x, y, z-1
    elseif direction == DIRECTIONS.WEST then return x+1, y, z
    end
  elseif moveType == EVENTS.MOVE_UP then
    return x, y+1, z
  elseif moveType == EVENTS.MOVE_DOWN then
    return x, y-1, z
  else
    return x, y, z
  end
end

-- Get new direction after turning
local function getNewDirection(currentDirection, turnType)
  if turnType == EVENTS.TURN_LEFT then
    return (currentDirection - 1) % 4
  elseif turnType == EVENTS.TURN_RIGHT then
    return (currentDirection + 1) % 4
  else
    return currentDirection
  end
end

-- Get position behind a turtle based on its direction
local function getPositionBehind(x, y, z, direction, distance)
  if direction == DIRECTIONS.NORTH then return x, y, z+distance
  elseif direction == DIRECTIONS.EAST then return x-distance, y, z
  elseif direction == DIRECTIONS.SOUTH then return x, y, z-distance
  elseif direction == DIRECTIONS.WEST then return x+distance, y, z
  end
end

-- Determine direction of a turtle
local function determineDirection()
  print("Determining position and direction...")
  
  -- Get initial position
  local x1, y1, z1 = gps.locate()
  if not x1 then
    print("Could not get GPS position. Make sure GPS hosts are running.")
    return nil, nil
  end
  
  print("Initial position: " .. x1 .. ", " .. y1 .. ", " .. z1)
  os.sleep(0.5) -- Short delay to ensure GPS reading is stable
  
  -- Try to move forward two blocks for a more significant position change
  local moveDistance = 0
  for i = 1, 2 do
    if turtle.forward() then
      moveDistance = moveDistance + 1
    else
      if i == 1 then
        print("Blocked - cannot determine direction. Please clear path in front of turtle.")
        return nil, nil
      else
        break -- At least moved one block
      end
    end
  end
  
  os.sleep(0.5) -- Wait for GPS to update
  
  -- Get new position
  local x2, y2, z2 = gps.locate()
  if not x2 then
    print("Could not get second GPS position.")
    -- Return to original position
    for i = 1, moveDistance do
      turtle.back()
    end
    return nil, nil
  end
  
  print("Second position: " .. x2 .. ", " .. y2 .. ", " .. z2)
  
  -- Return to original position
  for i = 1, moveDistance do
    turtle.back()
  end
  
  -- Calculate direction
  local detectedDirection = getDirectionFromMove(x1, z1, x2, z2)
  if detectedDirection == nil then
    print("Could not determine direction from coordinates:")
    print("Change in X: " .. (x2 - x1))
    print("Change in Z: " .. (z2 - z1))
    print("Make sure you're not moving vertically.")
    return nil, nil
  end
  
  local dirNames = {"NORTH", "EAST", "SOUTH", "WEST"}
  print("Determined direction: " .. dirNames[detectedDirection + 1])
  
  return {x = x1, y = y1, z = z1}, detectedDirection
end

-- Get a direction name for display
local function getDirectionName(direction)
  local dirNames = {"NORTH", "EAST", "SOUTH", "WEST"}
  return dirNames[direction + 1]
end

-- Find and select an item in turtle's inventory
local function selectItem(itemName)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == itemName then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Function to refuel using ender chest (usable by both miner and buddy)
local function refuelFromEnderChest(fuelThreshold)
  print("Starting refuel sequence...")
  
  -- Set default threshold if not provided
  fuelThreshold = fuelThreshold or 300
  
  -- Check if we even need fuel
  local currentFuel = turtle.getFuelLevel()
  if currentFuel > fuelThreshold then
    print("Fuel level already adequate: " .. currentFuel)
    return true
  end
  
  -- Clear space in front if needed
  if turtle.detect() then
    turtle.dig()
  end
  
  -- Place ender chest in front
  if not selectItem(ITEMS.ENDER_CHEST) then
    print("Error: Could not find ender chest")
    return false
  end
  
  if not turtle.place() then
    print("Error: Could not place ender chest in front")
    return false
  end
  
  print("Ender chest placed in front")
  
  -- Access the ender chest inventory to fill slot 1
  print("Accessing ender chest for fuel...")
  
  turtle.select(1)  -- Ensure we're working with slot 1
  local success = false
  
  -- Try to find and take fuel from ender chest
  for slot = 1, 27 do  -- Ender chest has 27 slots
    if turtle.suck(64) then  -- Try to take up to 64 items from front
      local item = turtle.getItemDetail(1)
      if item then
        -- Check if this is fuel using boolean return
        if turtle.refuel(0) then  -- Returns true if item can be fuel
          print("Found fuel item: " .. item.name .. " (x" .. item.count .. ")")
          success = true
          break
        else
          -- Not fuel, put it back
          turtle.drop()
          print("Item " .. item.name .. " is not fuel, putting back")
        end
      end
    end
  end
  
  if not success then
    print("Error: No fuel found in ender chest!")
    -- Remove ender chest and return failure
    turtle.dig()
    return false
  end
  
  -- Remove ender chest
  turtle.dig()
  print("Ender chest removed")
  
  -- Now fully refuel from slot 1
  turtle.select(1)
  local beforeFuel = turtle.getFuelLevel()
  turtle.refuel()  -- Consume all fuel items in slot 1
  local afterFuel = turtle.getFuelLevel()
  
  print("Refueled: " .. beforeFuel .. " → " .. afterFuel .. " fuel")
  print("Refueling sequence complete!")
  
  return true
end

-- Check and refuel from slot 1 or ender chest if needed
local function checkAndRefuel(fuelThreshold)
  -- Set default threshold if not provided
  fuelThreshold = fuelThreshold or 300
  
  local currentFuel = turtle.getFuelLevel()
  print("Current fuel level: " .. currentFuel)
  
  if currentFuel < fuelThreshold then
    print("Fuel level low! Checking slot 1...")
    turtle.select(1)
    local slot1Item = turtle.getItemDetail(1)
    
    if slot1Item then
      -- Check if slot 1 has fuel
      if turtle.refuel(0) then  -- Returns true if item can be fuel
        local beforeFuel = turtle.getFuelLevel()
        turtle.refuel()  -- Consume fuel from slot 1
        local afterFuel = turtle.getFuelLevel()
        print("Refueled from slot 1: " .. beforeFuel .. " → " .. afterFuel .. " fuel")
        return true
      else
        print("Item in slot 1 is not fuel. Trying ender chest...")
        return refuelFromEnderChest(fuelThreshold)
      end
    else
      print("Slot 1 is empty. Trying ender chest...")
      return refuelFromEnderChest(fuelThreshold)
    end
  else
    print("Fuel level adequate")
    return true
  end
end

-- Replace all GPS functions with local versions
local function initializeGPS()
  print("Initializing GPS coordinates...")
  
  -- Try to get GPS position
  local x, y, z = gps.locate()
  if x then
    print("GPS position acquired: " .. x .. ", " .. y .. ", " .. z)
    return {x = x, y = y, z = z}, true
  else
    print("WARNING: Could not get GPS position.")
    return {x = 0, y = 0, z = 0}, false  -- Return default coordinates and failure flag
  end
end

-- Validate position data - returns true if position has valid coordinates
local function validatePosition(position)
  if not position then return false end
  return position.x ~= nil and position.y ~= nil and position.z ~= nil
end

-- Calculate distance between two positions safely
local function calculateDistance(pos1, pos2)
  -- Validate both positions
  if not validatePosition(pos1) or not validatePosition(pos2) then
    print("WARNING: Invalid positions for distance calculation")
    return 999999  -- Return a large number to indicate invalid distance
  end
  
  -- Calculate Euclidean distance
  return math.sqrt(
    (pos1.x - pos2.x)^2 + 
    (pos1.y - pos2.y)^2 + 
    (pos1.z - pos2.z)^2
  )
end

-- Initialize position and direction - returns position, direction
local function initializeTurtleState()
  local position, success = initializeGPS()
  local direction = nil
  
  -- Determine direction if available
  local _, detectedDirection = determineDirection()
  if detectedDirection ~= nil then
    direction = detectedDirection
    print("Direction determined: " .. getDirectionName(direction))
  else
    print("WARNING: Could not determine direction automatically.")
    direction = DIRECTIONS.NORTH -- Default to North
    print("Using North as default direction")
  end
  
  return position, direction, success
end

return {
  DIRECTIONS = DIRECTIONS,
  EVENTS = EVENTS,
  CHANNELS = CHANNELS,
  ITEMS = ITEMS,
  findPeripheral = findPeripheral,
  getDirectionFromMove = getDirectionFromMove,
  getNewPosition = getNewPosition,
  getNewDirection = getNewDirection,
  getPositionBehind = getPositionBehind,
  determineDirection = determineDirection,
  getDirectionName = getDirectionName,
  selectItem = selectItem,
  refuelFromEnderChest = refuelFromEnderChest,
  checkAndRefuel = checkAndRefuel,
  initializeGPS = initializeGPS,
  validatePosition = validatePosition,
  calculateDistance = calculateDistance,
  initializeTurtleState = initializeTurtleState
}