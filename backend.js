var express = require('express');
var app = express();


var http = require("http");
var fs = require("fs");

var events = require("events");

var commandEvent = new events.EventEmitter();
var responseEvent = new events.EventEmitter();

var clients = {};
var connectKeys = {};

function clientCleanup(){
    var now = (new Date).getTime();
    for(var clientId in clients){
        if(now - clients[clientId].lastSeen > 45000) { //45 seconds.
            var cKey = clients[clientId].connectKey;
            if(connectKeys.hasOwnProperty(cKey)){
                delete connectKeys[cKey]
            }
            delete clients[clientId];
        }
    }
}

setInterval(clientCleanup, 10000);

function Client(){
    this.clientKey = "";
    this.clientId = "";
    this.connectKey = "";
    this.lastSeen = (new Date).getTime();
    this.commandQueue = [];
}

var niceChars = "23456789CFGHJMPQRVWX";
function genTypableRandom(len){
    var out = "";
    for(var i=0;i<len;i++){
        out += niceChars.charAt(Math.random() * niceChars.length);
    }
    return out;
}

var printableChars = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[/]^+`abcdefghijklmnopqrstuvwxyz{|}~";
function genPrintableRandom(len){
    var out = "";
    for(var i=0;i<len;i++){
        out += printableChars.charAt(Math.random() * printableChars.length);
    }
    return out;
}

function luaEncode(obj){
    var out = "{";

    for(prop in obj){
        out +=  "["+JSON.stringify(prop)+"] = ";
        if(obj[prop] instanceof Object) { //both lua and JS use integer indexed objects as arrays.
            out += luaEncode(obj[prop]);
        }else if(obj[prop] instanceof String){
            //LUA escapes the newline character itself, instead of using \n
            out += JSON.stringify(obj[prop]).replace("\\n","\\\n");
        }else{
            out += JSON.stringify(obj[prop]);
        }
        out += ",";
    }

    out += "}";
    return out;
}


Client.prototype.genKeys = function (){
    this.clientId = genPrintableRandom(20);
    this.clientKey = genPrintableRandom(10);
    this.connectKey = genTypableRandom(4);
};

Client.prototype.getId = function (){
    return this.clientId;
};

Client.prototype.getKey = function (){
    return this.clientKey;
};

Client.prototype.getConnect = function (){
    return this.connectKey;
};

Client.prototype.checkKey = function (inKey){
    return this.clientKey === inKey;
};

function findClient(res,inData){
    var inJson;
    try {
	inJson = JSON.parse(inData);
	}catch(e){
	console.log("Recieved malformated JSON: ", e.message);
        res.end(jsonDie(100,"Bad Request"));
        return false;
	}
    if(!inJson || !inJson.hasOwnProperty("i") || ! inJson.hasOwnProperty("k")){
        res.end(jsonDie(100,"Bad Request"));
        return false;
    }
    if(!clients.hasOwnProperty(inJson.i)){
        res.end(jsonDie(101,"No such session or bad key"));
        return false;
    }
    var client = clients[inJson.i];
    if(!client.checkKey(inJson.k)){
        res.end(jsonDie(101,"No such session or bad key"));
        return false;
    }
    return client;
}

function jsonDie(code,reason){
	return JSON.stringify({
	err: {
	code: code,
	reason: reason
	}});
}

app.use(express.static('public'));

app.post('/getcmd', function(req,res){
    var inData = '';
    req.on('data', function (d) {
        inData += d;
        if(inData.length > 128)
            req.connection.destroy();
    });
    req.on('end', function () {
        var client = findClient(res,inData);
        if(!client) return; //Connection has already been dealt with
        client.lastSeen = (new Date).getTime();
        if(client.commandQueue.length > 0){
            res.end(client.commandQueue[0]);
            client.commandQueue.splice(0,1);
        }else{
            var deathTimeout;
            var cmdCallback = function(cmd) {
                clearTimeout(deathTimeout);
                res.end(luaEncode(cmd));
            };
            commandEvent.once(client.clientId, cmdCallback);
            deathTimeout = setTimeout(function (){
                commandEvent.removeListener(client.clientId, cmdCallback);
                res.end("{action=\"ping\"}");
            },20000);
        }
    });
});

app.post('/response', function (req,res){
    var respData = '';
    req.on('data', function (d) {
        respData += d;
        if(respData.length > 1e8)
            req.connection.destroy();
    });
    req.on('end', function () {
        var client = findClient(res,respData);
        if(!client) return;
        client.lastSeen = (new Date).getTime();
        var inJson = JSON.parse(respData);
        responseEvent.emit(client.clientId, inJson.r);
    });

    res.end();
});

app.post("/qcmd", function (req,res){
    var qData = '';
    req.on('data', function (d) {
        qData += d;
        if(qData.length > 1e8)
            req.connection.destroy();
    });
    req.on('end', function () {
        var client = findClient(res, qData);
        if(!client){
            return;
        }
        var inJson = JSON.parse(qData);
        var deathTimeout;
        var respCb =  function (d) {
            res.end(JSON.stringify(d));
            clearTimeout(deathTimeout);
        };
        deathTimeout = setTimeout(function (){
            res.end(jsonDie(200,"Timeout while waiting for response from ComputerCraft"));
            responseEvent.removeListener(client.clientId, respCb);
        },4000);
        responseEvent.once(client.clientId,respCb);
        if(!commandEvent.emit(client.clientId, inJson.cmd))
        client.commandQueue.push(inJson.cmd);
        console.log("Command Q'd: " + JSON.stringify(inJson.cmd));
    });
});

app.post("/attach", function (req,res){
   var inData = '';
    req.on('data', function (d) {
        inData += d;
        if(inData.length > 128)
        req.connection.destroy();
    });
    req.on('end', function () {
        if(connectKeys.hasOwnProperty(inData)){
            client = connectKeys[inData];
            res.end(JSON.stringify({k: client.getKey(), i: client.getId()}));
            delete connectKeys[inData];
        }else
            res.end(
        	jsonDie(101,"No such session or bad key")
            );
    });
});

app.post("/connect", function (req,res){
    var client = new Client();
    client.genKeys();
    var payload = {
        k : client.getKey(),
        i : client.getId(),
        c : client.getConnect()
    };
    clients[client.getId()] = client;
    connectKeys[client.getConnect()] = client;
    console.log("Client Connected: ",payload);
    res.end(luaEncode(payload));
});

app.post("/get", function (req, res) {
    res.write("Part One");
    setInterval(function (){
        res.end("Part the next");
    },2000);
});

app.listen(8889);
