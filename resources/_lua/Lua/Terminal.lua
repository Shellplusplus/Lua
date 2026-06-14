-- Terminal.lua
-- Shell 终端桥接表盘
-- 接收快应用的命令请求 → os.execute → 写回结果

local TARGET_DIR = '/data/quickapp/files/com.shell.project/'
local CMD_TIMEOUT = 10000  -- 命令超时：10 秒

local isRunning = false
local cmdTimer = nil
local heartbeatTimer = nil
local watchdogTimer = nil
local statusBuffer = {}
local cmdBusy = false
local cmdStartTime = nil
local currentCmd = ''

-- ====== UI ======

local root = lvgl.Object(nil, {
    w = lvgl.HOR_RES(),
    h = lvgl.VER_RES(),
    align = lvgl.ALIGN.CENTER,
    border_width = 0,
    bg_color = '#000000',
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

lvgl.Label(root, {
    x = 0, y = 2,
    w = lvgl.HOR_RES(), h = 28,
    text = "Terminal Bridge",
    font_size = 16,
    text_color = '#00ff00',
    align = lvgl.ALIGN.CENTER,
})

local terminal = lvgl.Textarea(root, {
    w = lvgl.HOR_RES() - 10,
    h = lvgl.VER_RES() - 110,
    x = 5,
    y = 32,
    text = '',
    bg_color = '#000000',
    font_size = 18,
    text_color = '#00ff00',
    border_width = 0
})
terminal:clear_flag(lvgl.FLAG.SCROLLABLE)

local controlPanel = lvgl.Object(root, {
    x = 0,
    y = lvgl.VER_RES() - 72,
    w = lvgl.HOR_RES(),
    h = 72,
    bg_color = '#111111',
    border_width = 0
})
controlPanel:clear_flag(lvgl.FLAG.SCROLLABLE)

local startStopBtn = lvgl.Label(controlPanel, {
    x = 10, y = 5, w = 100, h = 40,
    text = "START", radius = 5,
    border_width = 1, border_color = '#00ff00',
    bg_color = '#004400', font_size = 28, text_color = '#00ff00'
})
startStopBtn:add_flag(lvgl.FLAG.CLICKABLE)

local clearBtn = lvgl.Label(controlPanel, {
    x = 120, y = 5, w = 100, h = 40,
    text = "CLEAR", radius = 5,
    border_width = 1, border_color = '#ffaa00',
    bg_color = '#443300', font_size = 28, text_color = '#ffaa00'
})
clearBtn:add_flag(lvgl.FLAG.CLICKABLE)

-- ====== 工具函数 ======

local function readFile(path)
    local ok, f = pcall(io.open, path, 'r')
    if not ok or not f then return nil end
    local c = f:read('*all')
    f:close()
    return c
end

local function writeFile(path, content)
    local ok, f = pcall(io.open, path, 'w')
    if not ok or not f then return false end
    f:write(content)
    f:close()
    return true
end

local function fileExists(path)
    local ok, f = pcall(io.open, path, 'r')
    if ok and f then f:close(); return true end
    return false
end

local function addLog(line)
    table.insert(statusBuffer, 1, line)
    while #statusBuffer > 25 do table.remove(statusBuffer) end
    local t = "=== Terminal Bridge ===\n"
    t = t .. "Status: " .. (isRunning and "RUNNING" or "STOPPED") .. "\n"
    t = t .. "Busy: " .. tostring(cmdBusy) .. "\n"
    t = t .. string.rep("-", 28) .. "\n"
    for i = 1, #statusBuffer do
        t = t .. statusBuffer[i] .. "\n"
    end
    terminal:set { text = t }
end

-- ====== JSON ======

local function jsonEncode(val)
    local t = type(val)
    if t == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == 'number' then
        if val == math.floor(val) then return string.format('%d', val) end
        return string.format('%g', val)
    elseif t == 'boolean' then return tostring(val)
    elseif t == 'nil' then return 'null'
    elseif t == 'table' then
        local parts, maxNum, count = {}, 0, 0
        for k in pairs(val) do
            count = count + 1
            if type(k) == 'number' and k > maxNum then maxNum = k end
        end
        if maxNum == count then
            for i = 1, count do parts[#parts+1] = jsonEncode(val[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local keys = {}
            for k in pairs(val) do keys[#keys+1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                parts[#parts+1] = jsonEncode(k) .. ':' .. jsonEncode(val[k])
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

-- ====== 原子写入 ======

local writeSeq = 0

local function atomicWrite(filename, data)
    data._seq = writeSeq
    data._writeTime = os.date('%H:%M:%S')
    writeSeq = writeSeq + 1
    local json = jsonEncode(data)
    local tmp = TARGET_DIR .. '.' .. filename .. '.tmp'
    local path = TARGET_DIR .. filename

    os.execute('mkdir -p ' .. TARGET_DIR)
    local ok = writeFile(tmp, json)
    if not ok then return false end
    os.remove(path)
    os.execute('mv "' .. tmp .. '" "' .. path .. '"')
    return true
end

-- ====== 命令执行 ======

local function executeShellCommand(cmd)
    if not cmd or cmd == '' then
        return { stdout = '', stderr = '', exitcode = -1 }
    end

    local ts = os.date('%H:%M:%S')
    addLog('[' .. ts .. '] Exec: ' .. cmd)

    local logFile = '/tmp/shell_out.txt'
    os.remove(logFile)

    pcall(os.execute, cmd .. ' > ' .. logFile)

    local text = ''
    local f = io.open(logFile, 'r')
    if f then
        for line in f:lines() do text = text .. line .. '\n' end
        f:close()
    end

    if text == '' then text = '(no output)' end
    if #text > 32768 then text = text:sub(1, 32768) .. '\n... [truncated at 32KB]' end

    addLog('[' .. ts .. '] Done (' .. #text .. ' bytes)')
    return { stdout = text, stderr = '', exitcode = 0 }
end

-- ====== 读取命令请求 ======

local function readCommandRequest()
    local reqFile = TARGET_DIR .. 'cmd_request.json'
    if not fileExists(reqFile) then return nil end

    local content = readFile(reqFile)
    if not content or content == '' then return nil end

    local ok, req = pcall(function()
        local seq = content:match('"seq"%s*:%s*(%-?%d+)')
        local cmd = content:match('"cmd"%s*:%s*"([^"]*)"')
        if seq and cmd then return { seq = tonumber(seq), cmd = cmd } end
        return nil
    end)

    if not ok then addLog('[!] parse error'); return nil end
    if not req then addLog('[!] missing seq/cmd'); return nil end
    return req
end

-- ====== 写入命令结果 ======

local function writeCommandResult(req, result)
    local res = {
        type = 'cmd_result', seq = req.seq, cmd = req.cmd,
        stdout = result.stdout, stderr = result.stderr,
        exitcode = result.exitcode, timestamp = os.date('%H:%M:%S')
    }
    atomicWrite('cmd_result.json', res)
    os.remove(TARGET_DIR .. 'cmd_request.json')
end

-- ====== 看门狗：检测命令超时 ======

local function watchdogCheck()
    if not cmdBusy then return end
    if not cmdStartTime then return end
    local elapsed = (os.clock() or 0) - cmdStartTime
    if elapsed * 1000 < CMD_TIMEOUT then return end

    addLog('[!] Command timed out: ' .. currentCmd)
    local res = {
        type = 'cmd_result',
        stdout = '',
        stderr = 'Error: Command timed out (' .. CMD_TIMEOUT .. 'ms)',
        exitcode = -1,
        timestamp = os.date('%H:%M:%S')
    }
    atomicWrite('cmd_result.json', res)
    os.remove(TARGET_DIR .. 'cmd_request.json')
    cmdBusy = false
    currentCmd = ''
    cmdStartTime = nil
end

-- ====== 定时器回调 ======

local function checkCommandRequest()
    if cmdBusy then return end
    if not isRunning then return end

    local req = readCommandRequest()
    if not req then return end

    cmdBusy = true
    currentCmd = req.cmd
    cmdStartTime = os.clock() or 0
    local result = executeShellCommand(req.cmd)
    writeCommandResult(req, result)
    cmdBusy = false
    currentCmd = ''
    cmdStartTime = nil
end

-- ====== 心跳 ======

local function writeHeartbeat()
    local ts = os.date('%H:%M:%S')
    local json = '{"type":"system_info","timestamp":"' .. ts .. '"}'
    local path = TARGET_DIR .. 'system_info.json'
    os.execute('mkdir -p ' .. TARGET_DIR)
    local ok, f = pcall(io.open, path, 'w')
    if not ok or not f then return end
    f:write(json)
    f:close()
end

-- ====== 启动/停止 ======

local function startService()
    if isRunning then return end
    isRunning = true; cmdBusy = false
    os.execute('mkdir -p ' .. TARGET_DIR)
    addLog('>>> Service Started')

    cmdTimer = lvgl.Timer({ period = 500, repeat_count = -1,
        cb = function() if isRunning then checkCommandRequest() end end })
    cmdTimer:resume()

    heartbeatTimer = lvgl.Timer({ period = 5000, repeat_count = -1,
        cb = function() if isRunning then writeHeartbeat() end end })
    heartbeatTimer:resume()

    watchdogTimer = lvgl.Timer({ period = 1000, repeat_count = -1,
        cb = function() if isRunning then watchdogCheck() end end })
    watchdogTimer:resume()

    startStopBtn:set { text = "STOP", bg_color = '#440000', border_color = '#ff0000', text_color = '#ff0000' }
end

local function stopService()
    if not isRunning then return end
    isRunning = false
    if cmdTimer then cmdTimer:pause() end
    if heartbeatTimer then heartbeatTimer:pause() end
    if watchdogTimer then watchdogTimer:pause() end
    addLog('>>> Service Stopped')
    startStopBtn:set { text = "START", bg_color = '#004400', border_color = '#00ff00', text_color = '#00ff00' }
end

local function clearLog()
    statusBuffer = {}
    local t = "=== Terminal Bridge ===\nStatus: " .. (isRunning and "RUNNING" or "STOPPED") .. "\nBusy: " .. tostring(cmdBusy) .. "\n" .. string.rep("-", 28) .. "\n"
    terminal:set { text = t }
end

-- ====== 按钮事件 ======

startStopBtn:onevent(lvgl.EVENT.CLICKED, function()
    if isRunning then stopService() else startService() end
end)
clearBtn:onevent(lvgl.EVENT.CLICKED, function() clearLog() end)

-- ====== 初始状态 ======

terminal:set { text = "=== Terminal Bridge ===\nStatus: STOPPED\n\nPress START\n\nDir: /data/quickapp/files/com.shell.project/" }
