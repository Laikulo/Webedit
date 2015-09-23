
var sessionKey = ""; //These are local, and should NEVER be exposed to other JS
var sessionId = "";


/**
 * sendCommand
 * asynchronously sends a command to the server
 * @param data object a JSON object to send as the command
 * @param callback function(req,resp) a function to call with the request and response
 * @returns nothing
 */
function sendCommand (data, callback){
    var xhr = new XMLHttpRequest();
    xhr.open("POST","/qcmd", true);
    xhr.onload = function(){
        var JSONObj;
        try {
            JSONObj = JSON.parse(xhr.responseText);
        } catch(e) {
            console.log("Non JSON recieved!", xhr.responseText);
            return false;
        }
        callback(data,JSONObj);
    };
    xhr.send(JSON.stringify({
        i: sessionId,
        k: sessionKey,
        cmd: data
    }));
}

/**
 * hasSession
 * check if a session exists on the clientside. The session may not be valid, though
 * @returns boolean true if a session exists
 */
function hasSession(){
    'use strict';
    return !(sessionKey === "" || sessionId === "")
}

/**
 * clearSession
 * clears session variables, effectively logging out
 */
function clearSession(){
    'use strict';
    sessionId = "";
    sessionKey = "";
}

/**
 * connectWithHey
 * connects to a session using a specified key.
 * This is synchronous, and will block until completion
 * @param key string the connection key to to use
 * @returns boolean true if the authentication was successful
 */
function connectWithKey(key) {
    'use strict';
    var xhr = new XMLHttpRequest();
    xhr.open("POST","/attach",false);
    xhr.send(key.toUpperCase());
    var resp = JSON.parse(xhr.responseText);
    if(resp.hasOwnProperty("err")){
        console.log(resp.err);
        return false;
    }
    sessionId = resp.i;
    sessionKey = resp.k;
    return true;
}