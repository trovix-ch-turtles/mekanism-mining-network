-- Miner with Mekanism Mining Setup
local common = require("lib.common")
local hubComm = require("lib.hub_comm") -- Changed from hub_client to lib.hub_comm

-- State
local position = {x = nil, y = nil, z = nil}
local direction = nil
local buddyId = nil
local isMining = false
local isMoving = false -- Flag to indicate when buddy should follow
local lastHeartbeat = os.clock() -- Timestamp of last heartbeat
local cycleCount = 1

-- Configuration
local TEST_MODE = false  -- Set to false for production
local FUEL_THRESHOLD = 1500  -- Minimum fuel before refueling
local HEARTBEAT_INTERVAL = 5 -- Seconds between heartbeats
local MAX_HEARTBEAT_MISS = 3 -- Maximum missed heartbeats before reconnection

-- Item names to search for
local ITEMS = {
    DIGITAL_MINER = "mekanism:digital_miner",
    CONFIG_CARD = "mekanism:configuration_card", 
    TRANSPORTER = "mekanism:ultimate_logistical_transporter",
    TELEPORTER = "mekanism:teleporter",
    QUANTUM_ENTANGLOPORTER = "mekanism:quantum_entangloporter",
    ENDER_CHEST = "enderstorage:ender_chest"
}

-- Initialize
local modemSide = common.findPeripheral("modem")
if not modemSide then
  print("No modem found! Please attach a modem.")
  return
end

print("Found modem on " .. modemSide .. " side")
rednet.open(modemSide)

-- Initialize hub connection
if not hubComm.initialize() then
  print("Warning: Could not initialize hub connection")
else
  -- Register with hub
  if not hubComm.register("worker") then
    print("Warning: Failed to register with hub")
  else
    -- Log successful registration
    hubComm.log("Miner initialized and registered with hub")
  end
end

-- Save current state to file
local function saveState()
  local stateData = {
    cycleCount = cycleCount,
    position = position,
    direction = direction,
    lastHeartbeat = os.clock() - lastHeartbeat -- Store as offset
  }
  
  local file = fs.open("miner_state.data", "w")
  if file then
    file.write(textutils.serialize(stateData))
    file.close()
    print("Saved state: Cycle " .. cycleCount)
    return true
  end
  return false
end

-- Load state from file
local function loadState()
  if not fs.exists("miner_state.data") then
    print("No saved state found")
    return false
  end
  
  local file = fs.open("miner_state.data", "r")
  if not file then
    print("Failed to open state file")
    return false
  end
  
  local content = file.readAll()
  file.close()
  
  local data = textutils.unserialize(content)
  if not data then
    print("Invalid state file")
    return false
  end
  
  -- Restore cycle count
  if data.cycleCount then
    cycleCount = data.cycleCount
    print("Restored cycle count: " .. cycleCount)
  end
  
  -- Restore other state if needed
  if data.position and data.position.x then
    position = data.position
    print("Restored position from file")
  end
  
  if data.direction ~= nil then
    direction = data.direction
    print("Restored direction from file")
  end
  
  return true
end

-- Background tasks for heartbeat
local function startHeartbeatMonitor()
  -- This thread handles sending heartbeats
  while true do
    if buddyId then
      rednet.send(buddyId, {type = common.EVENTS.HEARTBEAT}, common.CHANNELS.HEARTBEAT)
      print("Sent heartbeat to buddy")
    end
    os.sleep(HEARTBEAT_INTERVAL)
  end
end

-- Function to handle all incoming messages
local function messageHandler()
  -- This thread handles all incoming messages
  while true do
    local id, message, protocol = rednet.receive()
    
    if id == buddyId then
      if protocol == common.CHANNELS.HEARTBEAT and message.type == common.EVENTS.HEARTBEAT_RESPONSE then
        lastHeartbeat = os.clock()
        print("Received heartbeat response from buddy")
      elseif protocol == common.CHANNELS.HEARTBEAT and message.type == common.EVENTS.HEARTBEAT then
        -- Respond to buddy's heartbeat
        rednet.send(buddyId, {type = common.EVENTS.HEARTBEAT_RESPONSE}, common.CHANNELS.HEARTBEAT)
        print("Responded to buddy heartbeat")
      elseif protocol == common.CHANNELS.COMMAND and message.type == common.EVENTS.BUDDY_READY then
        print("Buddy is in position and ready!")
      elseif protocol == common.CHANNELS.COMMAND and message.type == common.EVENTS.CONNECTION_RESPONSE then
        print("Buddy connection confirmed")
      end
    end
  end
end

-- Wait for buddy to connect
local function waitForBuddy()
  print("Waiting for buddy to connect...")
  
  -- Update hub with no buddy status
  hubComm.setBuddyStatus(false)
  hubComm.log("Looking for a buddy turtle")
  
  -- Continuously broadcast availability and listen for buddies
  local isConnected = false
  
  while not isConnected do
    -- Broadcast our availability
    print("Broadcasting miner availability...")
    rednet.broadcast({
      type = common.EVENTS.BUDDY_REQUEST, 
      position = position, 
      direction = direction
    }, common.CHANNELS.DISCOVERY)
    
    -- Listen for responses
    local timer = os.startTimer(5)
    
    while not isConnected do
      local event, param1, param2, param3 = os.pullEvent()
      
      if event == "rednet_message" then
        local id, message, protocol = param1, param2, param3
        
        if protocol == common.CHANNELS.DISCOVERY and message.type == common.EVENTS.BUDDY_RESPONSE then
          buddyId = id
          print("Buddy connected with ID: " .. buddyId)
          
          -- Update hub that we found a buddy
          hubComm.setBuddyStatus(true)
          hubComm.log("Connected with buddy turtle ID: " .. buddyId)
          
          -- Wait for buddy to get in position
          print("Waiting for buddy to get in position...")
          local readyReceived = false
          local readyTimer = os.startTimer(30) -- 30 second timeout
          
          while not readyReceived do
            local readyEvent, readyParam1, readyParam2, readyParam3 = os.pullEvent()
            
            if readyEvent == "rednet_message" then
              local readyId, readyMessage, readyProtocol = readyParam1, readyParam2, readyParam3
              
              if readyId == buddyId and readyProtocol == common.CHANNELS.COMMAND and 
                 readyMessage.type == common.EVENTS.BUDDY_READY then
                print("Buddy is in position and ready!")
                hubComm.log("Buddy is in position and ready")
                readyReceived = true
                isConnected = true
              end
            elseif readyEvent == "timer" and readyParam1 == readyTimer then
              print("Timed out waiting for buddy to get ready")
              hubComm.log("Timed out waiting for buddy to get ready")
              break -- Exit the ready wait loop but not the connection loop
            end
          end
          
          if readyReceived then
            break -- Exit the connection loop
          end
        end
      elseif event == "timer" and param1 == timer then
        break -- Timeout, broadcast again
      end
    end
  end
  
  -- Start heartbeat and message handlers
  print("Starting communication handlers...")
  parallel.waitForAny(
    function() return isConnected end,
    startHeartbeatMonitor,
    messageHandler
  )
  
  return true
end

-- Check connection with buddy
local function checkConnection()
  -- Check if we've missed too many heartbeats
  if os.clock() - lastHeartbeat > HEARTBEAT_INTERVAL * MAX_HEARTBEAT_MISS then
    print("Too many missed heartbeats. Connection lost.")
    return false
  end

  -- Perform direct check
  rednet.send(buddyId, {type = common.EVENTS.CONNECTION_CHECK}, common.CHANNELS.COMMAND)
  
  local timer = os.startTimer(2) -- 2-second timeout for response
  local received = false
  
  while not received do
    local event, param1, param2, param3 = os.pullEvent()
    
    if event == "rednet_message" then
      local id, message, protocol = param1, param2, param3
      
      if id == buddyId and protocol == common.CHANNELS.COMMAND and 
         message.type == common.EVENTS.CONNECTION_RESPONSE then
        received = true
      end
    elseif event == "timer" and param1 == timer then
      print("Connection check timed out")
      return false
    end
  end
  
  return true
end

-- Send position update to buddy
local function updateBuddyPosition()
  rednet.send(buddyId, {
    type = common.EVENTS.POSITION_UPDATE,
    position = position,
    direction = direction
  }, common.CHANNELS.COMMAND)
end

-- Movement wrappers that may or may not send commands to buddy based on isMoving flag
local function forward()
  if turtle.forward() then
    local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_FORWARD)
    position = {x = nx, y = ny, z = nz}
    
    -- Only send movement to buddy when in moving mode
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.MOVE_FORWARD}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

local function back()
  if turtle.back() then
    local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_BACK)
    position = {x = nx, y = ny, z = nz}
    
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.MOVE_BACK}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

local function up()
  if turtle.up() then
    local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_UP)
    position = {x = nx, y = ny, z = nz}
    
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.MOVE_UP}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

local function down()
  if turtle.down() then
    local nx, ny, nz = common.getNewPosition(position.x, position.y, position.z, direction, common.EVENTS.MOVE_DOWN)
    position = {x = nx, y = ny, z = nz}
    
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.MOVE_DOWN}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

local function turnLeft()
  if turtle.turnLeft() then
    direction = common.getNewDirection(direction, common.EVENTS.TURN_LEFT)
    
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.TURN_LEFT}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

local function turnRight()
  if turtle.turnRight() then
    direction = common.getNewDirection(direction, common.EVENTS.TURN_RIGHT)
    
    if isMoving then
      rednet.send(buddyId, {type = common.EVENTS.TURN_RIGHT}, common.CHANNELS.COMMAND)
    end
    return true
  end
  return false
end

-- Utility functions from old_miner_script.lua
-- Function to find and select an item in turtle's inventory
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

-- Function to safely move forward with error checking
local function safeForward()
  local attempts = 0
  while not forward() and attempts < 10 do
    if turtle.detect() then
      turtle.dig()
    end
    turtle.attack()
    attempts = attempts + 1
    os.sleep(0.5)
  end
  return attempts < 10
end

-- Function to safely move up with error checking  
local function safeUp()
  local attempts = 0
  while not up() and attempts < 10 do
    if turtle.detectUp() then
      turtle.digUp()
    end
    turtle.attackUp()
    attempts = attempts + 1
    os.sleep(0.5)
  end
  return attempts < 10
end

-- Function to safely move down with error checking
local function safeDown()
  local attempts = 0
  while not down() and attempts < 10 do
    if turtle.detectDown() then
      turtle.digDown()
    end
    turtle.attackDown()
    attempts = attempts + 1
    os.sleep(0.5)
  end
  return attempts < 10
end

-- Function to place item above turtle
local function placeUp(itemName)
  if not selectItem(itemName) then
    print("Error: Could not find " .. itemName)
    return false
  end
  
  -- Clear space above if needed
  if turtle.detectUp() then
    turtle.digUp()
  end
  
  if turtle.placeUp() then
    print("Placed " .. itemName)
    return true
  else
    print("Failed to place " .. itemName)
    return false
  end
end

-- Function to check if slot 1 has fuel and refuel if needed
local function checkAndRefuelSlot1()
  -- Check if slot 1 is empty or has fuel
  turtle.select(1)
  local slot1Item = turtle.getItemDetail(1)
  
  if slot1Item == nil then
    print("Slot 1 is empty! Starting refuel sequence...")
    return common.refuelFromEnderChest(FUEL_THRESHOLD)
  else
    print("Slot 1 has fuel: " .. slot1Item.name .. " (x" .. slot1Item.count .. ")")
    -- Check if what's in slot 1 is fuel
    if turtle.refuel(0) then  -- Returns true if item can be fuel
      turtle.refuel()  -- Consume all fuel in slot 1
      print("Refueled from existing fuel in slot 1")
      return true
    else
      print("Item in slot 1 is not fuel. Trying ender chest...")
      return common.refuelFromEnderChest(FUEL_THRESHOLD)
    end
  end
end

-- Main placement routine
local function setupMiningNetwork()
  print("Starting Mekanism mining setup...")
  hubComm.updateStatus("online", cycleCount, "starting_cycle")
  hubComm.log("Starting mining cycle " .. cycleCount)
  
  -- Step 1: Place digital miner above starting position
  print("Step 1: Placing digital miner...")
  if not placeUp(ITEMS.DIGITAL_MINER) then
    return false
  end
  
  -- Step 2: Move 2 forward, then 1 up
  print("Step 2: Moving 2 forward and 1 up...")
  for i = 1, 2 do
    if not safeForward() then
      print("Error: Could not move forward (step " .. i .. ")")
      return false
    end
  end
  
  if not safeUp() then
    print("Error: Could not move up")
    return false
  end
  
  -- Step 3: Place logistical transporter above and turn left
  print("Step 3: Placing transporter and turning left...")
  if not placeUp(ITEMS.TRANSPORTER) then
    return false
  end
  turnLeft()
  
  -- Step 4: Move forward and place another transporter above twice
  print("Step 4: Moving forward and placing transporters twice...")
  if not safeForward() then
    print("Error: Could not move forward (first)")
    return false
  end
  
  if not placeUp(ITEMS.TRANSPORTER) then
    return false
  end
  
  if not safeForward() then
    print("Error: Could not move forward (second)")
    return false
  end
  
  if not placeUp(ITEMS.TRANSPORTER) then
    return false
  end
  
  -- Step 5: Turn left, move 1 forward and place a transporter above again
  print("Step 5: Turning left, moving forward and placing transporter...")
  turnLeft()
  
  if not safeForward() then
    print("Error: Could not move forward after left turn")
    return false
  end
  
  if not placeUp(ITEMS.TRANSPORTER) then
    return false
  end
  
  -- Step 6: Move 1 forward and build a transporter above
  print("Step 6: Moving forward and placing transporter...")
  if not safeForward() then
    print("Error: Could not move forward")
    return false
  end
  
  if not placeUp(ITEMS.TRANSPORTER) then
    return false
  end
  
  -- Step 7: Move 1 down and build quantum entangloporter above
  print("Step 7: Moving down and placing quantum entangloporter...")
  if not safeDown() then
    print("Error: Could not move down")
    return false
  end
  
  if not placeUp(ITEMS.QUANTUM_ENTANGLOPORTER) then
    return false
  end
  
  -- Step 7.5: Move 1 forward, place teleporter, move 1 back
  print("Step 7.5: Moving forward and placing teleporter...")
  if not safeForward() then
    print("Error: Could not move forward for teleporter placement")
    return false
  end
  
  if not placeUp(ITEMS.TELEPORTER) then
    return false
  end
  
  if not back() then
    print("Error: Could not move back after teleporter placement")
    return false
  end

  -- Step 8: Rotate left (already at correct height)
  print("Step 8: Rotating left...")
  turnLeft()
  
  -- Step 9: Move 2 forward
  print("Step 9: Moving 2 forward...")
  for i = 1, 2 do
    if not safeForward() then
      print("Error: Could not move forward (return step " .. i .. ")")
      return false
    end
  end
  
  -- Step 10: Turn left for proper cleanup orientation, then select the card and place it up
  print("Step 10: Orienting for cleanup and applying configuration card...")
  turnLeft()
  
  if not selectItem(ITEMS.CONFIG_CARD) then
    print("Error: Could not find configuration card")
    return false
  end
  
  if turtle.placeUp() then
    print("Configuration card applied to miner!")
  else
    print("Failed to apply configuration card")
    return false
  end
  
  hubComm.updateStatus("online", cycleCount, "setup")
  hubComm.log("Setting up mining network")
  
  print("Mining setup complete!")
  return true
end

-- Function to clean up the mining network by retracing steps and digging up
local function cleanupMiningNetwork()
  print("Starting cleanup sequence...")
  hubComm.updateStatus("online", cycleCount, "cleanup")
  hubComm.log("Cleaning up mining network")
  
  -- Notify buddy that cleanup is starting (they should check fuel)
  if buddyId then
    rednet.send(buddyId, {type = common.EVENTS.CLEANUP_STARTED}, common.CHANNELS.COMMAND)
    print("Notified buddy of cleanup start")
  end
  
  -- Step 1: Dig up miner above current position
  print("Cleanup Step 1: Removing digital miner...")
  if turtle.detectUp() then
    turtle.digUp()
  end
  
  -- Step 2: Move 2 forward, 1 up - dig up transporter
  print("Cleanup Step 2: Moving to first transporter...")
  for i = 1, 2 do
    if not safeForward() then
      print("Error: Could not move forward during cleanup (step " .. i .. ")")
      return false
    end
  end
  
  if not safeUp() then
    print("Error: Could not move up during cleanup")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed transporter 1")
  end
  
  -- Step 3: Turn left, move forward - dig up transporter
  print("Cleanup Step 3: Removing transporter 2...")
  turnLeft()
  if not safeForward() then
    print("Error: Could not move forward during cleanup")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed transporter 2")
  end
  
  -- Step 4: Move forward - dig up transporter
  print("Cleanup Step 4: Removing transporter 3...")
  if not safeForward() then
    print("Error: Could not move forward during cleanup")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed transporter 3")
  end
  
  -- Step 5: Turn left, move forward - dig up transporter
  print("Cleanup Step 5: Removing transporter 4...")
  turnLeft()
  if not safeForward() then
    print("Error: Could not move forward during cleanup")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed transporter 4")
  end
  
  -- Step 6: Move forward - dig up transporter and quantum entangloporter
  print("Cleanup Step 6: Removing final transporter and quantum entangloporter...")
  if not safeForward() then
    print("Error: Could not move forward during cleanup")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed transporter 5")
  end
  
  -- The quantum entangloporter was placed 1 level down from transporters
  -- So we need to check above us (where we placed it relative to the down position)
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed quantum entangloporter")
  end
  
  -- Step 6.5: Move forward, remove teleporter, move back
  print("Cleanup Step 6.5: Removing teleporter...")
  if not safeForward() then
    print("Error: Could not move forward to remove teleporter")
    return false
  end
  
  if turtle.detectUp() then
    turtle.digUp()
    print("Removed teleporter")
  end
  
  if not back() then
    print("Error: Could not move back after removing teleporter")
    return false
  end
  
  -- Step 7: Return to starting position
  print("Cleanup Step 7: Returning to starting position...")
  turnLeft()
  for i = 1, 2 do
    if not safeForward() then
      print("Error: Could not return to start during cleanup (step " .. i .. ")")
      return false
    end
  end
  
  if not safeDown() then
    print("Error: Could not move down to starting level")
    return false
  end
  
  -- Final orientation for next cycle
  turnLeft()
  print("Oriented for next mining cycle")
  
  print("Cleanup complete! All items removed.")
  return true
end

-- Function to move to next mining location - THIS IS THE PHASE WHERE BUDDY FOLLOWS
local function moveToNext()
  print("Moving to next mining location (70 blocks forward)...")
  
  -- Tell buddy we're starting movement phase
  isMoving = true
  print("Notifying buddy to follow movements...")
  
  -- Make sure buddy is in position before starting movement
  if not checkConnection() then
    print("Connection check failed before movement - updating buddy position")
    updateBuddyPosition()
    waitForBuddy()
  else
    print("Connection with buddy confirmed - beginning movement")
  end
  
  -- Add a small delay to make sure buddy is ready to follow
  os.sleep(1)
  
  for i = 1, 70 do
    -- Check connection every 5 blocks
    if i % 5 == 0 then
      print("Checking connection at block " .. i)
      if not checkConnection() then
        print("Lost connection during movement! Waiting for buddy...")
        updateBuddyPosition()
        waitForBuddy()
      end
    end
    
    -- Print status more frequently
    if i % 5 == 0 then
      print("Moving: " .. i .. "/70 blocks...")
    end
    
    -- Move forward and send movement to buddy
    if not safeForward() then
      print("Error: Could not move forward during relocation (block " .. i .. ")")
      isMoving = false
      return false
    end
    
    -- Short delay between moves to allow buddy to keep up
    os.sleep(0.2)
  end
  
  -- Movement phase complete
  isMoving = false
  print("Reached next mining location!")
  hubComm.updateStatus("online", cycleCount, "moving")
  hubComm.log("Moving to next location")
  return true
end

-- Function to check if all required items are present
local function checkInventory()
  print("Checking inventory for required items...")
  
  local required = {
    {ITEMS.DIGITAL_MINER, 1},
    {ITEMS.CONFIG_CARD, 1},
    {ITEMS.TRANSPORTER, 5},
    {ITEMS.TELEPORTER, 1},
    {ITEMS.QUANTUM_ENTANGLOPORTER, 1},
    {ITEMS.ENDER_CHEST, 1}
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
  
  -- Check what's in slot 1
  turtle.select(1)
  local slot1Item = turtle.getItemDetail(1)
  if slot1Item then
    print("✓ Slot 1 contains: " .. slot1Item.name .. " (x" .. slot1Item.count .. ")")
  else
    print("Note: Slot 1 is empty - will refuel at start of first cycle")
  end
  
  return true
end

-- Create a command handler function
local function handleHubCommand(command)
  print("Received command from hub: " .. command)
  hubComm.log("Received command: " .. command)
  
  if command == "pause_mining" then
    -- Implement pause logic
    hubComm.updateStatus("paused", cycleCount, "paused")
    hubComm.log("Mining paused by hub command")
    
  elseif command == "resume_mining" then
    -- Implement resume logic
    hubComm.updateStatus("online", cycleCount, currentPhase)
    hubComm.log("Mining resumed by hub command")
    
  elseif command == "emergency_stop" then
    -- Implement emergency stop
    hubComm.updateStatus("stopped", cycleCount, "emergency_stopped")
    hubComm.log("EMERGENCY STOP by hub command")
    
  else
    hubComm.log("Unknown command: " .. command)
  end
end

-- Add this to your main event loop/parallel tasks
local function processHubEvents()
  while true do
    local event, param1, param2, param3, param4, param5 = os.pullEvent()
    
    -- Process heartbeat timers
    if hubComm.processEvents(event, param1) then
      -- Heartbeat was processed
    end
    
    -- Process hub commands
    if event == "modem_message" then
      hubComm.listenForCommands(event, param1, param2, param3, param4, handleHubCommand)
    end
  end
end

-- Main execution - infinite mining loop
local function startMiningOperation()
  print("=== Mekanism Mining Turtle Setup ===")
  print("=== INFINITE MINING OPERATION ===")
  
  if TEST_MODE then
    print("*** TEST MODE ENABLED ***")
  end
  
  if not checkInventory() then
    print("Error: Missing required items!")
    return
  end
  
  print("All items found. Starting infinite mining loop in 3 seconds...")
  os.sleep(3)
  
  -- Infinite mining loop
  while true do
    print("\n=== MINING CYCLE " .. cycleCount .. " ===")
    
    -- Phase 0: Check slot 1 and refuel if needed
    print("Phase 0: Checking fuel in slot 1...")
    if not checkAndRefuelSlot1() then
      print("Fuel management failed! Stopping operation.")
      break
    end
    
    -- Phase 1: Setup mining network
    print("Phase 1: Setting up mining network...")
    if not setupMiningNetwork() then
      print("Setup failed! Stopping operation.")
      break
    end
    
    -- Phase 2: Wait for mining operation to complete by monitoring miner state
    print("Phase 2: Mining in progress (monitoring miner state)...")
    hubComm.updateStatus("online", cycleCount, "mining")
    hubComm.log("Mining in progress")
    
     -- Check if miner activated properly
    if not data.state or not data.state.active then
      print("Error: Digital miner is not active! It needs manual activation.")
      hubComm.log("Miner needs manual activation by player")
      
      -- Update hub with waiting state
      hubComm.updateStatus("waiting", cycleCount, "waiting_for_miner_start") 
      hubComm.log("Waiting for player to activate the Digital Miner")
      
      print("Please right-click the Digital Miner and activate it manually.")
      print("Ensure it's configured correctly with the right mining area.")
      print("Press any key after activating the miner...")
      os.pullEvent("key")
      
      -- Verify miner is now active after key press
      success, data = turtle.inspectUp()
      if success and data and data.name == ITEMS.DIGITAL_MINER and data.state and data.state.active then
          print("Digital miner is now active! Monitoring operation...")
          hubComm.updateStatus("online", cycleCount, "mining")
          hubComm.log("Digital miner successfully activated by player")
      else
          print("Miner still not active. Continuing anyway...")
          hubComm.log("WARNING: Proceeding without confirmed miner activation")
      end
    end
    
    print("Digital miner active and running!")
    
    -- Monitor the miner until it completes
    local waitTime = TEST_MODE and 5 or 50000
    local startTime = os.clock()
    local checkInterval = 5  -- Check every 5 seconds
    local lastCheckTime = os.clock()
    local inactiveConfirmations = 0  -- Require multiple inactive readings to confirm completion
    
    while os.clock() - startTime < waitTime do
      -- Process any pending events to stay responsive
      local event, param = os.pullEvent("timer")
      
      -- Time to check miner status?
      if os.clock() - lastCheckTime >= checkInterval then
        local success, data = turtle.inspectUp()
        
        if success and data and data.name == ITEMS.DIGITAL_MINER then
          -- Miner is still there, check its active state
          if data.state and data.state.active == false then
            -- Miner appears inactive, increment confirmation counter
            inactiveConfirmations = inactiveConfirmations + 1
            print("Miner appears inactive (" .. inactiveConfirmations .. "/3 confirmations)")
            
            -- Require 3 consecutive inactive readings to be sure it's done
            if inactiveConfirmations >= 3 then
              print("Digital miner has completed its operation!")
              hubComm.log("Mining operation completed naturally")
              break
            end
          else
            -- Miner is active, reset confirmation counter
            inactiveConfirmations = 0
            
            -- Log status occasionally
            if math.floor((os.clock() - startTime) / 60) % 5 == 0 then
              -- Log every 5 minutes
              hubComm.log("Mining in progress - " .. math.floor((os.clock() - startTime) / 60) .. " minutes elapsed")
            end
          end
        else
          print("Warning: Cannot detect digital miner!")
        end
        
        lastCheckTime = os.clock()
      end
      
      -- Set timer for next check
      os.startTimer(1)  -- Check for events every second
    end
    
        
    -- Phase 2.5: Check fuel level before cleanup
    print("Phase 2.5: Checking fuel level before cleanup...")
    if not common.checkAndRefuel(FUEL_THRESHOLD) then
      print("Fuel level check failed! Stopping operation.")
      break
    end
    
    -- Phase 3: Cleanup mining network
    print("Phase 3: Cleaning up mining network...")
    if not cleanupMiningNetwork() then
      print("Cleanup failed! Stopping operation.")
      break
    end
    
    -- Phase 4: Move to next mining location (Buddy follows this part)
    print("Phase 4: Moving to next location...")
    if not moveToNext() then
      print("Movement to next location failed! Stopping operation.")
      break
    end
    
    print("Cycle " .. cycleCount .. " completed successfully!")
    cycleCount = cycleCount + 1
    
    -- Brief pause between cycles
    os.sleep(1)
  end
  
  print("Mining operation terminated.")
end

-- Main function
local function main()
  print("Initializing mining turtle...")
  
  -- Check for fuel
  if not common.checkAndRefuel(FUEL_THRESHOLD) then
    print("Not enough fuel. Please refuel the turtle.")
    return
  end
  
  -- Initialize hub connection
  if not hubComm.initialize() then
    print("Warning: Could not initialize hub connection")
  else
    -- Register with hub
    if not hubComm.register("worker") then
      print("Warning: Failed to register with hub")
    else
      hubComm.log("Miner initialized and registered with hub")
    end
  end

  -- get current position
  position, direction, gpsSuccess = common.initializeTurtleState()
  if not gpsSuccess then
    print("Warning: Using estimated position. Navigation may be inaccurate.")
  end

  -- Connect with buddy
  if not waitForBuddy() then
    print("Failed to connect with buddy. Mining operation cannot continue.")
    hubComm.log("Failed to connect with buddy. Mining operation aborted.")
    return
  end
  
  -- Run the mining operation in parallel with heartbeat and event handling
  print("Starting mining operation...")
  hubComm.log("Starting mining operation")
  
  parallel.waitForAny(
    startMiningOperation,    -- This is your main mining function
    
    -- Hub event processor
    function()
      while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        
        -- Process heartbeat timers for hub
        if hubComm.processEvents(event, param1) then
          -- Heartbeat was processed
        end
        
        -- Process hub commands
        if event == "modem_message" then
          hubComm.listenForCommands(event, param1, param2, param3, param4, handleHubCommand)
        end
      end
    end,
    
    -- Buddy heartbeat (simplified - only miner sends heartbeats)
    function()
      while true do
        if buddyId then
          rednet.send(buddyId, {type = common.EVENTS.HEARTBEAT}, common.CHANNELS.HEARTBEAT)
        end
        os.sleep(HEARTBEAT_INTERVAL)
      end
    end,
    
    -- Message handler for buddy communication
    function()
      while true do
        local id, message, protocol = rednet.receive()
        
        if id == buddyId then
          -- Handle buddy messages
          if protocol == common.CHANNELS.COMMAND then
            -- Process command messages
          elseif protocol == common.CHANNELS.HEARTBEAT then
            -- Just respond to heartbeats, no need to log every one
            rednet.send(buddyId, {type = common.EVENTS.HEARTBEAT_RESPONSE}, common.CHANNELS.HEARTBEAT)
            lastHeartbeat = os.clock() -- Update last heartbeat time
          end
        end
      end
    end
  )
  
  print("Mining operation terminated.")
end

-- Run the program
main()