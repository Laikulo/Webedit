local baseUrl = "http://we.haun.guru";

local commandEndpoint = baseUrl .. "/getcmd";
local responseEndpoint = baseUrl .."/response";
local connectEndpoint = baseUrl .. "/connect";

local sessionId = "";
local sessionKey = "";
local connectKey = "";

local commands = {};

local toJSON;

local function getKeys()
  local httpresp = http.post(connectEndpoint,nil)
  if not httpresp then
    error("Could not reach server")
  end
  local resp = httpresp.readAll();
  local rd = textutils.unserialize(resp);
  print("Connected to server, use "..rd.c.." to connect!");
  sessionId = rd.i;
  sessionKey = rd.k;
  connectKey = rd.c;
end

local function die(code,reason)
  return {err = {code = code, reason = reason}};
end

local function sendCommandResponse(resp)
  payload = { i = sessionId, k = sessionKey, r = resp};
  http.post(responseEndpoint,toJSON(payload));
end


local function waitForCommand()
  local shouldStop = false;
  while not shouldStop do
    res = http.post(commandEndpoint,toJSON({i = sessionId, k = sessionKey}));
    if res then
      local rawCmd = res.readAll();
      cmd = textutils.unserialize(rawCmd);
      if not cmd then
      else
        if not cmd.action then
          sendCommandResponse(die(400, "Malformed Command"));
        else
          if not commands[cmd.action] then
            print("Unknown command: " .. cmd.action);
            sendCommandResponse(die(410,"Unknown Command"));
          else
            local function cmdCall() 
              shouldStop = not commands[cmd.action](cmd);
            end
            local nErr, err = pcall(cmdCall);
            if not nErr then
              print("Command error (" .. cmd.action .. "): " .. err);
              shouldStop = false; --Force continue on LUA errors
              sendCommandResponse(die(500,"Lua Error: " .. err));
            end
          end
        end
      end
    end
  end
end

function commands.testError(call)
  error(call.e or "Test Error");
end

function commands.ping(call)
  sendCommandResponse(call);
  return true;
end

function commands.lua(call)
  call.r = loadstring(call.code)(call.arg or nil);
  sendCommandResponse(call);
  return true;
end

function commands.pwd(call)
  call.pwd = shell.dir();
  sendCommandResponse(call);
  return true;
end

function commands.ls(call)
  if not call.dir then
    sendCommandResponse(die(401, "No target specified"));
    return true;
  end
  if not fs.isDir(call.dir) then
    sendCommandResponse(die(405, "No such directory"));
    return true;
  end
  local list = fs.list(call.dir);
  call.ls = {};
  for item in pairs(list) do
    local itempath = fs.combine(call.dir, list[item]);
    call.ls[list[item]] = {
      dir = fs.isDir(itempath),
      ro = fs.isReadOnly(itempath),
      size = fs.getSize(itempath)};
  end
  sendCommandResponse(call);
  return true;
end

function commands.cat(call)
  if not call.file then
    sendCommandResponse(die(401, "No target specified"));
    return true;
  end
  if not fs.exists(call.file) then
    sendCommandResponse(die(404,"No such file"));
    return true;
  end
  local fp = fs.open(call.file, "rb");
  if not fp then
		sendCommandResponse(die(402,"Unable to open file for reading"));
		return true;
  end
  local done = false;
  local file = "";
  while not done do
    local charBuffer = fp.read();
    if not charBuffer then
      done=true;
    else
      file = file .. string.char(charBuffer);
    end
  end
  call.f = file;
  fp.close();
  sendCommandResponse(call);
  return true;
end

function commands.write(call)
  fp = fs.open(call.file, "w");
	if not fp then
		sendCommandResponse(die(403,"Unable to open file for writing. (probably read-only)"));
		return true;
  end
  local done = false;
  fp.write(call.txt);
  fp.close();
  call.txt = nil; --scrubbed because we don't need it
  sendCommandResponse(call);
  return true;
end

function commands.dl(call)
  print("Dl'ing "..call.src.." to "..call.dst);
  local fp = fs.open(call.dst,"w");
  fp.write(http.get(call.src).readAll());
  fp.close();
  sendCommandResponse(call);
  --TODO: Streamline this
  return true
end

function commands.exit(call)
  call.exit="exiting";
  sendCommandResponse(call);
  print("Thank you for using webedit!");
  return false; --end
end

local function jsonReplaceWrapper(passfn,str,repl)
  return function (obj)
    return string.gsub(passfn(obj),str,repl)
  end
end

local function testJsonEscape(char, escape, fn)
  local inString = "Hello" .. char .. "World";
  local expectedString = "\"Hello" .. escape .."World\"";
  local outStr = fn(inString);
  if outStr ~= expectedString then
    print("Expected: "..expectedString);
    print("Recieved: "..outStr)
    return false
  else
    return true;
  end
end

local function setupJson()
  local jsonTest = {
  { name = "newlines" ,char = "\n", escape = "\\n", repl = "n"}, --Lua escapes literal newlines
  { name = "tabs", char = string.char(9), escape = "\\t"}
  };
  print("Setting up JSON...");
  toJSON = textutils.serializeJSON;
  for _,test in pairs(jsonTest) do
    print("Testing Json " .. test.name);
    if not testJsonEscape(test.char, test.escape, toJSON) then
      print("Failed, applying workaround");
      toJSON = jsonReplaceWrapper(toJSON, test.find or test.char, test.repl or test.escape);
      if not testJsonEscape(test.char, test.escape, toJSON) then
        error("Workaround for " .. test.name .. " failed");
      else
        print("Workaround Successful");
      end
    end
  end
end


setupJson();
getKeys();
waitForCommand();
