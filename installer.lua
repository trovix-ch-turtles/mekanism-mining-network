-- Mekanism Mining Network Installer (Optimized)
-- Usage: pastebin run <code> [part]
-- Available parts: hub, teleport_master, worker, worker_buddy

-- Configuration
local REPO_URL = "https://api.github.com/repos/trovix-ch-turtles/mekanism-mining-network/contents"
local PARTS = {
  "hub",
  "teleport_master",
  "worker",
  "worker_buddy"
}
local NEED_LIB = {
  worker = true,
  worker_buddy = true,
  teleport_master = true
}
local CONFIG_FILE = ".mekanism_config"
local UPDATE_FILE = "/update.lua"
local UPDATE_MODE = false

-- Function to display header
local function displayHeader()
  term.clear()
  term.setCursorPos(1, 1)
  print("=== Mekanism Mining Network Installer ===")
  print("This installer will set up your turtle/computer")
  print("for the Mekanism Mining Network system.")
  print("")
end

-- Function to select a part
local function selectPart()
  print("Please select a part to install:")
  for i, part in ipairs(PARTS) do
    print(i .. ". " .. part)
  end
  
  print("Enter your choice (1-" .. #PARTS .. "):")
  while true do
    local input = read()
    local choice = tonumber(input)
    
    if choice and choice >= 1 and choice <= #PARTS then
      return PARTS[choice]
    end
    
    print("Invalid choice. Please enter a number between 1 and " .. #PARTS .. ":")
  end
end

-- Function to save/load selection
local function saveSelection(part)
  local file = fs.open(CONFIG_FILE, "w")
  if file then file.write(part); file.close(); return true end
  return false
end

local function loadSelection()
  if not fs.exists(CONFIG_FILE) then return nil end
  local file = fs.open(CONFIG_FILE, "r")
  if file then 
    local part = file.readAll()
    file.close()
    if part and part ~= "" then return part end
  end
  return nil
end

-- Function to check if a part is valid
local function isValidPart(part)
  for _, validPart in ipairs(PARTS) do
    if part == validPart then return true end
  end
  return false
end

-- Function to get directory contents from GitHub API
local function getDirectoryContents(apiUrl)
  print("Fetching: " .. apiUrl)
  local response = http.get(apiUrl)
  if not response then
    print("Failed to get directory listing")
    return nil
  end
  
  local contents = textutils.unserializeJSON(response.readAll())
  response.close()
  
  if not contents then
    print("Failed to parse directory contents")
    return nil
  end
  
  return contents
end

-- Function to download file from URL to specified path
local function downloadFile(url, path)
  print("Downloading: " .. path)
  local response = http.get(url)
  if not response then
    print("Failed to download: " .. url)
    return false
  end
  
  local content = response.readAll()
  response.close()
  
  -- Create parent directories if needed
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  
  -- Remove existing file if it exists
  if fs.exists(path) then
    fs.delete(path)
  end
  
  local file = fs.open(path, "w")
  file.write(content)
  file.close()
  
  return true
end

-- Function to build file list for a part
local function buildFileList(part)
  local fileList = {}
  
  -- Get part files (to be placed at root)
  local partUrl = REPO_URL .. "/parts/" .. part
  local partContents = getDirectoryContents(partUrl)
  if not partContents then
    return nil
  end
  
  for _, item in ipairs(partContents) do
    if item.type == "file" then
      table.insert(fileList, {
        url = item.download_url,
        path = "/" .. item.name
      })
    end
  end
  
  -- Get lib files if needed
  if NEED_LIB[part] then
    local libUrl = REPO_URL .. "/lib"
    local libContents = getDirectoryContents(libUrl)
    if not libContents then
      return nil
    end
    
    for _, item in ipairs(libContents) do
      if item.type == "file" then
        table.insert(fileList, {
          url = item.download_url,
          path = "/lib/" .. item.name
        })
      end
    end
  end
  
  return fileList
end

-- Function to check if part is already installed
local function isPartInstalled(part)
  -- Check for startup.lua as indicator of installation
  if fs.exists("/startup.lua") then
    return true
  end
  
  -- For parts with lib, check if lib files exist
  if NEED_LIB[part] and fs.exists("/lib") then
    if fs.exists("/lib/common.lua") then
      return true
    end
  end
  
  return false
end

-- Function to clean existing files
local function cleanExistingFiles(part)
  print("Cleaning existing files for " .. part .. "...")
  
  -- Remove startup.lua which is common for all parts
  if fs.exists("/startup.lua") then
    fs.delete("/startup.lua")
    print("Removed existing startup.lua")
  end
  
  -- If this part needs lib, clean lib files but keep directory
  if NEED_LIB[part] and fs.exists("/lib") then
    -- Instead of removing the whole directory, just remove the files
    -- This ensures we don't remove any custom libs the user might have added
    if fs.exists("/lib/common.lua") then
      fs.delete("/lib/common.lua")
      print("Removed existing lib/common.lua")
    end
    
    if fs.exists("/lib/hub_comm.lua") then
      fs.delete("/lib/hub_comm.lua")
      print("Removed existing lib/hub_comm.lua")
    end
  end
end

-- Function to create the updater script
local function createUpdater()
  -- Skip if update.lua already exists
  if fs.exists(UPDATE_FILE) then
    return true
  end
  
  print("Creating updater script...")
  local updaterContent = [[
-- Mekanism Mining Network Updater
-- Simply run this file to update your installation

-- Configuration
local REPO_URL = "https://raw.githubusercontent.com/trovix-ch-turtles/mekanism-mining-network/main"
local INSTALLER_PATH = "/installer.lua"

-- Display header
term.clear()
term.setCursorPos(1, 1)
print("=== Mekanism Mining Network Updater ===")
print("This will download the latest installer and update your system.")
print("")

-- Download the installer
print("Downloading latest installer...")
local installerUrl = REPO_URL .. INSTALLER_PATH
print("From URL: " .. installerUrl)
local response = http.get(installerUrl)

if not response then
  print("Failed to download installer!")
  return
end

local content = response.readAll()
response.close()

-- Save the installer
print("Saving installer...")
if fs.exists(INSTALLER_PATH) then
  fs.delete(INSTALLER_PATH)
end

local file = fs.open(INSTALLER_PATH, "w")
file.write(content)
file.close()

-- Run the installer
print("Running installer...")
print("-----------------------------------")
shell.run(INSTALLER_PATH, "update_mode")

-- Installer will delete itself after completion
print("Update complete!")
]]

  local file = fs.open(UPDATE_FILE, "w")
  if file then
    file.write(updaterContent)
    file.close()
    print("Created updater script: " .. UPDATE_FILE)
    return true
  end
  
  print("Failed to create updater script!")
  return false
end

-- Function to install the selected part
local function installPart(part)
  -- Check if this is an update
  local isUpdate = isPartInstalled(part)
  if isUpdate then
    print("Found existing installation. Performing update...")
    cleanExistingFiles(part)
  end
  
  print("Building file list for " .. part .. "...")
  local fileList = buildFileList(part)
  if not fileList then
    print("Failed to build file list.")
    return false
  end
  
  print("Found " .. #fileList .. " files to " .. (isUpdate and "update" or "download") .. ".")
  
  -- Create lib directory if needed
  if NEED_LIB[part] and not fs.exists("/lib") then
    fs.makeDir("/lib")
  end
  
  -- Download each file
  local successCount = 0
  for _, file in ipairs(fileList) do
    if downloadFile(file.url, file.path) then
      successCount = successCount + 1
    end
  end
  
  -- Create the updater script
  createUpdater()
  
  print((isUpdate and "Updated " or "Downloaded ") .. successCount .. "/" .. #fileList .. " files.")
  return successCount == #fileList
end

-- Main function
local function main(...)
  displayHeader()
  
  -- Check if we're in update mode
  local args = {...}
  if args[1] == "update_mode" then
    UPDATE_MODE = true
  end
  
  -- Determine which part to install
  local part = nil
  
  -- Check for persisted selection
  part = loadSelection()
  if part and isValidPart(part) then
    print("Found saved selection: " .. part)
  end
  
  -- Check for command-line argument (skip if update_mode is the only arg)
  if not part and args[1] and args[1] ~= "update_mode" and isValidPart(args[1]) then
    part = args[1]
    print("Using command-line argument: " .. part)
  end
  
  -- Prompt user if needed
  if not part then
    part = selectPart()
  end
  
  -- Save the selection
  if not loadSelection() then  -- Only save if not already saved
    saveSelection(part)
    print("Selection saved for future use.")
  end
  
  -- Install/update the selected part
  local isUpdate = isPartInstalled(part)
  print("Preparing to " .. (isUpdate and "update" or "install") .. " " .. part .. "...")
  
  local success = installPart(part)
  if success then
    print((isUpdate and "Update" or "Installation") .. " complete!")
    
    -- Delete installer if in update mode
    if UPDATE_MODE then
      print("Removing installer...")
      local installerPath = shell.getRunningProgram()
      fs.delete(installerPath)
    end
    
    print("Restarting in 3 seconds...")
    
    -- Wait 3 seconds and then restart
    for i = 3, 1, -1 do
      print(i .. "...")
      sleep(1)
    end
    
    os.reboot()
  else
    print((isUpdate and "Update" or "Installation") .. " failed.")
  end
end

-- Run the installer
main(...)