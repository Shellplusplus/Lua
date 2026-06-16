-- Terminal.lua
-- Shell 终端桥接表盘
-- 接收快应用的命令请求 → os.execute → 写回结果

local TARGET_DIR = '/data/quickapp/files/com.shell.liangyi/'
local CMD_TIMEOUT = 10000  -- 命令超时：10 秒
local SCREEN_W = lvgl.HOR_RES()
local SCREEN_H = lvgl.VER_RES()
local FB_PATH = '/dev/fb0'
local SCREENSHOT_DIR = TARGET_DIR .. 'screenshots/'
local SCREENSHOT_REQ_TIMEOUT = 30
local SCREENSHOT_HISTORY_LIMIT = 20
local TMP_RAW = '/tmp/shell_screenshot.raw'
local STRIDE_BYTES = SCREEN_W * 3



local isRunning = false
local cmdTimer = nil
local heartbeatTimer = nil
local watchdogTimer = nil
local statusBuffer = {}
local cmdBusy = false
local cmdStartTime = nil
local currentCmd = ''
local currentReq = nil
local busyMode = ''
local screenshotPending = false
local screenshotReq = nil
local screenshotWaitStartedAt = 0
local screenshotPhase = ''

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

local function removeFile(path)
    pcall(os.remove, path)
end

local function mkdir(path)
    os.execute('mkdir -p "' .. path .. '"')
end

local function readAll(path, maxLen)
    local f = io.open(path, 'r')
    if not f then return '' end
    local text = ''
    for line in f:lines() do
        text = text .. line .. '\n'
    end
    f:close()
    if maxLen and #text > maxLen then
        text = text:sub(1, maxLen) .. '\n... [truncated at ' .. (maxLen / 1024) .. 'KB]'
    end
    return text
end

local function addLog(line)
    table.insert(statusBuffer, 1, line)
    while #statusBuffer > 25 do table.remove(statusBuffer) end
    local t = "=== Terminal Bridge ===\n"
    t = t .. "Status: " .. (isRunning and "RUNNING" or "STOPPED") .. "\n"
    t = t .. "Busy: " .. tostring(cmdBusy) .. "\n"
    t = t .. "Mode: " .. (busyMode ~= '' and busyMode or '-') .. "\n"
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

local function atomicWriteJson(filename, data)
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

local function writeBridgeState(busy, mode, message)
    atomicWrite('bridge_state.json', {
        type = 'bridge_state',
        busy = busy == true,
        mode = mode or '',
        message = message or '',
        timestamp = tostring(os.time())
    })
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

local function writeScreenshotResult(data)
    atomicWrite('screenshot_result.json', data)
end

local function buildScreenshotId(index, capturedAtUnix)
    local timePart = os.date('%Y%m%d%H%M%S', capturedAtUnix or os.time())
    return timePart .. '#' .. tostring(index)
end

local function buildScreenshotFilename(shotId)
    return (shotId:gsub('#', '_')) .. '.png'
end

local function normalizeScreenshotItems(items)
    local normalized = {}
    if type(items) ~= 'table' then
        return normalized, 1
    end
    local seen = {}
    local maxIndex = 0
    for i = 1, #items do
        local item = items[i]
        if type(item) == 'table' and item.file then
            local idx = tonumber(item.index) or i
            if idx > maxIndex then
                maxIndex = idx
            end
            local capturedAtUnix = tonumber(item.capturedAtUnix) or os.time()
            item.index = idx
            item.capturedAtUnix = capturedAtUnix
            item.shotId = item.shotId or buildScreenshotId(idx, capturedAtUnix)
            if not seen[item.shotId] then
                seen[item.shotId] = true
            normalized[#normalized + 1] = item
            end
        end
    end
    return normalized, maxIndex + 1
end

local function readScreenshotStore()
    local content = readFile(TARGET_DIR .. 'screenshot_history.json')
    if not content or content == '' then
        return { items = {}, nextIndex = 1, lastItem = nil }
    end
    local json = jsonDecode(content)
    if type(json) ~= 'table' then
        return { items = {}, nextIndex = 1, lastItem = nil }
    end
    local items = json
    if json.items and type(json.items) == 'table' then
        items = json.items
    end
    local normalized, nextIndex = normalizeScreenshotItems(items)
    local storedNextIndex = tonumber(json.nextIndex) or 0
    if storedNextIndex < nextIndex then
        storedNextIndex = nextIndex
    end
    return {
        items = normalized,
        nextIndex = storedNextIndex > 0 and storedNextIndex or nextIndex,
        lastItem = normalized[1]
    }
end

local function writeScreenshotStore(store)
    return atomicWriteJson('screenshot_history.json', {
        items = store.items or {},
        nextIndex = tonumber(store.nextIndex) or 1,
        lastItem = store.lastItem
    })
end

local function nextScreenshotIndex()
    local store = readScreenshotStore()
    local nextIndex = tonumber(store.nextIndex) or 1
    if nextIndex < 1 then nextIndex = 1 end
    return nextIndex, store
end

local function appendScreenshotHistory(item)
    local nextIndex, store = nextScreenshotIndex()
    item.index = nextIndex
    table.insert(store.items, 1, item)
    while #store.items > SCREENSHOT_HISTORY_LIMIT do
        table.remove(store.items)
    end
    store.lastItem = store.items[1]
    store.nextIndex = nextIndex + 1
    writeScreenshotStore(store)
end

local function writePng(path, width, height, rgb888Data)
    local fPng = io.open(path, 'wb')
    if not fPng then
        return false
    end

    local crcTable = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then
                c = math.floor(c / 2) ~ 0xEDB88320
            else
                c = math.floor(c / 2)
            end
        end
        crcTable[i] = c
    end

    local function writeInt32(n)
        fPng:write(string.char(
            (n >> 24) & 0xFF,
            (n >> 16) & 0xFF,
            (n >> 8) & 0xFF,
            n & 0xFF
        ))
    end

    local function calculateCRC(data)
        local crc = 0xFFFFFFFF
        for i = 1, #data do
            crc = (crc >> 8) ~ crcTable[(crc ~ string.byte(data, i)) & 0xFF]
        end
        return crc ~ 0xFFFFFFFF
    end

    local function calculateAdler32(data)
        local a, b = 1, 0
        for i = 1, #data do
            a = (a + string.byte(data, i)) % 65521
            b = (b + a) % 65521
        end
        return (b << 16) | a
    end

    local function writeChunk(typeName, data)
        local full = typeName .. data
        writeInt32(#data)
        fPng:write(full)
        writeInt32(calculateCRC(full))
    end

    fPng:write('\137PNG\r\n\026\n')
    writeChunk('IHDR', string.char(
        (width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF, width & 0xFF,
        (height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF, height & 0xFF,
        8, 2, 0, 0, 0
    ))

    local scanlines = {}
    local rowLen = width * 3
    for y = 0, height - 1 do
        local rowStart = y * rowLen + 1
        scanlines[#scanlines + 1] = '\0' .. rgb888Data:sub(rowStart, rowStart + rowLen - 1)
    end

    local imgData = table.concat(scanlines)
    local zlib = { '\x78\x01' }
    local pos = 1
    local len = #imgData
    while pos <= len do
        local chunk = math.min(65535, len - pos + 1)
        local final = (pos + chunk > len) and 1 or 0
        local l = chunk & 0xFF
        local h = (chunk >> 8) & 0xFF
        zlib[#zlib + 1] = string.char(final, l, h, 255 - l, 255 - h)
        zlib[#zlib + 1] = imgData:sub(pos, pos + chunk - 1)
        pos = pos + chunk
    end

    local adler = calculateAdler32(imgData)
    zlib[#zlib + 1] = string.char(
        (adler >> 24) & 0xFF,
        (adler >> 16) & 0xFF,
        (adler >> 8) & 0xFF,
        adler & 0xFF
    )

    writeChunk('IDAT', table.concat(zlib))
    writeChunk('IEND', '')
    fPng:close()
    return true
end

local function extractRgb888(rawData)
    local rows = {}
    for y = 0, SCREEN_H - 1 do
        local rowParts = {}
        local lineStart = y * STRIDE_BYTES + 1
        for x = 0, SCREEN_W - 1 do
            local p = lineStart + x * 3
            local b = string.byte(rawData, p) or 0
            local g = string.byte(rawData, p + 1) or 0
            local r = string.byte(rawData, p + 2) or 0
            rowParts[#rowParts + 1] = string.char(r, g, b)
        end
        rows[#rows + 1] = table.concat(rowParts)
    end
    return table.concat(rows)
end

local function captureScreenshot(req)
    mkdir(SCREENSHOT_DIR)
    removeFile(TMP_RAW)
    os.execute('dd if=' .. FB_PATH .. ' of=' .. TMP_RAW .. ' bs=' .. tostring(STRIDE_BYTES) .. ' skip=' .. tostring(SCREEN_H) .. ' count=' .. tostring(SCREEN_H) .. ' 2>/dev/null')

    local fRaw = io.open(TMP_RAW, 'rb')
    if not fRaw then
        return nil, '无法读取截图临时文件'
    end

    local rawData = fRaw:read('*a') or ''
    fRaw:close()
    local needBytes = STRIDE_BYTES * SCREEN_H
    if #rawData < needBytes then
        removeFile(TMP_RAW)
        return nil, '截图数据不足'
    end

    local rgbData = extractRgb888(rawData)
    rawData = nil
    pcall(collectgarbage, 'collect')

    local index = nextScreenshotIndex()
    local capturedAtUnix = os.time()
    local capturedAt = os.date('%Y-%m-%d %H:%M:%S', capturedAtUnix)
    local shotId = buildScreenshotId(index, capturedAtUnix)
    local filename = buildScreenshotFilename(shotId)
    local outPath = SCREENSHOT_DIR .. filename
    local quickPath = 'internal://files/screenshots/' .. filename
    local ok = writePng(outPath, SCREEN_W, SCREEN_H, rgbData)
    rgbData = nil
    removeFile(TMP_RAW)
    pcall(collectgarbage, 'collect')
    os.execute('sync')

    if not ok then
        return nil, 'PNG 写入失败'
    end

    local item = {
        seq = req.seq,
        index = index,
        shotId = shotId,
        file = quickPath,
        name = filename,
        capturedAt = capturedAt,
        capturedAtUnix = capturedAtUnix,
        requestTimestamp = tonumber(req.timestamp) or 0,
        screenWidth = SCREEN_W,
        screenHeight = SCREEN_H,
        source = 'framebuffer'
    }
    appendScreenshotHistory(item)
    return item
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
    return { seq = json.seq, cmd = json.cmd, type = json.type or 'cmd' }
end

local function readScreenshotRequest()
    local reqFile = TARGET_DIR .. 'screenshot_request.json'
    if not fileExists(reqFile) then return nil end

    local content = readFile(reqFile)
    if not content or content == '' then return nil end

    local json = jsonDecode(content)
    if not json then
        os.execute('sleep 0.1')
        content = readFile(reqFile)
        if not content or content == '' then return nil end
        json = jsonDecode(content)
        if not json then
            return nil
        end
    end
    if not json.seq then
        return nil
    end
    return {
        seq = json.seq,
        type = 'screenshot',
        timestamp = json.timestamp
    }
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

local function finishScreenshotError(message)
    local req = screenshotReq or { seq = -1 }
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'error',
        message = message,
        timestamp = os.date('%H:%M:%S')
    })
    writeBridgeState(false, '', '')
    screenshotPending = false
    screenshotReq = nil
    screenshotWaitStartedAt = 0
    screenshotPhase = ''
    cmdBusy = false
    busyMode = ''
end

local function finishScreenshotSuccess(item)
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = item.seq,
        status = 'done',
        message = '截图完成',
        index = item.index,
        shotId = item.shotId,
        file = item.file,
        name = item.name,
        capturedAt = item.capturedAt,
        capturedAtUnix = item.capturedAtUnix,
        requestTimestamp = item.requestTimestamp,
        screenWidth = item.screenWidth,
        screenHeight = item.screenHeight,
        source = item.source,
        timestamp = os.date('%H:%M:%S')
    })
    writeBridgeState(false, '', '')
    screenshotPending = false
    screenshotReq = nil
    screenshotWaitStartedAt = 0
    screenshotPhase = ''
    cmdBusy = false
    busyMode = ''
end

local function prepareScreenshotRequest(req)
    screenshotPending = true
    screenshotReq = req
    screenshotWaitStartedAt = os.time()
    screenshotPhase = 'waiting_screen_on'
    cmdBusy = true
    busyMode = 'screenshot'
    writeBridgeState(true, 'screenshot', '请熄屏后重新亮屏')
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'waiting_screen_on',
        message = '请熄屏后重新亮屏',
        timestamp = os.date('%H:%M:%S')
    })
    os.remove(TARGET_DIR .. 'screenshot_request.json')
    addLog('[shot] waiting for screen on')
end

-- ====== 看门狗：检测命令超时 ======

local function watchdogCheck()
    if not cmdBusy then return end
    if busyMode == 'screenshot' then
        if screenshotPending and screenshotWaitStartedAt > 0 and (os.time() - screenshotWaitStartedAt) >= SCREENSHOT_REQ_TIMEOUT then
            addLog('[shot] timeout')
            finishScreenshotError('截图超时，请重试')
        end
        return
    end
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
    busyMode = ''
    writeBridgeState(false, '', '')
    currentCmd = ''
    currentReq = nil
    cmdStartTime = nil
end

-- ====== 定时器回调 ======

local function checkScreenshotRequest()
    if cmdBusy then return end
    if not isRunning then return end

    local req = readScreenshotRequest()
    if not req then return end
    prepareScreenshotRequest(req)
end

local function checkCommandRequest()
    if cmdBusy then return end
    if not isRunning then return end

    local req = readCommandRequest()
    if not req then return end

    cmdBusy = true
    busyMode = 'cmd'
    currentCmd = req.cmd
    currentReq = req
    cmdStartTime = os.clock() or 0
    writeBridgeState(true, 'cmd', '命令执行中')
    local result = executeShellCommand(req.cmd)
    writeCommandResult(req, result)
    cmdBusy = false
    busyMode = ''
    writeBridgeState(false, '', '')
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
    isRunning = true; cmdBusy = false; busyMode = ''
    os.execute('mkdir -p ' .. TARGET_DIR)
    os.execute('mkdir -p "' .. SCREENSHOT_DIR .. '"')
    writeBridgeState(false, '', '')
    addLog('>>> Service Started')

    cmdTimer = lvgl.Timer({ period = 500, repeat_count = -1,
        cb = function()
            if isRunning then
                checkScreenshotRequest()
                checkCommandRequest()
            end
        end })
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
    cmdBusy = false
    busyMode = ''
    screenshotPending = false
    screenshotReq = nil
    screenshotWaitStartedAt = 0
    screenshotPhase = ''
    writeBridgeState(false, '', '')
    addLog('>>> Service Stopped')
    startStopBtn:set { text = "START", bg_color = '#004400', border_color = '#00ff00', text_color = '#00ff00' }
end

local function clearLog()
    statusBuffer = {}
    local t = "=== Terminal Bridge ===\nStatus: " .. (isRunning and "RUNNING" or "STOPPED") .. "\nBusy: " .. tostring(cmdBusy) .. "\nMode: " .. (busyMode ~= '' and busyMode or '-') .. "\n" .. string.rep("-", 28) .. "\n"
    terminal:set { text = t }
end

-- ====== 按钮事件 ======

startStopBtn:onevent(lvgl.EVENT.CLICKED, function()
    if isRunning then stopService() else startService() end
end)
clearBtn:onevent(lvgl.EVENT.CLICKED, function() clearLog() end)

-- ====== 初始状态 ======

terminal:set { text = "=== Terminal Bridge ===\nStatus: STOPPED\n\nPress START\n\nDir: /data/quickapp/files/com.shell.liangyi/" }

function ScreenStateChangedCB(pre, now, reason)
    if not screenshotPending then
        return
    end
    if pre ~= 'ON' and now == 'ON' then
        screenshotPhase = 'capturing'
        writeBridgeState(true, 'screenshot', '正在截图，请稍候')
        writeScreenshotResult({
            type = 'screenshot_result',
            seq = screenshotReq and screenshotReq.seq or -1,
            status = 'capturing',
            message = '正在截图，请稍候',
            timestamp = os.date('%H:%M:%S')
        })
        os.execute('sleep 1')
        local item, err = captureScreenshot(screenshotReq or { seq = -1 })
        if item then
            addLog('[shot] saved #' .. tostring(item.index))
            finishScreenshotSuccess(item)
        else
            addLog('[shot] failed: ' .. tostring(err))
            finishScreenshotError(err or '截图失败')
        end
    end
end
