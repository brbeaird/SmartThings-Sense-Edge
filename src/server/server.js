var port = process.env.SENSE_SERVER_PORT || 0
const { version: VERSION } = require('./package.json');

const sense = require('sense-energy-node');
const express = require('express');
const axios = require('axios').default;
const app = express();
app.use(express.json());


var mySense;                        //Main Sense API object
var deviceList = {};                //Holds list of Sense devices
var senseEmail;
var sensePassword;
const ssdpId = 'urn:SmartThingsCommunity:device:SenseController' //Used in SSDP auto-discovery
var deviceList = {};
var isProcessing = false;
const totalDeviceId = '00total';


//Set credentials on sense object (these are always passed-in from calls from the ST hub)
async function senseLogin(email, password){
    try {
        //If password has been updated, set up new API object
        if (email != senseEmail || password != sensePassword){

            //Handle missing info
            if (!email || !password){
              log('Missing username or password.')
            return false;
            }

            //Save it
            log('Got new username/password from hub. Initializing connection.')
            mySense = await sense({email: email, password: password, verbose: false})   //Set up Sense API object and authenticate
            setupWebsocketEvents();
            senseEmail = email;
            sensePassword = password;
        }
        return true;
    } catch (error) {
        log(error.message);
        return false;
    }
}

//Clear out local cache of auth
function resetAuth(){
  log(`Resetting auth`, 1);
  senseEmail = '';
  sensePassword = '';

}

const updateSenseDevices = async () => {
  try {

    let devices = await mySense.getDevices();
    if (!devices){
        log(`No devices found - refresh failed`, 1);
        return;
    }

    for (let device of devices){
        if (device.tags.DeviceListAllowed == 'true'){
            let isGuess = device.data?.tags?.NameUserGuess === 'true' ? true : false;
            let devName = isGuess ? device.name.trim() + ' (?)' : device.name.trim();

            //If already exists, only refresh the name
            if (deviceList[device.id]){
              deviceList[device.id].name = devName;
            }
            else{
              log(`Found ${devName} `);
              deviceList[device.id] = {
                id: device.id,
                name: devName,
                state: "off",
                usage: 0
            };
            }
        }
    }

    deviceList[totalDeviceId] = {
      id: totalDeviceId,
      name: 'Total',
      state: 'on',
      usage: 0
    };
  } catch (error) {
    log(`Device list error: ${error.message}`)
  }
}


var websocketRefreshInterval;
var deviceListRefreshInterval;
var websocketDataIsPresent = false;

//Gets devices
app.post('/senseDevices', async (req, res) => {
    try {
        if (!await senseLogin(req.body.auth.email, req.body.auth.password)){
            return res.sendStatus(401);
        }

        //Schedule the device refresh
        if (!deviceListRefreshInterval){
          log(`Scheduling device refresh`)
          await updateSenseDevices();
          deviceListRefreshInterval = setInterval(() => {
            updateSenseDevices();
          }, 1000*60*5);
        }

        //Schedule the device refresh
        if (!websocketRefreshInterval){
          log(`Scheduling websocket refresh`)
          mySense.openStream();
          websocketRefreshInterval = setInterval(() => {
            mySense.openStream();
          }, 1000*60);
        }

        //If no devices yet, just send empty 200
        if (!deviceList || !websocketDataIsPresent || deviceList[totalDeviceId].usage == 0){
          log(`Data not ready yet - try again next time.`);
          res.send({});
          return;
        }

        //If devices are there, push it over
        let arrayResult = [];
        for (let devId of Object.keys(deviceList)){
            arrayResult.push(deviceList[devId])
        }
        res.send(arrayResult);
        return;

    } catch (error) {
      log(`Refresh error: ${error.message} ${error.stack}`, 1);
      resetAuth();
      res.status(500).send(error.message);
    }
  })


  function setupWebsocketEvents(){
    mySense.events.on('data', (data) => {
        try {
            //Check for loss of authorization. If detected, try to reauth
            if (data.payload.authorized == false){
                log('Authentication failed. Trying to reauth...');
                resetAuth();
                return;
            }

            //Set processing flag so we only send through and process one at a time
            if (!isProcessing && data.type === "realtime_update" && data.payload && data.payload.devices) {
                isProcessing = true;
                websocketDataIsPresent = true;
                mySense.closeStream();

                //Set all devices (except our virtual "total" one) back to 0 and let websocket payload go on top
                for (let devId of Object.keys(deviceList)){
                  if (devId != totalDeviceId){
                    deviceList[devId].state = 'off';
                    deviceList[devId].usage = 0;
                  }
                }


                for (let dev of data.payload.devices) {
                    if (!deviceList[dev.id]){
                        log(`Device missing: ${dev.id}`);
                    }

                    //Don't go below 1 watt
                    if (convUsage(deviceList[dev.id].usage) < 1) {
                        deviceList[dev.id].usage = convUsage(1);
                    }

                    deviceList[dev.id].usage = convUsage(dev.w);
                    deviceList[dev.id].state = "on";
                }
                lastSocketUpdate = new Date();
                deviceList[totalDeviceId].usage = convUsage(data.payload.w);
            }

            return 0;
        } catch (error) {
            log(`Data processing error: ${error.message}`, 1);
        }
    });

    //Handle closures and errors
    mySense.events.on('close', (data) => {
      isProcessing = false;
    });
    mySense.events.on('error', (data) => {
        log(`Socket error ${data.message}`);
    });
}

//Status endpoint for troubleshooting
app.get('/status', async (req, res) => {
    try {
        if (!mySense){
            return res.status(200).send('Awaiting login');
        }

        let arrayResult = [];
        for (let devId of Object.keys(deviceList)){
            arrayResult.push(deviceList[devId])
        }

        if (arrayResult.length == 0){
            return res.status(200).send('No devices detected');
        }

        res.send(arrayResult);

    } catch (error) {
      log(`status error: ${error.message}`, 1);
      res.status(500).send(error.message);
    }
  })


//Format usage
function convUsage(val, rndTo = 2) {
    if (val !== -1) {
        val = parseInt(val).toFixed(rndTo);
    }
    return parseInt(val);
}

//Express webserver startup
let expressApp = app.listen(port, () => {
    port = expressApp.address().port
    log(`Sense HTTP server listening on port ${port}`);
    startSsdp();
  })

  //Set up ssdp
  function startSsdp() {
    var Server = require('node-ssdp-response').Server
    , server = new Server(
      {
          location: 'http://' + '0.0.0.0' + `:${port}/details`,
          udn: 'uuid:smartthings-brbeaird-sense',
            sourcePort: 1900,
          ssdpTtl: 2,
          allowWildcards : false
      }
    );
    server.addUSN(ssdpId);
    server.start();
    log(`SSDP server up and listening for broadcasts: ${Object.keys(server._usns)[0]}`)

    checkVersion();
    setInterval(() => {
      checkVersion();
    }, 1000*60*60); //Check every hour

    //I tweaked ssdp library to bubble up a broadcast event and to then do an http post to the URL
    // this is because this app cannot know its external IP if running as a docker container
    server.on('response', async function (headers, msg, rinfo) {
      try {
        if (headers.ST != ssdpId || !headers.SERVER_IP || !headers.SERVER_PORT){
          return;
        }
        let hubAddress = `http://${headers.SERVER_IP}:${headers.SERVER_PORT}/ping`
        log(`Detected SSDP broadcast. Posting details back to ST hub at ${hubAddress}`)
        await axios.post(hubAddress,
          {
            senseServerPort: port,
            deviceId: headers.DEVICE_ID
          },
          {timeout: 5000})
      } catch (error) {
          let msg = error.message;
          if (error.response){
            msg += error.response.data
        }
        log(msg, true);
      }
    });
  }

  async function checkVersion(){
    try {
      let response = await axios.post('https://version.brbeaird.com/getVersion',
      {
        app: 'senseEdge',
        currentVersion: VERSION
      },
      {timeout: 15000})
    if (response.data?.version && response.data?.version != VERSION){
      log(`Newer server version is available (${VERSION} => ${response.data?.version})`);
    }
    return;
    } catch (error) {}
  }


  //Logging with timestamp
function log(msg, isError) {
    let dt = new Date().toLocaleString();
    if (!isError) {
      console.log(dt + ' | ' + msg);
    }
    else{
      console.error(dt + ' | ' + msg);
    }
  }

//Handle uncaught errors
process.on('uncaughtException', (error) => {
    log(error.stack, true);
    }
)