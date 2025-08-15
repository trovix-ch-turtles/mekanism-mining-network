-- Miner Buddy
local common = require("lib.common")

-- State
local position = {x = nil, y = nil, z = nil}
local direction = nil
local minerId = nil
local minerPosition = {x = nil, y = nil, z = nil}
local minerDirection = nil
local isFollowing = false
local lastHeartbeat = os.clock() -- Timestamp of last heartbeat
local connectionActive = true -- Flag to track active connection

-- Configuration
local HEARTBEAT_INTERVAL = 5 -- Seconds between heartbeats
local MAX_HEARTBEAT_MISS = 3 -- Maximum missed heartbeats before reconnection
local FUEL_THRESHOLD = 1000  -- Minimum fuel before refueling

-- Initialize
local modemSide = common.findPeripheral("modem")
if not modemSide then
  print("No modem found! Please attach a modem.")
  return
end

print("Found modem on " .. modemSide .. " side")
rednet.open(modemSide)

-- Send a single heartbeat
local function sendHeartbeat()
  if minerId then
    rednet.send(minerId, {type = common.EVENTS.HEARTBEAT}, common.CHANNELS.HEARTBEAT)
    print("Sent heartbeat to miner")
  end
end

-- Background tasks for heartbeat monitoring
local function startHeartbeatMonitor()
  -- This function now runs as its own thread to handle heartbeats
  while true do
    if minerId and connectionActive then
      sendHeartbeat()
    end
    os.sleep(HEARTBEAT_INTERVAL)
  end
end

-- Check if all required items are present
local function checkInventory()
  print("Checking inventory for required items...")
  
  local required = {
    {common.ITEMS.ENDER_CHEST, 1}
  }
  
  for _, item in ipairs(required) do
    local count = 0
    for slot = 1, 16 do
      local detail = turtle.getItemDetail(slot)
      if detail and detail.name == item[1] then
        count = count + detail.count
      end
    end
    
    if count < item[2] then
      print("Missing: " .. item[1] .. " (need " .. item[2] .. ", have " .. count .. ")")
      return false
    else
      print("✓ " .. item[1] .. " (have " .. count .. ")")
    end
  end
  
  return true
end

-- Function to handle command messages
local function handleCommand(message
  if message.type == common.EVENTS.CONNECTION_CHECK then
    rednet.send(minerId, {type = common.EVENTS.CONNECTION_RESPONSE}, common.CHANNELS.COMMAND)
    print("Responded to connection check")
  elseif message.type == common.EVENTS.POSITION_UPDATE then
    minerPosition = message.position
    minerDirection = message.direction
    print("Received position update from miner")
    navigateBehindMiner()
  elseif message.type == common.EVENTS.MOVE_FORWARD then
    -- The miner is moving, follow it
    if turtle.forward() then
      local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_FORWARD)
      position = {x = nx, y = ny, z = nz}
      print("Following miner: forward")
    else
      turtle.dig()
      if turtle.forward() then
        local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_FORWARD)
        position = {x = nx, y = ny, z = nz}
      else
        print("Warning: Failed to follow miner forward")
      end
    end
  elseif message.type == common.EVENTS.MOVE_BACK then
    print("Following miner: back")
    if turtle.back() then
      local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_BACK)
      position = {x = nx, y = ny, z = nz}
    end
  elseif message.type == common.EVENTS.MOVE_UP then
    print("Following miner: up")
    if turtle.up() then
      position.y = position.y + 1
    else
      turtle.digUp()
      turtle.up()
      position.y = position.y + 1
    end
  elseif message.type == common.EVENTS.MOVE_DOWN then
    print("Following miner: down")
    if turtle.down() then
      position.y = position.y - 1
    else
      turtle.digDown()
      turtle.down()
      position.y = position.y - 1
    end
  elseif message.type == common.EVENTS.TURN_LEFT then
    print("Following miner: turn left")
    turtle.turnLeft()
    direction = common.getNewDirection(direction, common.EVENTS.TURN_LEFT)
  elseif message.type == common.EVENTS.TURN_RIGHT then
    print("Following miner: turn right")
    turtle.turnRight()
    direction = common.getNewDirection(direction, common.EVENTS.TURN_RIGHT)
  end
end

-- Function to handle all incoming messages
local function messageHandler()
  -- This function runs as its own thread to handle all incoming messages
  while true do
    local id, message, protocol = rednet.receive()
    
    if id == minerId then
      if protocol == common.CHANNELS.HEARTBEAT and message.type == common.EVENTS.HEARTBEAT_RESPONSE then
        lastHeartbeat = os.clock()
        print("Received heartbeat response from miner")
      elseif protocol == common.CHANNELS.HEARTBEAT and message.type == common.EVENTS.HEARTBEAT then
        -- Respond to miner's heartbeat
        rednet.send(minerId, {type = common.EVENTS.HEARTBEAT_RESPONSE}, common.CHANNELS.HEARTBEAT)
        print("Responded to miner heartbeat")
      elseif protocol == common.CHANNELS.COMMAND and message.type == common.EVENTS.CLEANUP_STARTED then
        -- Miner has started cleanup, check our fuel
        print("Miner started cleanup. Checking fuel...")
        common.checkAndRefuel(FUEL_THRESHOLD)
      elseif protocol == common.CHANNELS.COMMAND then
        -- Handle regular command messages
        handleCommand(message)
      elseif protocol == common.CHANNELS.DISCOVERY then
        print("Received discovery message: " .. textutils.serialize(message))
        
        if message.type == common.EVENTS.BUDDY_REQUEST then
          -- Now check if all fields exist
          print("Request validation:")
          print("- Has position: " .. tostring(message.position ~= nil))
          if message.position then
            print("- Has x: " .. tostring(message.position.x ~= nil))
            print("- Has y: " .. tostring(message.position.y ~= nil))
            print("- Has z: " .. tostring(message.position.z ~= nil))
          end
          print("- Has direction: " .. tostring(message.direction ~= nil))
          
          minerId = id
          minerPosition = message.position
          minerDirection = message.direction
          
          print("Found miner at: " .. minerPosition.x .. ", " .. minerPosition.y .. ", " .. minerPosition.z)
          print("Miner direction: " .. common.getDirectionName(minerDirection))
          
          -- Send response
          rednet.send(minerId, {type = common.EVENTS.BUDDY_RESPONSE}, common.CHANNELS.DISCOVERY)
          isConnected = true
          connectionActive = true
          lastHeartbeat = os.clock()
        end
      end
    end
  end
end

-- Check connection with miner
local function checkConnection()
  -- Skip heartbeat check during initial navigation
  if not lastHeartbeat or os.clock() - lastHeartbeat < 2 then
    return true
  end
  
  -- Check if we've missed too many heartbeats
  if os.clock() - lastHeartbeat > HEARTBEAT_INTERVAL * MAX_HEARTBEAT_MISS then
    print("Too many missed heartbeats. Connection lost.")
    connectionActive = false
    return false
  end
  
  connectionActive = true
  return true
end

-- Listen for miner requests
local function listenForMiner()
  print("Listening for miner requests...")
  
  local isConnected = false
  
  while not isConnected do
    -- Listen for incoming requests with a timeout
    local timer = os.startTimer(5)
    
    while not isConnected do
      local event, param1, param2, param3 = os.pullEvent()
      
      if event == "rednet_message" then
        local id, message, protocol = param1, param2, param3
        
        if protocol == common.CHANNELS.DISCOVERY and message.type == common.EVENTS.BUDDY_REQUEST then
          -- Check if the miner is within range (50 blocks)
          local distance = math.sqrt(
            (message.position.x - position.x)^2 +
            (message.position.y - position.y)^2 +
            (message.position.z - position.z)^2
          )
          
          if distance <= 50 then
            minerId = id
            minerPosition = message.position
            minerDirection = message.direction
            
            print("Found miner at: " .. minerPosition.x .. ", " .. minerPosition.y .. ", " .. minerPosition.z)
            print("Miner direction: " .. common.getDirectionName(minerDirection))
            
            -- Send response
            rednet.send(minerId, {type = common.EVENTS.BUDDY_RESPONSE}, common.CHANNELS.DISCOVERY)
            isConnected = true
            connectionActive = true
            lastHeartbeat = os.clock()
            break
          else
            print("Miner found but out of range (" .. distance .. " blocks away)")
          end
        end
      elseif event == "timer" and param1 == timer then
        break -- Timeout, look for miners again
      end
    end
  end
  
  return true
end

-- Navigate to position behind miner
local function navigateBehindMiner()
  print("Navigating to position behind miner...")
  
  local targetX, targetY, targetZ = common.getPositionBehind(
    minerPosition.x, minerPosition.y, minerPosition.z, 
    minerDirection, 4
  )
  
  print("Target position: " .. targetX .. ", " .. targetY .. ", " .. targetZ)
  
  -- Check if already at target position
  local alreadyInPosition = (position.x == targetX and 
                            position.y == targetY and 
                            position.z == targetZ)
  
  if alreadyInPosition then
    print("Already in correct position behind miner!")
  else
    -- Simple pathfinding to target
    while position.x ~= targetX or position.y ~= targetY or position.z ~= targetZ do
      -- Move in X direction
      while position.x < targetX do
        if direction ~= common.DIRECTIONS.EAST then
          if direction == common.DIRECTIONS.WEST then
            turtle.turnRight()
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.NORTH then
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.SOUTH then
            turtle.turnLeft()
          end
          direction = common.DIRECTIONS.EAST
        end
        
        if turtle.forward() then
          position.x = position.x + 1
        else
          turtle.dig()
          if not turtle.forward() then
            print("Failed to move forward after digging")
            os.sleep(0.5)
          else
            position.x = position.x + 1
          end
        end
      end
      
      while position.x > targetX do
        if direction ~= common.DIRECTIONS.WEST then
          if direction == common.DIRECTIONS.EAST then
            turtle.turnRight()
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.NORTH then
            turtle.turnLeft()
          elseif direction == common.DIRECTIONS.SOUTH then
            turtle.turnRight()
          end
          direction = common.DIRECTIONS.WEST
        end
        
        if turtle.forward() then
          position.x = position.x - 1
        else
          turtle.dig()
          if not turtle.forward() then
            print("Failed to move forward after digging")
            os.sleep(0.5)
          else
            position.x = position.x - 1
          end
        end
      end
      
      -- Move in Z direction
      while position.z < targetZ do
        if direction ~= common.DIRECTIONS.SOUTH then
          if direction == common.DIRECTIONS.NORTH then
            turtle.turnRight()
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.EAST then
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.WEST then
            turtle.turnLeft()
          end
          direction = common.DIRECTIONS.SOUTH
        end
        
        if turtle.forward() then
          position.z = position.z + 1
        else
          turtle.dig()
          if not turtle.forward() then
            print("Failed to move forward after digging")
            os.sleep(0.5)
          else
            position.z = position.z + 1
          end
        end
      end
      
      while position.z > targetZ do
        if direction ~= common.DIRECTIONS.NORTH then
          if direction == common.DIRECTIONS.SOUTH then
            turtle.turnRight()
            turtle.turnRight()
          elseif direction == common.DIRECTIONS.EAST then
            turtle.turnLeft()
          elseif direction == common.DIRECTIONS.WEST then
            turtle.turnRight()
          end
          direction = common.DIRECTIONS.NORTH
        end
        
        if turtle.forward() then
          position.z = position.z - 1
        else
          turtle.dig()
          if not turtle.forward() then
            print("Failed to move forward after digging")
            os.sleep(0.5)
          else
            position.z = position.z - 1
          end
        end
      end
      
      -- Move in Y direction
      while position.y < targetY do
        if turtle.up() then
          position.y = position.y + 1
        else
          turtle.digUp()
          if not turtle.up() then
            print("Failed to move up after digging")
            os.sleep(0.5)
          else
            position.y = position.y + 1
          end
        end
      end
      
      while position.y > targetY do
        if turtle.down() then
          position.y = position.y - 1
        else
          turtle.digDown()
          if not turtle.down() then
            print("Failed to move down after digging")
            os.sleep(0.5)
          else
            position.y = position.y - 1
          end
        end
      end
    end
  end
  
  -- Face same direction as miner
  while direction ~= minerDirection do
    turtle.turnRight()
    direction = (direction + 1) % 4
  end
  
  print("Reached position behind miner")
  
  -- Add a small delay before sending ready signal
  -- This ensures the miner is ready to receive it
  print("Waiting 1 second before sending ready signal...")
  os.sleep(1)
  
  -- Signal to miner that we're ready
  rednet.send(minerId, {type = common.EVENTS.BUDDY_READY}, common.CHANNELS.COMMAND)
  print("Sent ready signal to miner")
  
  return true
end

-- Function to safely move forward with error checking
local function safeForward()
  local attempts = 0
  while not turtle.forward() and attempts < 10 do
    if turtle.detect() then
      turtle.dig()
    end
    turtle.attack()
    attempts = attempts + 1
    os.sleep(0.5)
  end
  
  if attempts < 10 then
    -- Update position after successful move
    local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_FORWARD)
    position = {x = nx, y = ny, z = nz}
    return true
  end
  return false
end

-- Function to follow the miner
local function followMiner()
  print("Starting follow operation...")
  
  while true do
    -- Check connection periodically
    if not checkConnection() then
      print("Lost connection to miner. Terminating follow operation.")
      return
    end
    
    -- Main follow loop - mostly waits for commands from the miner
    -- Most movement is driven by message handler responding to commands
    
    -- Periodically check fuel
    if turtle.getFuelLevel() < FUEL_THRESHOLD then
      common.checkAndRefuel(FUEL_THRESHOLD)
    end
    
    os.sleep(1)
  end
end

-- Main function for buddy
local function main()
  print("Initializing buddy turtle...")

  local gpsSuccess = false
  position, direction, gpsSuccess = common.initializeTurtleState()

  if not gpsSuccess then
    print("Warning: Using estimated position. Distance calculations may be inaccurate.")
  end
  
  -- Check for fuel
  if not common.checkAndRefuel(FUEL_THRESHOLD) then
    print("Not enough fuel. Please refuel the turtle.")
    return
  end
  
  -- Find a miner to follow
  if not listenForMiner() then
    print("Failed to find a miner to follow.")
    return
  end


  -- MISSING STEP: Navigate to position behind miner
  print("Moving to position behind miner...")
  if not navigateBehindMiner() then
    print("Failed to navigate behind miner. Aborting operation.")
    return
  end
  
  parallel.waitForAny(
    followMiner,    -- This is your main following function
    
    -- Message handler (handles heartbeats too)
    function()
      while true do
        local id, message, protocol = rednet.receive()
        
        if id == minerId then
          if protocol == common.CHANNELS.COMMAND then
            -- Process command messages
            handleCommand(message)
          elseif protocol == common.CHANNELS.HEARTBEAT then
            -- Just respond to heartbeats, don't send our own
            rednet.send(minerId, {type = common.EVENTS.HEARTBEAT_RESPONSE}, common.CHANNELS.HEARTBEAT)
            lastHeartbeat = os.clock() -- Update last heartbeat time
          end
        end
      end
    end,
    
    -- Connection checker
    function()
      while true do
        -- Check if we've missed too many heartbeats
        if os.clock() - lastHeartbeat > HEARTBEAT_INTERVAL * MAX_HEARTBEAT_MISS then
          print("Lost connection to miner!")
          connectionActive = false
          -- Can terminate the follow operation here if needed
          -- If this happens, the followMiner thread will also detect it via checkConnection()
        end
        os.sleep(HEARTBEAT_INTERVAL)
      end
    end
  )
  
  print("Buddy operation terminated.")
end

-- Run the program
main()