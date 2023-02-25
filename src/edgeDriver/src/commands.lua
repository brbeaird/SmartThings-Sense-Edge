local caps = require('st.capabilities')
local utils = require('st.utils')
local neturl = require('net.url')
local log = require('log')
local json = require('dkjson')
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
http.TIMEOUT = 5
local ltn12 = require('ltn12')
local httpUtil = require('httpUtil')
local socket = require('socket')
local config = require('config')
local CONTROLLERID = 'SenseController'

--Custom capabilities
local statusCapName = 'towertalent27877.bridgeServerStatus'
local statusCapAttName = 'status'
local bridgeServerStatusCap = caps[statusCapName]

local addressCapName = 'towertalent27877.bridgeServerAddress'
local addressCapAttName = 'address'
local bridgeServerAddressCap = caps[addressCapName]
local healthCap = caps['towertalent27877.health']

--Device type info
local senseDeviceProfile = 'SenseDevice.v1'

--Allow for occasional errors
local consecutiveFailureCount = 0
local consecutiveFailureThreshold = 3

--Main exported object
local command_handler = {}

------------------
-- Refresh command
function command_handler.refresh(driver, callingDevice, skipScan, firstAuth)


  local senseController

  --If called from controller, shortcut it
  if (callingDevice.device_network_id == CONTROLLERID) then
    senseController = callingDevice

  --Otherwise, look up the controller device
  else
    local device_list = driver:get_devices() --Grab existing devices
    local deviceExists = false
    for _, device in ipairs(device_list) do
      if device.device_network_id == CONTROLLERID then
        senseController = driver.get_device_info(driver, device.id, true)
      end
    end
  end

  --Handle manual IP entry
  if senseController.preferences.serverIp ~= '' then
    skipScan = 1
  end

  --Update controller server address
  local currentControllerServerAddress = senseController:get_latest_state('main', addressCapName, addressCapAttName, "unknown")
  local serverAddress = "Pending"
  if senseController.model ~= '' then
    serverAddress = senseController.model
  end
  if currentControllerServerAddress ~= serverAddress then
    senseController:emit_event(bridgeServerAddressCap.address(serverAddress))
  end

--Handle blank auth info
  if senseController.preferences.email == '' or senseController.preferences.password == '' then
    log.info('No credentials yet. Waiting.')
    local defaultAuthStatus = 'Awaiting credentials'
    local currentStatus = senseController:get_latest_state('main', statusCapName, statusCapAttName, "unknown")
    if currentStatus ~= defaultAuthStatus then
      senseController:emit_event(bridgeServerStatusCap.status(defaultAuthStatus))
      senseController:online()
          local currentHealthStatus = senseController:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
          if currentHealthStatus ~= 'Online' then
            senseController:emit_event(healthCap.healthStatus('Online'))
          end
    end
    consecutiveFailureCount = 100 --Force immediate display of errors once auth is entered
    return
  end

  --Handle missing bridge server URL - try and broadcast to auto-discover
  if senseController.model == '' then
    doBroadcast(driver, callingDevice, senseController)
    return
  end


  --Call out to Sense server
  local loginInfo = {email=senseController.preferences.email, password=senseController.preferences.password}
  local data = {auth=loginInfo}
  local success, code, res_body = httpUtil.send_lan_command(senseController.model, 'POST', 'senseDevices', data)

  --Handle server result
  if success and code == 200 then
    local raw_data = json.decode(table.concat(res_body)..'}') --ltn12 bug drops last  bracket
    consecutiveFailureCount = 0
    local installedDeviceCount = 0

    --Loop over latest data from bridge server
    local senseDeviceCount = 0
    for devNumber, senseDevice in pairs(raw_data) do

      --Doors and lamp modules
        senseDeviceCount = senseDeviceCount + 1
        local deviceExists = false
        local stDevice

        --Determine if device exists in SmartThings
        local device_list = driver:get_devices() --Grab existing devices
        for _, device in ipairs(device_list) do
          if device.device_network_id == senseDevice.id then
            deviceExists = true
            stDevice = device
          end
        end

        --If this device already exists in SmartThings, update the status
        if deviceExists then
          installedDeviceCount = installedDeviceCount + 1

          --Set health online
          stDevice:online()
          local currentHealthStatus = stDevice:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
          if currentHealthStatus ~= 'Online' then
            stDevice:emit_event(healthCap.healthStatus('Online'))
          end

          local currentUsage = senseDevice.usage
          local stPower = stDevice:get_latest_state('main', caps.powerMeter.ID, "power", 9999)

          if stPower ~= currentUsage then
            log.trace('Power usage ' ..stDevice.label .. ': setting value from ' ..stPower ..' to ' ..currentUsage)
            stDevice:emit_event(caps.powerMeter.power(currentUsage))
          end


          local lampState = senseDevice.state
          local stState = stDevice:get_latest_state('main', caps.switch.switch.ID, "switch", "unknown")

          if stState ~= lampState then
            log.trace('Switch ' ..stDevice.label .. ': setting status to ' ..lampState)
            stDevice:emit_event(caps.switch.switch(lampState))
          end

        --Create new devices
        else

          --Respect include list setting (if applicable)
          local deviceIncluded = false
          if senseController.preferences.includeList == '' then
            deviceIncluded = true
          else
            deviceIncluded = false
            for i in string.gmatch(senseController.preferences.includeList, "([^,]+)") do
              if i == senseDevice.name then
                deviceIncluded = true
              end
           end
          end

          if deviceIncluded == true then

            local profileName

            log.info('Ready to create ' ..senseDevice.name ..' ('..senseDevice.id ..') ')

            local metadata = {
              type = 'LAN',
              device_network_id = senseDevice.id,
              label = 'Sense-' ..senseDevice.name,
              profile = senseDeviceProfile,
              manufacturer = 'sense',
              model = senseController.model,
              vendor_provided_label = 'senseDevice',
              parent_device_id = senseController.id
            }
            assert (driver:try_create_device(metadata), "failed to create device")
            installedDeviceCount = installedDeviceCount + 1
          else
            --log.info(senseDevice.name ..' not found in device inclusion list.')
          end
        end
    end

    --Update controller status
    log.info('Refresh successful via ' ..senseController.model ..'. Sense devices: ' ..senseDeviceCount ..', ST-installed devices: ' ..installedDeviceCount)
    senseController:online()
    local newStatus = 'Connected: ' ..installedDeviceCount ..' devices'
    local currentStatus = senseController:get_latest_state('main', statusCapName, statusCapAttName, "unknown")
    if currentStatus ~= newStatus then
      senseController:emit_event(bridgeServerStatusCap.status(newStatus))
    end

  elseif code == 401 and firstAuth == 1 then
    senseController:emit_event(bridgeServerStatusCap.status('Invalid credentials.'))
    return

  elseif code == 500 then
    senseController:emit_event(bridgeServerStatusCap.status('Server error.'))

  else

    --Allow for some failures in a row before we display a problem
    consecutiveFailureCount = consecutiveFailureCount + 1
    if consecutiveFailureCount > consecutiveFailureThreshold then

      --Handle Controller Status
      senseController:offline()
      local currentHealthStatus = senseController:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
      if currentHealthStatus ~= 'Offline' then
        senseController:emit_event(healthCap.healthStatus('Offline'))
      end


      --Update all devices to show server offline
      local device_list = driver:get_devices() --Grab existing devices
      for _, device in ipairs(device_list) do
        log.info(device.id)
        device:offline()

        --Set health status cap (needed for routines)
        local currentHealthStatus = device:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
        if currentHealthStatus ~= 'Offline' then
          device:emit_event(healthCap.healthStatus('Offline'))
        end

      end
    end


    --If refresh failed with no response at all, try a UDP search to try and auto detect the server (maybe the IP or port changed)
    log.error('Refresh Failed.')

    if (skipScan ~= 1) then
      doBroadcast(driver, device, senseController)
    end
  end
end

function doBroadcast(driver, device, senseController)

  local defaultLookingStatus = 'Searching for bridge server'
  local currentStatus = senseController:get_latest_state('main', statusCapName, statusCapAttName, "unknown")
  if currentStatus ~= defaultLookingStatus then
    senseController:emit_event(bridgeServerStatusCap.status(defaultLookingStatus))
  end

  -- Broadcast search
  senseController:offline()
  log.info('Sending broadcast looking for bridge server, listening for a response at ' ..driver.server.ip ..':' ..driver.server.port)
  local upnp = socket.udp()
  upnp:setsockname('*', 0)
  upnp:setoption('broadcast', true)
  upnp:settimeout(config.MC_TIMEOUT)

  local mSearchText = config.MSEARCH:gsub('IP_PLACEHOLDER', driver.server.ip)
  mSearchText = mSearchText:gsub('PORT_PLACEHOLDER', driver.server.port)
  mSearchText = mSearchText:gsub('ID_PLACEHOLDER', senseController.id)
  upnp:sendto(mSearchText, config.MC_ADDRESS, config.MC_PORT)
  local res = upnp:receive()
  upnp:close()
end

----------------
-- Device commands

--Switch--
function command_handler.switchControl(driver, device, commandParam)
  return
end

function command_handler.getControllerDevice(driver)
  local device_list = driver:get_devices() --Grab existing devices
  for _, device in ipairs(device_list) do
    if device.device_network_id == CONTROLLERID then
      return driver.get_device_info(driver, device.id)
    end
  end
end

function getLoginDetails(driver)

  --Email/password are stored on the controller device. Find it.
  local senseController
  local device_list = driver:get_devices() --Grab existing devices
  local deviceExists = false
  for _, device in ipairs(device_list) do
    if device.device_network_id == CONTROLLERID then
      senseController = driver.get_device_info(driver, device.id)
    end
  end
  return {email=senseController.preferences.email, password=senseController.preferences.password}
end

return command_handler