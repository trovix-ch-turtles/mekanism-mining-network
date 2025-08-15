-- Mekanism Mining Network Installer
-- Usage: pastebin run <code> [part]
-- Available parts: hub, teleport_master, worker, worker_buddy

-- Configuration
local REPO_URL = "https://api.github.com/repos/trovix-ch-turtles/mekanism-mining-network/contents"
local TEMP_DIR = "/tmp_repo"
local PARTS = {
  "hub",
  "teleport_master",
  "worker",
  "worker_buddy"
}
local NEED_LIB = {
  worker = true,
  worker_buddy = true
}
local CONFIG_FILE = ".mekanism_config"

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

-- Function to save the selected part
local function saveSelection(part)
  local file = fs.open(CONFIG_FILE, "w")
  if file then
    file.write(part)
    file.close()
    return true
  end
  return false
end

-- Function to load the saved selection
local function loadSelection()
  if not fs.exists(CONFIG_FILE) then
    return nil
  end
  
  local file = fs.open(CONFIG_FILE, "r")
  if file then
    local part = file.readAll()
    file.close()
    if part and part ~= "" then
      return part
    end
  end
  return nil
end

-- Function to check if a part is valid
local function isValidPart(part)
  for _, validPart in ipairs(PARTS) do
    if part == validPart then
      return true
    end
  end
  return false
end

-- Function to download file from URL
local function downloadFile(url, path)
  print("Downloading: " .. url)
  local response = http.get(url)
  if not response then
    print("Failed to download: " .. url)
    return false
  end
  
  local content = response.readAll()
  response.close()
  
  local file = fs.open(path, "w")
  file.write(content)
  file.close()
  
  return true
end

-- Function to download a directory recursively
local function downloadDirectory(apiUrl, localPath)
  -- Create the directory
  if not fs.exists(localPath) then
    fs.makeDir(localPath)
  end
  
  -- Get the directory contents
  local response = http.get(apiUrl)
  if not response then
    print("Failed to get directory listing: " .. apiUrl)
    return false
  end
  
  local contents = textutils.unserializeJSON(response.readAll())
  response.close()
  
  if not contents then
    print("Failed to parse directory contents")
    return false
  end
  
  -- Download each item
  for _, item in ipairs(contents) do
    local itemPath = fs.combine(localPath, item.name)
    
    if item.type == "file" then
      if not downloadFile(item.download_url, itemPath) then
        return false
      end
    elseif item.type == "dir" then
      if not downloadDirectory(item.url, itemPath) then
        return false
      end
    end
  end
  
  return true
end

-- Function to copy a directory
local function copyDirectory(source, destination)
  if not fs.exists(destination) then
    fs.makeDir(destination)
  end
  
  for _, file in ipairs(fs.list(source)) do
    local sourcePath = fs.combine(source, file)
    local destPath = fs.combine(destination, file)
    
    if fs.isDir(sourcePath) then
      copyDirectory(sourcePath, destPath)
    else
      fs.copy(sourcePath, destPath)
    end
  end
end

-- Function to install the selected part
local function installPart(part)
  print("Installing " .. part .. "...")
  
  -- Create temporary directory
  if fs.exists(TEMP_DIR) then
    fs.delete(TEMP_DIR)
  end
  fs.makeDir(TEMP_DIR)
  
  -- Clone the repository
  print("Cloning repository...")
  if not downloadDirectory(REPO_URL, TEMP_DIR) then
    print("Failed to clone repository.")
    fs.delete(TEMP_DIR)
    return false
  end
  
  -- Move the selected part to root
  local partDir = fs.combine(TEMP_DIR, "parts/" .. part)
  print("Moving " .. part .. " files to root...")
  
  if not fs.exists(partDir) then
    print("Part directory not found: " .. partDir)
    fs.delete(TEMP_DIR)
    return false
  end
  
  for _, file in ipairs(fs.list(partDir)) do
    local sourcePath = fs.combine(partDir, file)
    local destPath = "/" .. file
    
    if fs.exists(destPath) then
      fs.delete(destPath)
    end
    
    fs.copy(sourcePath, destPath)
    print("Copied: " .. destPath)
  end
  
  -- Move lib folder if needed
  if NEED_LIB[part] then
    print("Moving lib folder to root...")
    local libDir = fs.combine(TEMP_DIR, "lib")
    
    if fs.exists("/lib") then
      fs.delete("/lib")
    end
    
    copyDirectory(libDir, "/lib")
    print("Lib folder copied.")
  end
  
  -- Clean up
  fs.delete(TEMP_DIR)
  print(part .. " installed successfully!")
  return true
end

-- Main function
local function main(...)
  displayHeader()
  
  -- Determine which part to install
  local part = nil
  
  -- Check for persisted selection
  part = loadSelection()
  if part and isValidPart(part) then
    print("Found saved selection: " .. part)
  end
  
  -- Check for command-line argument
  local args = {...}
  if not part and args[1] and isValidPart(args[1]) then
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
  
  -- Install the selected part
  print("Preparing to install " .. part .. "...")
  
  if installPart(part) then
    print("Installation complete!")
    print("Restarting in 3 seconds...")
    
    -- Wait 3 seconds and then restart
    for i = 3, 1, -1 do
      print(i .. "...")
      sleep(1)
    end
    
    os.reboot()
  else
    print("Installation failed.")
  end
end

-- Run the installer
main(...)