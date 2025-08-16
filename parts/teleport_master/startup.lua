-- Teleport Master for Mekanism Mining Network
-- This turtle places teleporters to help players reach miners that are waiting for activation

-- Load libraries
local common = require("lib.common")
local hubComm = require("lib.hub_comm")

-- Configuration
local POLL_INTERVAL = 5  -- How often to check for waiting miners (seconds)

-- State tracking
local currentMiner = nil     -- Current miner we're servicing
local waitingMiners = {}     -- List of miners waiting for activation
local teleporterPlaced = false

-- Request list of waiting miners from hub - custom function needed
local function getWaitingMiners()
  print("Requesting waiting miners from hub...")
  
  local message = {
    type = "request_waiting_miners",
    id = hubComm.computerID,
    timestamp = os.clock()
  }
  
  local modem = peripheral.wrap(hubComm.modemSide)
  modem.transmit(hubComm.channel, hubComm.computerID, textutils.serialise(message))
  
  -- Wait for response
  local timer = os.startTimer(5)
  
  while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    
    if event == "modem_message" then
      local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
      
      if channel == hubComm.channel then
        local data = textutils.unserialise(message)
        if data and data.type == "waiting_miners_response" then
          print("Received " .. #data.miners .. " waiting miners from hub")
          return data.miners
        end
      end
    elseif event == "timer" and p1 == timer then
      print("Request timed out")
      return {}
    end
  end
end

-- Find a teleporter for a specific miner in the turtle's inventory
local function findTeleporterForMiner(minerLabel)
  print("Looking for teleporter for: " .. minerLabel)
  
  -- Check all inventory slots
  for slot = 1, 16 do
    turtle.select(slot)
    local item = turtle.getItemDetail()
    
    -- Check if it's a teleporter with the right name
    if item and item.name == "mekanism:teleporter" then
      -- Check if the display name matches what we need
      if item.displayName and item.displayName:find(minerLabel) then
        print("Found teleporter for " .. minerLabel .. " in slot " .. slot)
        return slot
      end
    end
  end
  
  print("No teleporter found for " .. minerLabel)
  return nil
end

-- Place teleporter for a miner
local function placeTeleporter(minerLabel)
  -- Check if we already have a teleporter placed
  if teleporterPlaced then
    print("Teleporter already placed, removing first...")
    if not removeTeleporter() then
      return false
    end
  end
  
  -- Find teleporter in inventory
  local slot = findTeleporterForMiner(minerLabel)
  if not slot then
    print("ERROR: Teleporter for " .. minerLabel .. " is missing!")
    hubComm.log("ERROR: Missing teleporter for " .. minerLabel)
    
    -- Wait for user to add the teleporter
    print("Please add teleporter and press any key to continue...")
    os.pullEvent("key")
    
    -- Try again
    slot = findTeleporterForMiner(minerLabel)
    if not slot then
      print("Still missing teleporter. Giving up on this miner.")
      return false
    end
  end
  
  -- Select the teleporter
  turtle.select(slot)
  
  -- Clear space above if needed
  if turtle.detectUp() then
    turtle.digUp()
    os.sleep(0.5)
  end
  
  -- Place teleporter
  if not turtle.placeUp() then
    print("Failed to place teleporter")
    return false
  end
  
  print("Placed teleporter for " .. minerLabel)
  hubComm.log("Placed teleporter for " .. minerLabel .. " - Ready for player to visit")
  teleporterPlaced = true
  currentMiner = minerLabel
  return true
end

-- Remove teleporter and put it back in inventory
local function removeTeleporter()
  if not teleporterPlaced then
    return true
  end
  
  -- Select an empty slot if possible
  local emptySlot = nil
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      emptySlot = slot
      break
    end
  end
  
  if emptySlot then
    turtle.select(emptySlot)
  else
    -- If no empty slot, use slot 1
    turtle.select(1)
  end
  
  -- Dig up teleporter
  if turtle.detectUp() then
    turtle.digUp()
  else
    print("Warning: No teleporter found above, but we thought one was placed")
  end
  
  -- Wait a moment for item to be collected
  os.sleep(0.5)
  
  -- Check if we got the teleporter
  local item = turtle.getItemDetail()
  if not item or item.name ~= "mekanism:teleporter" then
    print("Warning: Teleporter not found in inventory after digging")
    teleporterPlaced = false
    currentMiner = nil
    return false
  end
  
  print("Removed teleporter and returned it to inventory")
  hubComm.log("Removed teleporter for " .. (currentMiner or "unknown miner"))
  teleporterPlaced = false
  currentMiner = nil
  return true
end

-- Monitor for miner status changes
local function monitorMinerStatus(minerLabel, minerId)
  print("Monitoring status of miner: " .. minerLabel)
  
  while true do
    -- Request status update from hub
    local message = {
      type = "request_miner_status",
      id = os.getComputerID(),
      minerId = minerId,
      timestamp = os.clock()
    }
    
    -- Fixed: Use proper hubComm reference
    local modem = peripheral.wrap(hubComm.modemSide)
    modem.transmit(hubComm.channel, os.getComputerID(), textutils.serialise(message))
    
    -- Wait for response or timeout
    local timer = os.startTimer(POLL_INTERVAL)
    local statusChanged = false
    
    while not statusChanged do
      local event, p1, p2, p3, p4, p5 = os.pullEvent()
      
      if event == "modem_message" then
        local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
        
        if channel == hubComm.channel then
          local data = textutils.unserialise(message)
          if data and data.type == "miner_status_response" and data.minerId == minerId then
            -- Check if miner is no longer waiting
            if data.status ~= "waiting" or data.phase ~= "waiting_for_miner_start" then
              print("Miner " .. minerLabel .. " is no longer waiting (Status: " .. data.status .. ", Phase: " .. data.phase .. ")")
              return true
            end
            break  -- Status still waiting, break inner loop and set new timer
          end
        end
      elseif event == "timer" and p1 == timer then
        break  -- Timeout, check again
      end
    end
  end
end

-- Process messages from the hub
local function processHubMessages()
  while true do
    local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    
    if channel == hubComm.channel then
      local data = textutils.unserialise(message)
      if not data then
        -- Invalid message
        goto continue
      end
      
      -- Process different message types
      if data.type == "miner_status_update" then
        -- A miner's status has been updated
        local minerId = data.id
        local minerLabel = data.label
        local status = data.status
        local phase = data.phase
        
        print("Status update: " .. minerLabel .. " is now " .. status .. " (" .. phase .. ")")
        
        -- Check if this is our current miner and it's no longer waiting
        if minerLabel == currentMiner and (status ~= "waiting" or phase ~= "waiting_for_miner_start") then
          print("Current miner is no longer waiting, removing teleporter")
          removeTeleporter()
        end
        
        -- Check if a new miner just started waiting
        if status == "waiting" and phase == "waiting_for_miner_start" then
          -- Add to our waiting list if not already there
          local found = false
          for _, miner in ipairs(waitingMiners) do
            if miner.id == minerId then
              found = true
              break
            end
          end
          
          if not found then
            table.insert(waitingMiners, {id = minerId, label = minerLabel})
            print("Added new waiting miner: " .. minerLabel)
          end
        end
      end
      
      ::continue::
    end
  end
end

-- Main loop to manage teleporters for waiting miners
local function manageTeleporters()
  while true do
    -- Get fresh list of waiting miners if we don't have any
    if #waitingMiners == 0 then
      waitingMiners = getWaitingMiners()
    end
    
    -- If we have waiting miners, service the first one
    if #waitingMiners > 0 then
      local miner = table.remove(waitingMiners, 1)
      print("Servicing waiting miner: " .. miner.label)
      
      -- Place teleporter
      if placeTeleporter(miner.label) then
        -- Monitor until miner is no longer waiting
        monitorMinerStatus(miner.label, miner.id)
        
        -- Remove teleporter when done
        removeTeleporter()
      end
    else
      -- No miners waiting, wait a bit before checking again
      print("No miners waiting for activation. Checking again in " .. POLL_INTERVAL .. " seconds.")
      os.sleep(POLL_INTERVAL)
    end
  end
end

-- Main function
local function main()
  print("=== Teleport Master ===")
  print("This turtle manages teleporters for miners waiting to be activated")

  -- Initialize hub communication
  if not hubComm.initialize() then
    print("Warning: Could not initialize hub communication")
  else
    print("Hub communication initialized!")
  end
  
  -- Register with hub
  if not hubComm.register("teleport_master") then
    print("Warning: Failed to register with hub. Will continue anyway.")
  else 
    print("Successfully registered with hub!")
  end
  
  -- Log startup
  hubComm.log("Teleport Master started - Managing teleporters for waiting miners")
  
  -- Start processing messages and managing teleporters in parallel
  parallel.waitForAny(processHubMessages, manageTeleporters)
end

-- Run the program
main()