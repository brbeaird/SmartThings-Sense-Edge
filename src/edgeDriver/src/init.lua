local Driver = require('st.driver')
local caps = require('st.capabilities')
local log = require('log')
local socket = require('socket')
local config = require('config')
local httpUtil = require('httpUtil')
local cosock = require('cosock')
local commands = require('commands')
local lux = require('luxure')
local json = require('dkjson')
local CONTROLLERID = 'SenseController'


-- Create Initial Device
local function discovery_handler(driver, _, should_continue)
  log.debug("Device discovery invoked")

  local senseController = commands.getControllerDevice(driver)
  if senseController == nil then
    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'Sense-Controller'
    local VEND_LABEL = 'Sense-Controller'
    local ID = 'SenseController'
    local PROFILE = 'SenseController.v1'

    log.info (string.format('Creating new controller device'))
    local create_device_msg =
    {
      type = "LAN",
      device_network_id = ID,
      label = VEND_LABEL,
      profile = PROFILE,
      manufacturer = MFG_NAME,
      model = '',
      vendor_provided_label = VEND_LABEL,
    }

    assert (driver:try_create_device(create_device_msg), "failed to create device")
  end
  log.debug("Exiting discovery")
end


-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)

  log.debug(device.label .. ": " .. device.device_network_id .. "> INITIALIZING")

  --Set up refresh schedule
  if (device.device_network_id == CONTROLLERID) then
    commands.refresh(driver, device)
    log.debug("Setting up refresh schedule")
    device.thread:call_on_schedule(
      device.preferences.pollingInterval,
      function ()
        return commands.refresh(driver, device)
      end,
      'refreshTimer')
  end
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)
  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")
end


--Called when settings are changed
local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')
  if (device.device_network_id == CONTROLLERID) then

    --Cancel existing timer
    log.debug("Cancelling old timer");
    for timer in pairs(device.thread.timers) do
      device.thread:cancel_timer(timer)
    end

    --Store manually-entered IP/Port info (if applicable)
    if device.preferences.serverIp ~= '' and device.preferences.serverPort ~= '' then
      assert (device:try_update_metadata({model = 'http://' ..device.preferences.serverIp ..':' ..device.preferences.serverPort}), 'failed to update device.')
    end

    --Set up refresh schedule
    log.debug("Setting up refresh schedule");
    device.thread:call_on_schedule(
      device.preferences.pollingInterval,
      function ()
        return commands.refresh(driver, device)
      end,
      'refreshTimer')
  end

  --Go ahead and refresh
  commands.refresh(driver, device, 1, 1)

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")
  for timer in pairs(device.thread.timers) do --Timer should only apply to controller device
    device.thread:cancel_timer(timer)
  end
end


--------------------
-- Driver definition
local driver =
  Driver(
    'senseConnectorDriver',
    {
      discovery = discovery_handler,
      lifecycle_handlers = {
        init = device_init,
        added = device_added,
        infoChanged = handler_infochanged,
        removed = device_removed
      },

      --lifecycle_handlers = lifecycles,
      supported_capabilities = {
        caps.doorControl
      },
      capability_handlers = {

        -- Refresh command handler
        [caps.refresh.ID] = {
          [caps.refresh.commands.refresh.NAME] = commands.refresh
        }
      }
    }
  )

  -----------------------------
-- Initialize Hub server (for incoming traffic)
local hub_server = {}

function hub_server.start(driver)
  local server = lux.Server.new_with(cosock.socket.tcp(), { env = 'debug' })

  server:listen()
  log.trace('Server listening on ' ..server.ip ..':' ..server.port)

  cosock.spawn(function()
    while true do
      server:tick(log.error)
    end
  end, "server run loop")

  server:get('/', function(req, res)
    res:send('hello world')
  end)

  server:post('/ping', function (req, res)
    log.info('Incoming ping from ')
    local body = json.decode(req:get_body())
    log.info(req:get_headers():serialize())

    --Get the IP/port from the http request
    local senseServerUrl = req.socket:getpeername() ..':' ..body.senseServerPort
    log.info('Incoming ping from ' ..senseServerUrl ..body.deviceId)

    --Respond
    res:send('HTTP/1.1 200 OK')

    --Update URL on controller device
    local senseController = commands.getControllerDevice(driver)
    assert (senseController:try_update_metadata({model = 'http://' ..senseServerUrl}), 'failed to update device.')
  end)

  driver.server = server
end


hub_server.start(driver)

--------------------
-- Initialize Driver
driver:run()