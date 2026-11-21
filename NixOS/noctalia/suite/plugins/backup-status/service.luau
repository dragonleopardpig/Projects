--!nonstrict
-- Singleton background service: streams `backup-pool watch` into noctalia.state.
-- The helper also sends the desktop notifications (failed, stalled, days without a backup).

local common = require("./common.luau")

local function publish(data)
  if type(data) == "table" then
    noctalia.state.set("snapshot", data)
  end
end

local function refreshOnce()
  local argv = common.helperArgv({ "status" })
  if argv == nil then
    publish({ available = false, state = "unavailable" })
    return
  end
  noctalia.runAsync(argv, function(res)
    publish(common.decode(res))
  end)
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshOnce()
  end
end

local streamCmd = common.helperCommand("watch")
if streamCmd ~= nil then
  noctalia.runStream(streamCmd, function(line)
    local ok, data = pcall(noctalia.json.decode, line)
    if ok then
      publish(data)
    end
  end)
else
  publish({ available = false, state = "unavailable" })
end
