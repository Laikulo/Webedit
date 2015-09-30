local baseUrl;

if _WEBEDIT_ALTERNATE_BASE then
  baseUrl = _WEBEDIT_ALTERNATE_BASE;
  print("Using alternate base URL: " .. baseUrl)
else
  baseUrl = "http://we.haun.guru";
end

local commandEndpoint = baseUrl .. "/getcmd";
local responseEndpoint = baseUrl .."/response";
local connectEndpoint = baseUrl .. "/connect";

local sessionId = "";
local sessionKey = "";
local connectKey = "";

local commands = {};

local toJSON;

---- U T I L I T Y  F U N C T I O N S ----

local function die(code,reason)
  return {err = {code = code, reason = reason}};
end

---- S E R V E R  I N T E R A C T I O N ----

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

---- C O M M A N D S ----

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

---- V I R T U A L  T E R M I N A L ----

local terminalBase = {
  xPos = 1,
  yPos = 1,
  height = 10,
  width = 10,
  bgColor = colors.black,
  textColor = colors.white,
  cursorBlink = false
};

function terminalBase.addChar(self, char, fgcolor, bgcolor)
  if self.xPos <= self.width then
    self.chars[self.yPos][self.xPos] = char;
    self.fgColors[self.yPos][self.xPos] = fgcolor;
    self.bgColors[self.yPos][self.xPos] = bgcolor;
    self.xPos = self.xPos + 1;
  end
end

function terminalBase.setSize(self,width,height)
  --Initialize a terminal to all spaces
  for y = 1, height do
    self.chars[y] = {};
    self.bgColors[y] = {};
    self.fgColors[y] = {};
    for x = 1, width do
      self.chars[y][x] = 32;
      self.bgColors[y][x] = colors.black;
      self.fgColors[y][x] = colors.white;
    end
  end
  self.width = width;
  self.height = height;
  self.xPos = 1;
  self.yPos = 1;
  --Terminal resize events are not yet supported
end

function terminalBase.writeImpl(self,str)
  for i = 1, #str do
    self.addChar(self,string.byte(string.sub(str,i,i)),self.textColor, self.bgColor)
  end
end


local colorTable = { ---This color table is used by the blit implementation
  ["0"] = colors.black,
  ["1"] = colors.blue,
  ["2"] = colors.green,
  ["3"] = colors.cyan,
  ["4"] = colors.red,
  ["5"] = colors.purple,
  ["6"] = colors.orange,
  ["7"] = colors.lightGray,
  ["8"] = colors.gray,
  ["9"] = colors.lightBlue,
  ["a"] = colors.lime,
  ["b"] = colors.cyan, --Ummm no aqua?
  ["c"] = colors.pink,
  ["d"] = colors.magenta,
  ["e"] = colors.yellow,
  ["f"] = colors.white
}

function terminalBase.blitImpl(self,tStr,fStr,bStr)
  for i = 1, #tStr do
    self.addChar(self,
      string.byte(string.sub(tStr,i,i)),
      colorTable[string.sub(fStr,i,i)],
      colorTable[string.sub(bStr,i,i)])
  end
end

function terminalBase.clearImpl(self)
  --CC's clear fills with spaces, with BGcolor and fgcolor set
  for y = 1, self.height do
    for x = 1, self.width do
      self.chars[y][x] = 32;
      self.bgColors[y][x] = self.bgColor;
      self.fgColors[y][x] = self.textColor;
    end
  end
end

function terminalBase.clearLineImpl(self)
  for x = 1, self.width do
    self.chars[self.yPos][x] = 32
    self.bgColors[self.yPos][x] = self.bgColor
    self.fgColors[self.yPos][x] = self.textColor
  end
end

function terminalBase.getCursorPosImpl(self)
  return self.xPos, self.yPos
end

function terminalBase.setCursorPosImpl(self,x,y)
  self.xPos = x
  self.yPos = y
end

function terminalBase.getSizeImpl(self)
  return self.width, self.height
end

function terminalBase.scrollImpl(self,t)
  error("terminal scroll is not yet implemented")
end

function terminalBase.redirectImpl(self,target)
  error("terminal redirection is not yet implemented")
end

function terminalBase.nativeImpl(self)
  error("the terminal native call is not supported")
end

function terminalBase.setTextColorImpl(self,color)
  self.textColor = color
end

function terminalBase.getTextColorImpl(self)
  return self.textColor
end

function terminalBase.setBackgroundColorImpl(self,color)
  self.bgColor = color
end

function terminalBase.getBackgroundColorImpl(self)
  return self.bgColor;
end

local function newTerminal()
  local terminal = {};
  setmetatable(terminal, {__index = terminalBase});
  ---- Function shims ----
  terminal.write = function (str) terminal.writeImpl(terminal,str) end;
  terminal.blit = function (text,colors,bgcolors) terminal.blitImpl(terminal,text,colors,bgcolors) end;
  terminal.clear = function () terminal.clearImpl(terminal) end;
  terminal.clearLine = function () terminal.clearLineImpl(terminal) end;
  terminal.getCursorPos = function () return terminal.getCursorPosImpl(terminal) end;
  terminal.setCursorPos = function (x,y) terminal.setCursorPosImpl(terminal,x,y) end;
  terminal.isColor = function () return terminal.isColorImpl(terminal) end;
  terminal.getSize = function () return terminal.getSizeImpl(terminal) end;
  terminal.scroll = function (n) terminal.scrollImpl(terminal,n) end;
  terminal.redirect = function (targetTerm) return terminal.redirectImpl(targetTerm) end;
  terminal.current = function () return terminal.currentImpl(terminal) end;
  terminal.native = function () return terminal.nativeImpl(terminal) end;
  terminal.setTextColor = function (color) terminal.setTextColorImpl(terminal,color) end;
  terminal.getTextColor = function () return terminal.getTextColorImpl(terminal,color) end;
  terminal.setBackgroundColor = function (color) terminal.setBackgroundColorImpl(terminal,color) end;
  terminal.getBackgroundColor = function () return terminal.getBackgroundColorImpl(terminal) end;
  ---- Per-instace variables ----
  terminal.chars = {};
  terminal.fgColors = {};
  terminal.bgColors = {};
  return terminal;
end

---- J S O N  F I X E S ----

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

local function startDebugShell()
  debugEnv = {
    newTerminal = newTerminal,
    terminalBase = terminalBase,
    colorTable = colorTable
  }
  os.run(debugEnv, "rom/programs/lua");
end

if _WEBEDIT_DEBUG_SHELL then
  startDebugShell();
else
  setupJson();
  getKeys();
  waitForCommand();
end