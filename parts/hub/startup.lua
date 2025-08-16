-- Mekanism Mining Hub Control Script (Simplified)
-- Central control system for managing multiple mining turtles
-- Requires: Advanced Computer + Monitor + Ender Modem
local common = require("lib.common")
-- Configuration
local CHANNEL = 1337  -- Communication channel for turtle network
local HUB_ID = "MINING_HUB"
local DATA_FILE = "hub_data.json"  -- File to store turtle data
local SAVE_INTERVAL = 30  -- Save data every 30 seconds
local AUTO_NAME_PREFIX = "MINER"  -- Prefix for auto-generated names
local autoNameCounter = 1  -- Counter for auto-generated names

-- Global variables
local turtles = {}  -- Table to store turtle information
local selectedTurtle = nil  -- Currently selected turtle
local detailsExpanded = false  -- Whether details are currently shown
local lastSave = 0  -- Track last save time
local monitor = nil
local modem = nil
local MONITOR_SIDE = nil  -- Will be detected automatically
local MODEM_SIDE = nil    -- Will be detected automatically
local running = true

-- Colors for UI (using global colors API)
local uiColors = {
    background = colors.black,
    header = colors.blue,
    text = colors.white,
    selected = colors.green,
    offline = colors.red,
    online = colors.lime,
    warning = colors.yellow,
    waiting = colors.orange,
    border = colors.gray,
    accent = colors.cyan
}

-- Turtle data structure with pairing support
function createTurtleEntry(id, label, x, y, z, computerType)
    return {
        id = id,
        label = label or ("Turtle_" .. id),
        x = x or 0,
        y = y or 0, 
        z = z or 0,
        status = "online",
        lastSeen = os.clock(),
        logs = {},
        cycle = 0,
        fuel = 0,
        phase = "unknown",
        inventory = {},
        customData = {},  -- Store custom data from turtle
        turtleType = computerType or "worker",  -- Use the provided computerType
        pairedWith = nil,  -- ID of paired turtle
        needsCompanion = false,  -- Whether this turtle needs a companion
        isHidden = computerType == "teleport_master"  -- Hide teleport masters from main display
    }
end

-- Save turtle data to file
function saveTurtleData()
    local dataToSave = {
        turtles = {},
        timestamp = os.clock(),
        hubId = HUB_ID,
        autoNameCounter = autoNameCounter  -- Save the counter
    }
    
    -- Copy turtle data (excluding logs to keep file size manageable)
    for id, turtle in pairs(turtles) do
        dataToSave.turtles[id] = {
            id = turtle.id,
            label = turtle.label,
            x = turtle.x,
            y = turtle.y,
            z = turtle.z,
            status = "offline",  -- Mark as offline until reconnection
            lastSeen = turtle.lastSeen,
            cycle = turtle.cycle,
            fuel = turtle.fuel,
            phase = turtle.phase,
            logs = {}  -- Don't save logs to keep file small
        }
    end
    
    local file = fs.open(DATA_FILE, "w")
    if file then
        file.write(textutils.serialise(dataToSave))
        file.close()
        return true
    end
    return false
end

-- Load turtle data from file
function loadTurtleData()
    if not fs.exists(DATA_FILE) then
        print("No previous turtle data found")
        return false
    end
    
    local file = fs.open(DATA_FILE, "r")
    if not file then
        print("Failed to open turtle data file")
        return false
    end
    
    local content = file.readAll()
    file.close()
    
    local data = textutils.unserialise(content)
    if not data or not data.turtles then
        print("Invalid turtle data file")
        return false
    end
    
    -- Restore auto name counter
    autoNameCounter = data.autoNameCounter or 1
    
    -- Restore turtle data
    local loadedCount = 0
    for id, turtleData in pairs(data.turtles) do
        turtles[tonumber(id)] = createTurtleEntry(
            turtleData.id,
            turtleData.label,
            turtleData.x,
            turtleData.y,
            turtleData.z
        )
        
        -- Restore additional data
        local turtle = turtles[tonumber(id)]
        turtle.status = "offline"  -- Start as offline until they reconnect
        turtle.lastSeen = turtleData.lastSeen or 0
        turtle.cycle = turtleData.cycle or 0
        turtle.fuel = turtleData.fuel or 0
        turtle.phase = turtleData.phase or "unknown"
        
        -- Add a log entry about restoration
        addTurtleLog(tonumber(id), "Restored from previous session (waiting for reconnection)")
        
        loadedCount = loadedCount + 1
    end
    
    print("Loaded " .. loadedCount .. " turtles from previous session")
    print("Auto-name counter restored to: " .. autoNameCounter)
    return true
end

-- Broadcast discovery message with new protocol
function broadcastDiscovery()
    if not modem then return end
    
    local discoveryMessage = {
        type = "hub_discovery",
        id = tostring(os.clock()),
        from = "hub",
        timestamp = os.clock(),
        data = {
            hubId = HUB_ID,
            channel = CHANNEL,
            message = "Hub restarted - please re-register"
        }
    }
    
    modem.transmit(CHANNEL, CHANNEL, textutils.serialise(discoveryMessage))
    print("Broadcasted discovery message to all turtles")
end

-- Periodic save function
function handlePeriodicSave()
    local currentTime = os.clock()
    if currentTime - lastSave >= SAVE_INTERVAL then
        if saveTurtleData() then
            -- Only print save message if we have turtles to save
            if table.getn(turtles) > 0 then
                print("Auto-saved turtle data (" .. table.getn(turtles) .. " turtles)")
            end
        end
        lastSave = currentTime
    end
end

-- Initialize hardware connections
function initializeHardware()
    print("Initializing hardware...")
    
    -- Auto-detect monitor
    MONITOR_SIDE = common.findPeripheral("monitor")
    if MONITOR_SIDE then
        monitor = peripheral.wrap(MONITOR_SIDE)
        if monitor then
            monitor.setTextScale(1.0)  -- Larger text (was 0.5)
            print("✓ Monitor connected on " .. MONITOR_SIDE .. " side")
        else
            error("Failed to wrap monitor")
        end
    else
        error("No monitor found on any side")
    end
    
    -- Auto-detect modem
    MODEM_SIDE = common.findPeripheral("modem")
    if MODEM_SIDE then
        modem = peripheral.wrap(MODEM_SIDE)
        if modem then
            modem.open(CHANNEL)
            print("✓ Ender modem connected on " .. MODEM_SIDE .. " side")
        else
            error("Failed to wrap modem")
        end
    else
        error("No ender modem found on any side")
    end
    
    print("Hardware initialization complete!")
end

-- Add log entry to turtle
function addTurtleLog(turtleId, message)
    if turtles[turtleId] then
        local timestamp = os.date("%H:%M:%S")
        table.insert(turtles[turtleId].logs, {
            time = timestamp,
            message = message
        })
        
        -- Keep only last 100 log entries
        if #turtles[turtleId].logs > 100 then
            table.remove(turtles[turtleId].logs, 1)
        end
        
        turtles[turtleId].lastSeen = os.clock()
    end
end

-- Handle incoming messages from turtles
function handleTurtleMessage(message, senderId)
    local data = textutils.unserialise(message)
    if not data then return end
    
    if data.type == "register" then
        local computerType = data.computerType or "worker"
        local assignedName = ""
        
        -- Use different naming scheme based on computer type
        if computerType == "teleport_master" then
            assignedName = "TELEPORT_MASTER"
        else
            -- Regular miner naming scheme
            assignedName = AUTO_NAME_PREFIX .. autoNameCounter
            autoNameCounter = autoNameCounter + 1  -- Increment counter only for miners
        end
        
        -- New turtle registration
        turtles[senderId] = createTurtleEntry(
            senderId,
            assignedName,
            data.x, data.y, data.z,
            computerType  -- Pass the computer type to createTurtleEntry
        )
        
        addTurtleLog(senderId, computerType .. " registered with hub as: " .. assignedName)
        
        -- Send acknowledgment with assigned name
        modem.transmit(CHANNEL, CHANNEL, textutils.serialise({
            type = "register_ack",
            hubId = HUB_ID,
            assignedName = assignedName,
            timestamp = os.clock()
        }))
        
    elseif data.type == "status_update" then
        -- Status update from existing turtle
        if turtles[senderId] then
            -- Store previous status and phase to detect changes
            local prevStatus = turtles[senderId].status
            local prevPhase = turtles[senderId].phase
            
            -- Update turtle data
            turtles[senderId].status = data.status or "online"
            turtles[senderId].cycle = data.cycle or 0
            turtles[senderId].fuel = data.fuel or 0
            turtles[senderId].phase = data.phase or "unknown"
            turtles[senderId].x = data.x or turtles[senderId].x
            turtles[senderId].y = data.y or turtles[senderId].y
            turtles[senderId].z = data.z or turtles[senderId].z
            turtles[senderId].lastSeen = os.clock()
            
            -- Broadcast status change ONLY when it's related to waiting for miner start
            if (prevPhase ~= "waiting_for_miner_start" and turtles[senderId].phase == "waiting_for_miner_start") or
                (prevPhase == "waiting_for_miner_start" and turtles[senderId].phase ~= "waiting_for_miner_start") then
                modem.transmit(CHANNEL, CHANNEL, textutils.serialise({
                    type = "miner_status_update",
                    id = senderId,
                    label = turtles[senderId].label,
                    status = turtles[senderId].status,
                    phase = turtles[senderId].phase,
                    timestamp = os.clock()
                }))
            end
        end
        
    elseif data.type == "log" then
        -- Log message from turtle
        addTurtleLog(senderId, data.message)
        
    elseif data.type == "heartbeat" then
        -- Keep-alive signal
        if turtles[senderId] then
            turtles[senderId].lastSeen = os.clock()
        end
    elseif data.type == "request_waiting_miners" then
        -- Get a list of all waiting miners
        local waitingMiners = {}
        for id, turtle in pairs(turtles) do
            if turtle.status == "waiting" and turtle.phase == "waiting_for_miner_start" then
                table.insert(waitingMiners, {
                    id = id,
                    label = turtle.label
                })
            end
        end
        
        -- Send response back to the requesting turtle
        modem.transmit(CHANNEL, senderId, textutils.serialise({
            type = "waiting_miners_response",
            miners = waitingMiners,
            timestamp = os.clock()
        }))
        
    elseif data.type == "request_miner_status" then
        -- Get status for a specific miner
        local minerId = data.minerId
        local response = {
            type = "miner_status_response",
            minerId = minerId,
            timestamp = os.clock()
        }
        
        if turtles[minerId] then
            response.status = turtles[minerId].status
            response.phase = turtles[minerId].phase
            response.label = turtles[minerId].label
        else
            response.status = "unknown"
            response.phase = "unknown"
        end
        
        -- Send response back to the requesting turtle
        modem.transmit(CHANNEL, senderId, textutils.serialise(response))
    end
end

-- Check for offline turtles
function checkTurtleStatus()
    local currentTime = os.clock()
    for id, turtle in pairs(turtles) do
        if currentTime - turtle.lastSeen > 30 then  -- 30 seconds timeout
            turtle.status = "offline"
        end
    end
end

-- Draw header on monitor
function drawHeader()
    local w, h = monitor.getSize()
    
    -- Clear header area and add space
    monitor.setBackgroundColor(uiColors.background)
    monitor.clear()
    
    -- Empty row for spacing
    monitor.setCursorPos(1, 1)
    monitor.clearLine()
    
    -- Main title row - make it stand out
    monitor.setCursorPos(1, 2)
    -- monitor.setBackgroundColor(uiColors.header)
    monitor.setBackgroundColor(uiColors.background)
    monitor.clearLine()
    monitor.setTextColor(uiColors.text)
    
    -- Create emphasized title with spacing between characters
    local title = "M E K A N I S M   M I N I N G   H U B"
    local padding = math.floor((w - #title) / 2)
    
    monitor.setCursorPos(padding, 2)
    monitor.write(title)
    
    -- Status line with spacing
    monitor.setCursorPos(1, 3)
    monitor.setBackgroundColor(uiColors.background)
    monitor.clearLine()
    
    -- Status line
    monitor.setCursorPos(1, 4)
    -- monitor.setBackgroundColor(uiColors.header)
    monitor.setBackgroundColor(uiColors.background)
    monitor.clearLine()
    monitor.setTextColor(uiColors.text)
    
    local onlineCount = 0
    local restoredCount = 0
    for _, turtle in pairs(turtles) do
        if turtle.status == "online" then
            onlineCount = onlineCount + 1
        else
            restoredCount = restoredCount + 1
        end
    end
    
    local statusText = string.format(" Active: %d/%d", onlineCount, table.getn(turtles))
    if restoredCount > 0 then
        statusText = statusText .. string.format(" | Waiting: %d", restoredCount)
    end
    statusText = statusText .. string.format(" | Ch: %d | %s ", CHANNEL, os.date("%H:%M:%S"))
    monitor.setCursorPos((w - #statusText) / 2, 4)  -- Center status text
    monitor.write(statusText)
    
    -- Empty row for spacing
    monitor.setCursorPos(1, 5)
    monitor.setBackgroundColor(uiColors.background)
    monitor.clearLine()
end

-- Get sorted turtle list
function getSortedTurtles()
    local sortedList = {}
    for id, turtle in pairs(turtles) do
        table.insert(sortedList, {id = id, turtle = turtle})
    end
    
    -- Sort by status (online first) then by ID
    table.sort(sortedList, function(a, b)
        if a.turtle.status ~= b.turtle.status then
            return a.turtle.status == "online"
        end
        return a.id < b.id
    end)
    
    return sortedList
end

-- Draw turtle list with accordion-style details and pairing info
function drawTurtleList()
    local w, h = monitor.getSize()
    monitor.setBackgroundColor(uiColors.background)
    
    -- Clear turtle list area (start from line 6 - after header and spacing)
    for y = 6, h do
        monitor.setCursorPos(1, y)
        monitor.clearLine()
    end
    
    local sortedTurtles = getSortedTurtles()
    
    -- Filter out hidden turtles
    local visibleTurtles = {}
    for _, entry in ipairs(sortedTurtles) do
        local turtle = entry.turtle
        if not turtle.isHidden then
            table.insert(visibleTurtles, entry)
        end
    end
    sortedTurtles = visibleTurtles
    
    if #sortedTurtles == 0 then
        monitor.setTextColor(uiColors.warning)
        monitor.setCursorPos(2, 7)
        monitor.write("No turtles registered")
        monitor.setCursorPos(2, 8)
        monitor.write("Waiting for connections on channel " .. CHANNEL .. "...")
        return
    end
    
    local line = 6  -- Start after header and spacing
    
    for i, entry in ipairs(sortedTurtles) do
        -- (rest of the function remains the same, just with updated starting line)
        local id = entry.id
        local turtle = entry.turtle
        
        if line > h then break end
        
        -- Draw turtle summary line with type and pairing info
        monitor.setCursorPos(1, line)
        monitor.setBackgroundColor(uiColors.background)
        
        -- Status indicator
        local statusColor = uiColors.offline
        if turtle.status == "online" then
            statusColor = uiColors.online
        elseif turtle.status == "waiting" then
            statusColor = uiColors.waiting
        end
        monitor.setTextColor(statusColor)
        monitor.write("●")
        
        -- Turtle type indicator
        monitor.setTextColor(uiColors.text)
        local typeIndicator = ""
        if turtle.turtleType == "worker" then
            typeIndicator = "[W]"
        elseif turtle.turtleType == "companion" then
            typeIndicator = "[C]"
        end
        monitor.write(typeIndicator)
        
        -- Pairing indicator
        local pairIndicator = ""
        if turtle.pairedWith then
            pairIndicator = "↔" .. turtle.pairedWith
        elseif turtle.turtleType == "worker" then
            pairIndicator = "○"  -- Waiting for companion
        elseif turtle.turtleType == "companion" then
            pairIndicator = "○"  -- Waiting for worker
        end
        
        -- Main turtle info
        local info = string.format(" %s [%d]%s - %s | C:%d F:%d", 
            turtle.label, id, pairIndicator, turtle.phase, turtle.cycle, turtle.fuel)
        
        -- Highlight selected turtle
        if selectedTurtle == id and detailsExpanded then
            monitor.setBackgroundColor(uiColors.selected)
            monitor.setTextColor(colors.black)
        end
        
        monitor.write(info)
        
        -- Add coordinates if available and space permits
        if turtle.x ~= 0 or turtle.y ~= 0 or turtle.z ~= 0 then
            local coordText = string.format(" (%d,%d,%d)", turtle.x, turtle.y, turtle.z)
            if #info + #coordText < w - 6 then  -- Account for type and pair indicators
                monitor.write(coordText)
            end
        end
        
        monitor.setBackgroundColor(uiColors.background)
        line = line + 1
        
        -- Draw expanded details if this turtle is selected
        if selectedTurtle == id and detailsExpanded then
            line = drawExpandedDetails(turtle, line, w, h)
        end
    end
end

-- Draw expanded details for selected turtle
function drawExpandedDetails(turtle, startLine, w, h)
    local line = startLine
    
    -- Calculate maximum height for details (70% of total screen)
    local maxDetailHeight = math.floor(h * 0.7)
    local availableHeight = math.min(h - startLine, maxDetailHeight)
    local endLine = startLine + availableHeight - 1
    
    -- Draw border
    monitor.setCursorPos(1, line)
    monitor.setTextColor(uiColors.border)
    monitor.write(string.rep("-", w))
    line = line + 1
    
    if line > endLine then return line end
    
    -- Turtle details header
    monitor.setCursorPos(2, line)
    monitor.setTextColor(uiColors.accent)
    monitor.write("TURTLE DETAILS: " .. turtle.label .. " [ID:" .. turtle.id .. "]")
    line = line + 1
    
    if line > endLine then return line end
    
    -- Status and timing info
    monitor.setCursorPos(2, line)
    monitor.setTextColor(uiColors.text)
    monitor.write("Status: ")
    local statusColor = turtle.status == "online" and uiColors.online or uiColors.offline
    monitor.setTextColor(statusColor)
    monitor.write(turtle.status)
    monitor.setTextColor(uiColors.text)
    monitor.write(" | Last Seen: " .. os.date("%H:%M:%S", turtle.lastSeen))
    line = line + 1
    
    if line > endLine then return line end
    
    -- Coordinates (enhanced GPS display)
    monitor.setCursorPos(2, line)
    monitor.setTextColor(uiColors.text)
    if turtle.x ~= 0 or turtle.y ~= 0 or turtle.z ~= 0 then
        local distance = math.sqrt(turtle.x * turtle.x + turtle.y * turtle.y + turtle.z * turtle.z)
        monitor.write(string.format("Position: X:%d Y:%d Z:%d | Distance: %.1f blocks", 
            turtle.x, turtle.y, turtle.z, distance))
    else
        monitor.write("Position: GPS data not available")
    end
    line = line + 1
    
    if line > endLine then return line end
    
    -- Fuel and cycle info
    monitor.setCursorPos(2, line)
    monitor.setTextColor(uiColors.text)
    monitor.write(string.format("Fuel: %d | Cycle: %d | Phase: %s", 
        turtle.fuel, turtle.cycle, turtle.phase))
    line = line + 1
    
    if line > endLine then return line end
    
    -- Logs header
    monitor.setCursorPos(2, line)
    monitor.setTextColor(uiColors.accent)
    monitor.write("RECENT LOGS:")
    line = line + 1
    
    -- Display logs (most recent first, limited by space)
    local logs = turtle.logs
    local maxLogLines = endLine - line
    
    if #logs == 0 then
        if line <= endLine then
            monitor.setCursorPos(4, line)
            monitor.setTextColor(uiColors.warning)
            monitor.write("No logs available")
        end
        line = line + 1
    else
        -- Show most recent logs first
        local startIndex = math.max(1, #logs - maxLogLines + 1)
        
        for i = #logs, startIndex, -1 do
            if line > endLine then break end
            
            local log = logs[i]
            monitor.setCursorPos(4, line)
            monitor.setTextColor(uiColors.warning)
            monitor.write(log.time)
            monitor.setTextColor(uiColors.text)
            
            -- Word wrap long messages
            local maxLogWidth = w - 12  -- Account for timestamp and indent
            local message = log.message
            
            if #message <= maxLogWidth then
                monitor.write(" " .. message)
            else
                -- First line
                monitor.write(" " .. string.sub(message, 1, maxLogWidth))
                line = line + 1
                
                -- Additional lines for long messages
                local remaining = string.sub(message, maxLogWidth + 1)
                while #remaining > 0 and line <= endLine do
                    monitor.setCursorPos(12, line)
                    monitor.setTextColor(uiColors.text)
                    local chunk = string.sub(remaining, 1, maxLogWidth)
                    monitor.write(chunk)
                    remaining = string.sub(remaining, maxLogWidth + 1)
                    line = line + 1
                end
                line = line - 1  -- Adjust for the extra increment
            end
            line = line + 1
        end
    end
    
    -- Bottom border
    if line <= endLine then
        monitor.setCursorPos(1, line)
        monitor.setTextColor(uiColors.border)
        monitor.write(string.rep("-", w))
        line = line + 1
    end
    
    return line
end

-- Handle monitor touches (simplified - only for expanding turtle details)
function handleMonitorTouch(x, y)
    local w, h = monitor.getSize()
    
    -- Ignore header clicks (now includes rows 1-5)
    if y <= 5 then return end
    
    local sortedTurtles = getSortedTurtles()
    local line = 6  -- Start after header and spacing
    
    for i, entry in ipairs(sortedTurtles) do
        local id = entry.id
        local turtle = entry.turtle
        
        -- Check if this line was clicked
        if y == line then
            if selectedTurtle == id and detailsExpanded then
                -- Collapse if already expanded
                selectedTurtle = nil
                detailsExpanded = false
            else
                -- Expand this turtle
                selectedTurtle = id
                detailsExpanded = true
            end
            return
        end
        
        line = line + 1
        
        -- Skip over expanded details if shown
        if selectedTurtle == id and detailsExpanded then
            -- Calculate how many lines the details take (70% of screen max)
            local maxDetailHeight = math.floor(h * 0.7)
            local detailLines = math.min(maxDetailHeight, 15)  -- Roughly 15 lines for details
            line = line + detailLines
        end
        
        if line > h then break end
    end
end

-- Send command to turtle (simplified)
function sendCommandToTurtle(turtleId, command)
    if not turtles[turtleId] then return false end
    
    local message = textutils.serialise({
        type = "command",
        command = command,
        timestamp = os.clock(),
        hubId = HUB_ID
    })
    
    modem.transmit(CHANNEL, CHANNEL, message)
    addTurtleLog(turtleId, "Hub sent command: " .. command)
    return true
end

-- Main UI update function
function updateDisplay()
    monitor.clear()
    drawHeader()
    drawTurtleList()
end

-- Handle terminal commands
function handleTerminalCommands()
    print("\nHub Commands:")
    print("- 'list' - Show all turtles")
    print("- 'select <id>' - Select turtle")
    print("- 'cmd <id> <command>' - Send command to a turtle")
    print("- 'stop' - Stop hub")
    print("- 'clear' - Clear terminal")
    
    while running do
        write("Hub> ")
        local input = read()
        local parts = {}
        for word in input:gmatch("%S+") do
            table.insert(parts, word)
        end
        
        local command = parts[1]
        
        if command == "list" then
            print("Registered turtles:")
            for id, turtle in pairs(turtles) do
                print(string.format("  [%d] %s - %s (C:%d F:%d) %s", 
                    id, turtle.label, turtle.status, turtle.cycle, turtle.fuel, turtle.phase))
            end
            
        elseif command == "select" and parts[2] then
            local id = tonumber(parts[2])
            if turtles[id] then
                selectedTurtle = id
                detailsExpanded = true
                print("Selected and expanded turtle " .. id)
            else
                print("Turtle " .. id .. " not found")
            end
            
        elseif command == "cmd" and parts[2] and parts[3] then
            local id = tonumber(parts[2])
            if turtles[id] then
                local cmd = table.concat(parts, " ", 3)
                if sendCommandToTurtle(id, cmd) then
                    print("Command sent to turtle " .. id)
                else
                    print("Failed to send command")
                end
            else
                print("Turtle " .. id .. " not found")
            end
            
        elseif command == "stop" then
            running = false
            print("Stopping hub...")
            break
            
        elseif command == "clear" then
            term.clear()
            term.setCursorPos(1, 1)
            
        else
            print("Unknown command: " .. input)
        end
    end
end

-- Main event loop
function eventLoop()
    local timer = os.startTimer(1)  -- Update timer
    local saveTimer = os.startTimer(SAVE_INTERVAL)  -- Save timer
    
    while running do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        
        if event == "modem_message" then
            local side, channel, replyChannel, message, distance = param1, param2, param3, param4, param5
            if channel == CHANNEL then
                handleTurtleMessage(message, replyChannel)
                updateDisplay()
            end
            
        elseif event == "monitor_touch" then
            local side, x, y = param1, param2, param3
            if side == MONITOR_SIDE then
                handleMonitorTouch(x, y)
                updateDisplay()
            end
            
        elseif event == "timer" then
            if param1 == timer then
                checkTurtleStatus()
                updateDisplay()
                timer = os.startTimer(5)  -- Check every 5 seconds
            elseif param1 == saveTimer then
                handlePeriodicSave()
                saveTimer = os.startTimer(SAVE_INTERVAL)
            end
            
        elseif event == "terminate" then
            running = false
        end
    end
end

-- Utility function to get table length (Lua 5.1 compatibility)
function table.getn(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Main function
function main()
    print("=== MEKANISM MINING HUB CONTROL (Simplified) ===")
    print("Initializing...")
    
    -- Initialize hardware
    initializeHardware()
    
    -- Load previous turtle data
    print("Loading previous session data...")
    loadTurtleData()
    
    -- Initial display
    updateDisplay()
    
    -- Broadcast discovery message to tell turtles to reconnect
    print("Broadcasting discovery message...")
    sleep(1)  -- Small delay to ensure modem is ready
    broadcastDiscovery()
    
    print("Hub is running!")
    print("- Click turtles to expand/collapse details")
    print("- Use terminal for sending commands")
    print("- Auto-saves every " .. SAVE_INTERVAL .. " seconds")
    print("Turtles can register on channel " .. CHANNEL)
    
    if table.getn(turtles) > 0 then
        print("Waiting for " .. table.getn(turtles) .. " turtles to reconnect...")
    end
    
    -- Start terminal and event loops in parallel
    parallel.waitForAny(eventLoop, handleTerminalCommands)
    
    -- Cleanup and save on shutdown
    print("Shutting down hub...")
    if saveTurtleData() then
        print("Turtle data saved successfully")
    else
        print("Warning: Failed to save turtle data")
    end
    
    if modem then
        modem.close(CHANNEL)
    end
    if monitor then
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.setTextColor(colors.white)
        monitor.setBackgroundColor(colors.black)
        monitor.write("Mining Hub Offline")
    end
    
    print("Hub shutdown complete.")
end

-- Run the hub
main()