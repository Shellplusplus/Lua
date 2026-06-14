-- Terminal.lua
-- Shell 终端桥接表盘
-- 接收快应用的命令请求 → os.execute → 写回结果

local TARGET_DIR = '/data/quickapp/files/com.shell.liangyi/'
local CMD_TIMEOUT = 10000  -- 命令超时：10 秒



local isRunning = false
local cmdTimer = nil
local heartbeatTimer = nil
local watchdogTimer = nil
local statusBuffer = {}
local cmdBusy = false
local cmdStartTime = nil
local currentCmd = ''
local currentReq = nil

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

-- ====== JSON 解码器 ======

local function jsonDecode(json)
    local pos = 1
    local len = #json

    -- 前向声明互递归的局部函数
    local parseValue, parseObject, parseArray

    local function skipWS()
        while pos <= len do
            local c = json:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parseString()
        pos = pos + 1
        local parts = {}
        while pos <= len do
            local c = json:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == '\\' then
                pos = pos + 1
                if pos > len then error('unterminated escape') end
                local esc = json:sub(pos, pos)
                if     esc == '"' then parts[#parts+1] = '"'
                elseif esc == '\\' then parts[#parts+1] = '\\'
                elseif esc == '/'  then parts[#parts+1] = '/'
                elseif esc == 'n'  then parts[#parts+1] = '\n'
                elseif esc == 'r'  then parts[#parts+1] = '\r'
                elseif esc == 't'  then parts[#parts+1] = '\t'
                else error('bad escape: \\' .. esc) end
                pos = pos + 1
            else
                parts[#parts+1] = c
                pos = pos + 1
            end
        end
        error('unterminated string')
    end

    local function parseNumber()
        local start = pos
        if json:sub(pos, pos) == '-' then pos = pos + 1 end
        if json:sub(pos, pos) == '0' then
            pos = pos + 1
        elseif json:sub(pos, pos) >= '1' and json:sub(pos, pos) <= '9' then
            repeat pos = pos + 1 until pos > len or json:sub(pos, pos) < '0' or json:sub(pos, pos) > '9'
        else
            error('invalid number')
        end
        if json:sub(pos, pos) == '.' then
            pos = pos + 1
            if pos > len or json:sub(pos, pos) < '0' or json:sub(pos, pos) > '9' then error('invalid fraction') end
            repeat pos = pos + 1 until pos > len or json:sub(pos, pos) < '0' or json:sub(pos, pos) > '9'
        end
        local c = json:sub(pos, pos)
        if c == 'e' or c == 'E' then
            pos = pos + 1
            c = json:sub(pos, pos)
            if c == '+' or c == '-' then pos = pos + 1 end
            if pos > len or json:sub(pos, pos) < '0' or json:sub(pos, pos) > '9' then error('invalid exponent') end
            repeat pos = pos + 1 until pos > len or json:sub(pos, pos) < '0' or json:sub(pos, pos) > '9'
        end
        local num = tonumber(json:sub(start, pos - 1))
        if not num then error('bad number') end
        return num
    end

    parseObject = function()
        pos = pos + 1
        local obj = {}
        skipWS()
        if json:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while true do
            skipWS()
            if json:sub(pos, pos) ~= '"' then error('expected string key') end
            local key = parseString()
            skipWS()
            if json:sub(pos, pos) ~= ':' then error('expected :') end
            pos = pos + 1
            obj[key] = parseValue()
            skipWS()
            local c = json:sub(pos, pos)
            if c == '}' then pos = pos + 1; return obj end
            if c ~= ',' then error('expected , or }') end
            pos = pos + 1
        end
    end

    parseArray = function()
        pos = pos + 1
        local arr = {}
        skipWS()
        if json:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        local idx = 1
        while true do
            arr[idx] = parseValue()
            idx = idx + 1
            skipWS()
            local c = json:sub(pos, pos)
            if c == ']' then pos = pos + 1; return arr end
            if c ~= ',' then error('expected , or ]') end
            pos = pos + 1
        end
    end

    parseValue = function()
        skipWS()
        if pos > len then error('unexpected end') end
        local c = json:sub(pos, pos)
        if     c == '"' then return parseString()
        elseif c == '{' then return parseObject()
        elseif c == '[' then return parseArray()
        elseif c == 't' then
            if json:sub(pos, pos+3) == 'true' then pos = pos + 4; return true end
            error('bad literal')
        elseif c == 'f' then
            if json:sub(pos, pos+4) == 'false' then pos = pos + 5; return false end
            error('bad literal')
        elseif c == 'n' then
            if json:sub(pos, pos+3) == 'null' then pos = pos + 4; return nil end
            error('bad literal')
        elseif c == '-' or (c >= '0' and c <= '9') then
            return parseNumber()
        else
            error('unexpected: ' .. c)
        end
    end

    local ok, result = pcall(function()
        skipWS()
        local val = parseValue()
        skipWS()
        return val
    end)
    if not ok then return nil end
    return result
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

    local outFile = '/tmp/shell_stdout.txt'
    os.remove(outFile)

    local fullCmd = cmd .. ' > ' .. outFile
    pcall(os.execute, fullCmd)

    -- 读取输出
    local function readAll(path, maxLen)
        local f = io.open(path, 'r')
        if not f then return '' end
        local text = ''
        for line in f:lines() do text = text .. line .. '\n' end
        f:close()
        if #text > maxLen then text = text:sub(1, maxLen) .. '\n... [truncated at ' .. (maxLen/1024) .. 'KB]' end
        return text
    end

    local stdout = readAll(outFile, 32768)

    -- 有输出 = 命令执行成功
    local exitcode = 0
    local stderr = ''
    if stdout == '' then
        exitcode = -1
        stdout = '(no output)'
    end

    addLog('[' .. ts .. '] Done (' .. #stdout .. ' bytes)')
    return { stdout = stdout, stderr = stderr, exitcode = exitcode }
end

-- ====== 读取命令请求 ======

local lastParseError = 0

local function readCommandRequest()
    local reqFile = TARGET_DIR .. 'cmd_request.json'
    if not fileExists(reqFile) then return nil end

    local content = readFile(reqFile)
    if not content or content == '' then return nil end

    local json = jsonDecode(content)
    if not json then
        -- 可能是文件正在被写入，等 100ms 重试一次
        os.execute('sleep 0.1')
        content = readFile(reqFile)
        if not content or content == '' then return nil end
        json = jsonDecode(content)
        if not json then
            -- 连续两次失败才记日志（限频率）
            local now = os.time()
            if now - lastParseError >= 5 then
                addLog('[!] JSON parse error (retried)')
                lastParseError = now
            end
            return nil
        end
    end
    if not json.seq or not json.cmd then
        return nil
    end
    return { seq = json.seq, cmd = json.cmd }
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

    local timedOutCmd = currentCmd
    local timedOutReq = currentReq
    addLog('[!] Command timed out: ' .. timedOutCmd)

    local res = {
        type = 'cmd_result',
        seq = timedOutReq and timedOutReq.seq or -1,
        cmd = timedOutCmd,
        stdout = '',
        stderr = 'Error: Command timed out (' .. CMD_TIMEOUT .. 'ms)',
        exitcode = -1,
        timestamp = os.date('%H:%M:%S')
    }
    atomicWrite('cmd_result.json', res)
    os.remove(TARGET_DIR .. 'cmd_request.json')
    cmdBusy = false
    currentCmd = ''
    currentReq = nil
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
    currentReq = req
    cmdStartTime = os.clock() or 0
    local result = executeShellCommand(req.cmd)
    writeCommandResult(req, result)
    cmdBusy = false
    currentCmd = ''
    currentReq = nil
    cmdStartTime = nil
end

-- ====== 心跳 ======

local function writeHeartbeat()
    local data = {
        type = 'system_info',
        timestamp = tostring(os.time())
    }
    atomicWrite('system_info.json', data)
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

terminal:set { text = "=== Terminal Bridge ===\nStatus: STOPPED\n\nPress START\n\nDir: /data/quickapp/files/com.shell.liangyi/" }
