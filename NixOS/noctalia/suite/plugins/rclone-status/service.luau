--!nonstrict
-- Singleton background service publishing rclone mounts & remotes snapshots via noctalia.state.

local common = require("./common.luau")

local function publish(data)
  if type(data) == "table" then
    noctalia.state.set("snapshot", data)
  end
end

local function refreshOnce()
  local argv = common.helperArgv({ "status" })
  if argv == nil then
    return
  end
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local data = noctalia.json.decode(res.stdout)
      publish(data)
    end
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
    local data = noctalia.json.decode(line)
    publish(data)
  end)
else
  refreshOnce()
end
