-- Terminal.lua
-- Shell 终端桥接表盘
-- 接收快应用的命令/截图/文件请求 → 执行后写回结果

local BAND9_PRO_DIR = '/data/quickapp/files/com.shell.liangyi/'
local BAND10_PRO_DIR = '/data/data/com.shell.liangyi/'
local BAND10_PRO_FILES_DIR = '/data/files/com.shell.liangyi/'
local DEVICE_INFO_FILE = 'device_info.json'
local SCREENSHOT_DEBUG_FILE = 'screenshot_debug.json'
local TARGET_DIR = BAND10_PRO_DIR
local CMD_TIMEOUT = 10000  -- 命令超时：10 秒
local SCREEN_W = lvgl.HOR_RES()
local SCREEN_H = lvgl.VER_RES()
local FB_PATH = '/dev/fb0'
local SCREENSHOT_DIR = TARGET_DIR .. 'screenshots/'
local SCREENSHOT_REQ_TIMEOUT = 30
local SCREENSHOT_HISTORY_LIMIT = 20
local LOG_HISTORY_LIMIT = 30
local TMP_RAW = '/tmp/shell_screenshot.raw'
local STRIDE_BYTES = SCREEN_W * 3
local SCREENSHOT_CHUNK_SIZE = 32 * 1024



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
local localScreenshotSeq = 0
local activeDeviceProduct = '-'
local activeDeviceModel = '-'
local activeDeviceSourceDir = ''
local ipcGuardToken = ''
local ipcGuardSeq = 0
local writeLuaEventLog

-- ====== UI ======
-- 视觉风格对齐 Vela 快应用：纯黑背景 + 深灰圆角卡片 + 蓝色主操作
-- 布局遵循 luaexample 规范：
--   1) Object 容器只用绝对坐标 (x, y)，绝不设 align；Label 才用 align
--   2) 容器统一 pad_all = 0，消除默认内边距造成的偏移/溢出
--   3) 非交互容器/标签 add_flag(EVENT_BUBBLE) 做点击穿透，事件冒泡到目标按钮
--   4) 切页用 root:clean() 清空后重建（单文件页面：home / shell；用户操作放在 QuickApp）
local UI_BG        = '#000000'  -- 页面背景
local UI_CARD      = '#262626'  -- 卡片/次按钮
local UI_PRIMARY   = '#0D6EFF'  -- 主操作（START）
local UI_DANGER    = '#D93A2F'  -- 运行中（STOP）
local UI_TEXT      = '#ffffff'  -- 主文字
local UI_TERM_TEXT = '#d6d6d6'  -- 日志文字
local UI_DIM       = '#888888'  -- 次要信息
local UI_CLAUDE    = '#D97757'  -- Claude 品牌橙

-- 版面尺寸（针对 336x480 调校）
local UI_GAP = 12               -- 统一外边距/间距
local UI_CARD_RADIUS = 24       -- 卡片圆角
local UI_BTN_H = 48             -- 按钮高度（缩小按钮，释放终端空间）
local UI_BTN_RADIUS = math.floor(UI_BTN_H / 2)  -- 胶囊按钮
local UI_TOPBAR_H = 56          -- 顶部返回/标题栏高度（紧凑）
local HOME_PAD = 20             -- 表盘数据左边距

-- 当前页面与各页面控件引用（切页后重建，故用 forward 局部，配合 nil 守卫）
local currentPage = 'home'      -- 'home' | 'shell' | 'log'
local terminal = nil
local logTerminal = nil
local logTapCount = 0
local logLastTapAt = 0
local startBtn = nil
local startBtnLabel = nil
local clearBtn = nil
local timeLabel = nil
local dateLabel = nil
local weekLabel = nil
local spriteCells = nil         -- 像素方块网格（lvgl.Object 数组）
local spriteFrame = 0
local clockTimer = nil
local spriteTimer = nil
local buildHomePage, buildShellPage, buildLogPage   -- 互相跳转，提前声明

-- 根容器只创建一次；切页时 root:clean() 重建子节点，flag 保留在 root 上
local root = lvgl.Object(nil, {
    x = 0, y = 0,
    w = SCREEN_W, h = SCREEN_H,
    bg_color = UI_BG,
    border_width = 0,
    pad_all = 0,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)  -- 点击穿透

-- ====== 像素精灵：用 12x12 方块网格渲染（每格一个 lvgl.Object，不依赖字体字形）======
-- 每次亮屏随机显示小猫或 Claude 火花，逐帧改变方块的颜色/透明度形成动画；不标注名称
local SPRITE_COLS = 14          -- 网格列数（横向，左右各比原来宽一格）
local SPRITE_ROWS = 12          -- 网格行数（纵向）
local SPRITE_CELL = 20          -- 每格方块尺寸（px，实体无间隙）

-- Claude Code 精灵（参考用户提供的轮廓 ▐▛███▜▌ ▝▜█████▛▘ ▘▘ ▝▝）
-- 方块像素造型：平顶身体 + 左右两侧伸出的手臂 + 两只黑方眼 + 底部带缝隙的小脚
-- 'O'=身体橙，'P'=黑眼，其余空白；待机形象左右对称
-- 特效：眼睛变化（正常 ↔ 眨眼 ↔ 看向一侧）
local CLAUDE_NORMAL = {
    "..............",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "..OOPOOOOPOO..",
    "..OOPOOOOPOO..",
    "OOOOOOOOOOOOOO",
    "OOOOOOOOOOOOOO",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "...O.O..O.O...",
    "...O.O..O.O...",
    "..............",
}
local CLAUDE_BLINK = {
    "..............",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "..OOPOOOOOOO..",
    "..OOPOOOOPOO..",
    "OOOOOOOOOOOOOO",
    "OOOOOOOOOOOOOO",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "...O.O..O.O...",
    "...O.O..O.O...",
    "..............",
}
local CLAUDE_LOOK = {
    "..............",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "..OOPOOOOPOO..",
    "..OOPOOOOPOO..",
    "OOOOOOOOOOOOOO",
    "OOOOOOOOOOOOOO",
    "..OOOOOOOOOO..",
    "..OOOOOOOOOO..",
    "...O.O..O.O...",
    "...O.O..O.O...",
    "..............",
}

local CRAB_SPRITE = {
    palette = { ['O'] = UI_CLAUDE, ['H'] = '#F0A070', ['W'] = '#ffffff', ['P'] = '#222222', ['L'] = '#B05530', ['-'] = '#F0A070' },
    frames = { CLAUDE_NORMAL, CLAUDE_NORMAL, CLAUDE_BLINK, CLAUDE_LOOK },
}

local function resetSprite()
    spriteFrame = 0
end

local function renderSprite()
    if not spriteCells then return end
    local grid = CRAB_SPRITE.frames[(spriteFrame % #CRAB_SPRITE.frames) + 1]
    local palette = CRAB_SPRITE.palette
    for r = 1, SPRITE_ROWS do
        local rowStr = grid[r] or ''
        for c = 1, SPRITE_COLS do
            local cell = spriteCells[(r - 1) * SPRITE_COLS + c]
            if cell then
                local color = palette[rowStr:sub(c, c)]
                if color then
                    cell:set { bg_color = color, bg_opa = 255 }
                else
                    cell:set { bg_opa = 0 }
                end
            end
        end
    end
end

local function updateClock()
    if currentPage ~= 'home' or not timeLabel then return end
    timeLabel:set { text = os.date('%H:%M') }
end

-- ====== 终端日志渲染（shell 页存在时才刷新；切到 home 后安全 no-op）======
local function buildTerminalText()
    local t = "shell++\n"
    t = t .. "Status: " .. (isRunning and "RUNNING" or "STOPPED") .. "\n"
    t = t .. "Busy: " .. tostring(cmdBusy) .. "\n"
    t = t .. "Mode: " .. (busyMode ~= '' and busyMode or '-') .. "\n"
    t = t .. "设备: " .. tostring(activeDeviceProduct or '-') .. " | " .. tostring(TARGET_DIR or '-') .. "\n"
    t = t .. string.rep("-", 28) .. "\n"
    for i = 1, #statusBuffer do
        t = t .. statusBuffer[i] .. "\n"
    end
    return t
end

local function refreshTerminal()
    local text = buildTerminalText()
    if terminal then terminal:set { text = text } end
    if logTerminal then logTerminal:set { text = text } end
end

local function resetLogTap()
    logTapCount = 0
    logLastTapAt = 0
end

local function onLogCardClicked()
    local now = os.time()
    if now - logLastTapAt > 2 then
        logTapCount = 0
    end
    logTapCount = logTapCount + 1
    logLastTapAt = now
    if logTapCount >= 2 then
        resetLogTap()
        buildLogPage()
    end
end

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

local function writeBinaryFile(path, content)
    local ok, f = pcall(io.open, path, 'wb')
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

local function dirExists(path)
    local ok, dir = pcall(function() return lvgl.fs.open_dir(path) end)
    if ok and dir then
        dir:close()
        return true
    end
    return false
end

local function removeFile(path)
    pcall(os.remove, path)
end

local function fileSize(path)
    local ok, f = pcall(io.open, path, 'rb')
    if not ok or not f then return 0 end
    local seekOk, size = pcall(f.seek, f, 'end')
    f:close()
    if not seekOk then return 0 end
    return tonumber(size) or 0
end

local function padFileToSize(path, totalBytes)
    local size = fileSize(path)
    if size >= totalBytes then return true end
    local f = io.open(path, 'ab')
    if not f then return false end
    local remaining = totalBytes - size
    local zeros = string.rep('\0', 1024)
    while remaining > 0 do
        local n = remaining > 1024 and 1024 or remaining
        local ok = pcall(f.write, f, zeros:sub(1, n))
        if not ok then
            f:close()
            return false
        end
        remaining = remaining - n
    end
    f:close()
    return true
end

local function isRedmiWatch6()
    local product = string.lower(tostring(activeDeviceProduct or ''))
    local model = string.lower(tostring(activeDeviceModel or ''))
    return product == 'redmi watch 6'
        or product == 'redmi watch6'
        or product:find('redmi watch 6', 1, true) ~= nil
        or product:find('redmi watch6', 1, true) ~= nil
        or model == 'm2523w1'
end

local function getScreenshotProfile()
    local skipRows = SCREEN_H
    local method = 'legacy'
    local name = 'legacy'
    local minRows = SCREEN_H
    local readRows = SCREEN_H
    local candidateSkipRows = nil

    if isRedmiWatch6() then
        method = 'stream'
        name = 'redmi_watch6'
        if SCREEN_W == 432 and SCREEN_H == 514 then
            skipRows = 0
            minRows = 512
            readRows = 512
        end
    end

    return {
        name = name,
        method = method,
        width = SCREEN_W,
        height = SCREEN_H,
        strideBytes = STRIDE_BYTES,
        skipRows = skipRows,
        offsetBytes = STRIDE_BYTES * skipRows,
        rawBytes = STRIDE_BYTES * SCREEN_H,
        readBytes = STRIDE_BYTES * readRows,
        readRows = readRows,
        minRawBytes = STRIDE_BYTES * minRows,
        pixelFormat = 'bgr888',
        candidateSkipRows = candidateSkipRows
    }
end

local function setTargetDir(path)
    TARGET_DIR = path
    SCREENSHOT_DIR = TARGET_DIR .. 'screenshots/'
end

local function mkdir(path)
    if not path or path == '' then return end
    if path:find('[;&|`"\\]') or path:find('%$') or path:find('[()]') then return end
    pcall(os.execute, 'mkdir -p "' .. path .. '"')
end

local function readAll(path, maxLen)
    local ok, f = pcall(io.open, path, 'r')
    if not ok or not f then return '' end
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
    refreshTerminal()
end

-- ====== JSON ======

local function jsonEncode(val)
    local t = type(val)
    if t == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'):gsub('[\x00-\x1f]', function(c) return string.format('\\u%04x', string.byte(c)) end) .. '"'
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
                elseif esc == 'u'  then
                    local hex = json:sub(pos + 1, pos + 4)
                    if #hex < 4 then error('incomplete unicode escape') end
                    local cp = tonumber(hex, 16)
                    if not cp then error('invalid unicode escape') end
                    pos = pos + 4
                    if cp < 0x80 then
                        parts[#parts+1] = string.char(cp)
                    elseif cp < 0x800 then
                        parts[#parts+1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
                    else
                        parts[#parts+1] = string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
                    end
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

local function readDeviceInfoFrom(dir)
    local content = readFile(dir .. DEVICE_INFO_FILE)
    if not content or content == '' then return nil end
    local data = jsonDecode(content)
    if type(data) ~= 'table' then return nil end
    data._sourceDir = dir
    data._updatedAtUnix = tonumber(data.updatedAtUnix) or tonumber(data.timestamp) or 0
    return data
end

local function resolveTargetDirByDeviceInfo()
    local candidates = {
        BAND9_PRO_DIR,         -- Band 9 Pro / Watch S4 / Watch S4 41mm
        BAND10_PRO_DIR,        -- Band 10 Pro
        BAND10_PRO_FILES_DIR,  -- Band 10 Pro fallback
    }
    local selected = nil

    for _, dir in ipairs(candidates) do
        local data = readDeviceInfoFrom(dir)
        if data then
            selected = data
            break
        end
    end

    if not selected then
        activeDeviceProduct = '-'
        activeDeviceModel = '-'
        activeDeviceSourceDir = ''
        return false, '请打开快应用获取设备信息后再试'
    end

    local product = tostring(selected.product or '')
    local chosenDir = selected._sourceDir or BAND10_PRO_DIR

    if product == 'Xiaomi Smart Band 9 Pro'
        or product == 'Xiaomi Watch S4'
        or product == 'Xiaomi Watch S4 41mm' then
        chosenDir = BAND9_PRO_DIR
    elseif product == 'Xiaomi Smart Band 10 Pro' then
        if chosenDir ~= BAND10_PRO_FILES_DIR then
            chosenDir = BAND10_PRO_DIR
        end
    end

    setTargetDir(chosenDir)
    activeDeviceProduct = product ~= '' and product or '-'
    activeDeviceModel = tostring(selected.model or '-')
    activeDeviceSourceDir = tostring(selected._sourceDir or chosenDir)
    return true
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

    pcall(os.execute, 'mkdir -p "' .. TARGET_DIR .. '"')
    local ok = writeFile(tmp, json)
    if not ok then return false end
    os.remove(path)
    pcall(os.execute, 'mv "' .. tmp .. '" "' .. path .. '"')
    return true
end

local function atomicWriteJson(filename, data)
    local json = jsonEncode(data)
    local tmp = TARGET_DIR .. '.' .. filename .. '.tmp'
    local path = TARGET_DIR .. filename
    pcall(os.execute, 'mkdir -p "' .. TARGET_DIR .. '"')
    local ok = writeFile(tmp, json)
    if not ok then return false end
    os.remove(path)
    pcall(os.execute, 'mv "' .. tmp .. '" "' .. path .. '"')
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

local function randomHex(n)
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local bytes = f:read(n)
        f:close()
        if bytes and #bytes == n then
            local hex = ''
            for i = 1, n do
                hex = hex .. string.format('%02x', string.byte(bytes, i))
            end
            return hex
        end
    end
    local r = ''
    for _ = 1, n do
        r = r .. string.format('%02x', math.random(0, 255))
    end
    return r
end

local function buildIpcGuardToken()
    local t = tostring(os.time())
    local r = randomHex(8)
    return t .. '-' .. r
end

local function rotateIpcGuard()
    ipcGuardSeq = ipcGuardSeq + 1
    ipcGuardToken = buildIpcGuardToken()
    atomicWrite('ipc_guard.json', {
        type = 'ipc_guard',
        seq = ipcGuardSeq,
        token = ipcGuardToken,
        timestamp = tostring(os.time())
    })
end

local function ensureIpcGuard()
    if ipcGuardToken == '' then
        rotateIpcGuard()
    end
end

local function rejectInjectedRequest(filename, reason)
    os.remove(TARGET_DIR .. filename)
    addLog('[guard] rejected ' .. filename)
    writeLuaEventLog('IPC 请求被拒绝', filename, reason or 'guard 校验失败')
end

local function validateIpcGuard(req, filename)
    ensureIpcGuard()
    if not req or req.guard ~= ipcGuardToken then
        rejectInjectedRequest(filename, '缺少或错误的安全令牌')
        return false
    end
    rotateIpcGuard()
    return true
end

local function commandTouchesProtectedIpc(cmd)
    if not cmd then return false end
    local lower = string.lower(cmd)
    local protected = {
        'cmd_request.json', 'cmd_result.json',
        'screenshot_request.json', 'screenshot_result.json',
        'file_request.json', 'file_result.json',
        'bridge_state.json', 'ipc_guard.json',
        'screenshot_history.json', 'screenshot_preview_state.json',
        'screenshot_settings.json',
        '/data/quickapp/files/com.shell.liangyi',
        '/data/data/com.shell.liangyi',
        'internal://files/',
        'com.shell.liangyi'
    }
    for i = 1, #protected do
        if string.find(lower, protected[i], 1, true) then
            return true
        end
    end
    if string.find(cmd, '%.%./') or string.find(cmd, '%.%..*[/\\]') then
        return true
    end
    return false
end

local function commandLooksLikeNestedScript(cmd)
    if not cmd then return false end
    if string.find(cmd, '\n', 1, true) or string.find(cmd, '\r', 1, true) then
        return true
    end
    local lower = string.lower(cmd)
    local trimmed = string.gsub(lower, '^%s+', '')
    local prefixes = {
        'sh ', 'sh\t', '/bin/sh', 'bash ', 'bash\t', '/bin/bash', 'busybox sh',
        'lua ', 'lua\t', '/usr/bin/lua', 'luac ', 'python ', 'python\t', '/usr/bin/python',
        'python3 ', '/usr/bin/python3', 'node ', 'node\t', '/usr/bin/node',
        'perl ', 'perl\t', '/usr/bin/perl', 'ruby ', 'ruby\t', '/usr/bin/ruby',
        'php ', 'php\t', '/usr/bin/php',
        'nohup ', 'nohup\t', 'setsid ', 'setsid\t',
        'eval ', 'eval\t', 'exec ', 'exec\t',
        'source ', 'source\t', '. '
    }
    for i = 1, #prefixes do
        if string.sub(trimmed, 1, #prefixes[i]) == prefixes[i] then
            return true
        end
    end
    if string.sub(trimmed, 1, 2) == './' then
        return true
    end
    if string.find(trimmed, '&', 1, true) then
        return true
    end
    if string.find(cmd, '[|;`]') or string.find(cmd, '%$%(') then
        return true
    end
    return false
end

-- ====== 命令执行 ======

local function executeShellCommand(cmd)
    if not cmd or cmd == '' then
        return { stdout = '', stderr = '', exitcode = -1 }
    end
    if commandTouchesProtectedIpc(cmd) then
        writeLuaEventLog('命令被拦截', cmd, '命令包含 Shell++ IPC 受保护路径或文件名')
        return { stdout = '', stderr = 'Blocked: command touches protected Shell++ IPC files', exitcode = -2 }
    end
    if commandLooksLikeNestedScript(cmd) then
        writeLuaEventLog('命令被拦截', cmd, '命令疑似脚本套娃或后台驻留')
        return { stdout = '', stderr = 'Blocked: nested scripts and background commands are not allowed', exitcode = -3 }
    end

    local ts = os.date('%H:%M:%S')
    addLog('[' .. ts .. '] Exec: ' .. cmd)

    mkdir(TARGET_DIR)
    local outFile = TARGET_DIR .. '.shell_stdout.txt'
    os.remove(outFile)

    -- 这台设备只允许 os.execute：io.popen 被固件禁用，嵌套 spawn nsh 会崩。
    -- NSH 只支持 `>` 重定向 stdout，不支持 `2>`（bash 语法，会导致整行解析
    -- 失败、命令根本不执行）。所以只用 `> outFile` 捕获 stdout；nsh 不支持
    -- 分离 stderr，命令的报错信息通常也会打到 stdout 里。
    os.execute(cmd .. ' > "' .. outFile .. '"')
    local stdout = readAll(outFile, 32768)

    if #stdout > 32768 then
        stdout = stdout:sub(1, 32768) .. '\n... [truncated at 32KB]'
    end
    local exitcode = 0
    if stdout == '' then
        exitcode = -1
        stdout = '(no output)'
    end

    addLog('[' .. ts .. '] Done (' .. #stdout .. ' bytes)')
    return { stdout = stdout, stderr = '', exitcode = exitcode }
end

local function writeScreenshotResult(data)
    atomicWrite('screenshot_result.json', data)
end

local function notifyScreenshotSuccess()
    pcall(function()
        if vibrator and type(vibrator.start) == 'function' and vibrator.type and vibrator.type.SUCCESS then
            vibrator.start(vibrator.type.SUCCESS)
        end
    end)
end

local function buildScreenshotId(index, capturedAtUnix)
    local timePart = os.date('%Y%m%d%H%M%S', capturedAtUnix or os.time())
    return timePart .. '#' .. tostring(index)
end

local function buildScreenshotFilename(shotId)
    return (shotId:gsub('#', '_')) .. '.png'
end

local function buildScreenshotRawFilename(shotId)
    return (shotId:gsub('#', '_')) .. '.raw'
end

local function buildScreenshotMetaFilename(shotId)
    return (shotId:gsub('#', '_')) .. '.json'
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

local function getScreenshotDebugConfig()
    local content = readFile(TARGET_DIR .. SCREENSHOT_DEBUG_FILE)
    if not content or content == '' then
        return { saveRaw = false }
    end
    local json = jsonDecode(content)
    if type(json) ~= 'table' then
        return { saveRaw = false }
    end
    return {
        saveRaw = json.saveRaw == true
    }
end

local function isLogRecordingEnabled()
    local content = readFile(TARGET_DIR .. 'log_config.json')
    if not content or content == '' then
        return false
    end
    local json = jsonDecode(content)
    return type(json) == 'table' and json.enabled == true
end

local function buildLuaLogFilename(logId)
    return 'log_lua_' .. (logId:gsub('#', '_')) .. '.txt'
end

local function normalizeLuaLogItems(items)
    local normalized = {}
    if type(items) ~= 'table' then
        return normalized, 1
    end
    local seen = {}
    local maxIndex = 0
    for i = 1, #items do
        local item = items[i]
        if type(item) == 'table' and (item.file or item.logId) then
            local idx = tonumber(item.index) or i
            if idx > maxIndex then
                maxIndex = idx
            end
            local capturedAtUnix = tonumber(item.capturedAtUnix) or os.time()
            local logId = item.logId or buildScreenshotId(idx, capturedAtUnix)
            if not seen[logId] then
                seen[logId] = true
                item.index = idx
                item.capturedAtUnix = capturedAtUnix
                item.logId = logId
                item.source = 'lua'
                normalized[#normalized + 1] = item
            end
        end
    end
    return normalized, maxIndex + 1
end

local function readLuaLogStore()
    local content = readFile(TARGET_DIR .. 'lua_log_history.json')
    if not content or content == '' then
        return { items = {}, nextIndex = 1, lastItem = nil }
    end
    local json = jsonDecode(content)
    if type(json) ~= 'table' then
        return { items = {}, nextIndex = 1, lastItem = nil }
    end
    local items = json.items and type(json.items) == 'table' and json.items or json
    local normalized, nextIndex = normalizeLuaLogItems(items)
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

local function writeLuaLogStore(store)
    return atomicWriteJson('lua_log_history.json', {
        items = store.items or {},
        nextIndex = tonumber(store.nextIndex) or 1,
        lastItem = store.lastItem
    })
end

local function nextLuaLogIndex()
    local store = readLuaLogStore()
    local nextIndex = tonumber(store.nextIndex) or 1
    if nextIndex < 1 then nextIndex = 1 end
    return nextIndex, store
end

local function appendLuaLogEntry(title, summary, message)
    if not isLogRecordingEnabled() then
        return false
    end
    local nextIndex, store = nextLuaLogIndex()
    local capturedAtUnix = os.time()
    local capturedAt = os.date('%Y-%m-%d %H:%M:%S', capturedAtUnix)
    local logId = buildScreenshotId(nextIndex, capturedAtUnix)
    local filename = buildLuaLogFilename(logId)
    local absPath = TARGET_DIR .. filename
    local quickPath = 'internal://files/' .. filename
    local content = title .. '\n\n'
        .. '编号: ' .. logId .. '\n'
        .. '时间: ' .. capturedAt .. '\n'
        .. '来源: Lua\n'
        .. (summary and summary ~= '' and ('摘要: ' .. summary .. '\n') or '')
        .. '\n'
        .. (message or '')

    if not writeFile(absPath, content) then
        return false
    end

    local item = {
        index = nextIndex,
        logId = logId,
        file = quickPath,
        name = filename,
        capturedAt = capturedAt,
        capturedAtUnix = capturedAtUnix,
        source = 'lua',
        title = title,
        summary = summary or ''
    }
    table.insert(store.items, 1, item)
    while #store.items > LOG_HISTORY_LIMIT do
        table.remove(store.items)
    end
    store.lastItem = store.items[1]
    store.nextIndex = nextIndex + 1
    writeLuaLogStore(store)
    return true
end

writeLuaEventLog = function(title, summary, message)
    pcall(function()
        appendLuaLogEntry(title, summary, message)
    end)
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

local function buildCrcTable()
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
    return crcTable
end

local function makePngWriter(path)
    local fPng = io.open(path, 'wb')
    if not fPng then
        return nil
    end

    local crcTable = buildCrcTable()

    local function writeInt32(n)
        fPng:write(string.char(
            (n >> 24) & 0xFF,
            (n >> 16) & 0xFF,
            (n >> 8) & 0xFF,
            n & 0xFF
        ))
    end

    local function crcUpdate(crc, data)
        for i = 1, #data do
            crc = (crc >> 8) ~ crcTable[(crc ~ string.byte(data, i)) & 0xFF]
        end
        return crc
    end

    local function writeChunk(typeName, length, writeBody)
        local crc = 0xFFFFFFFF
        writeInt32(length)
        fPng:write(typeName)
        crc = crcUpdate(crc, typeName)
        local safe, ok, err = pcall(writeBody, function(data)
            if not data or data == '' then return end
            fPng:write(data)
            crc = crcUpdate(crc, data)
        end)
        if not safe then
            return false, tostring(ok)
        end
        if not ok then
            return false, err
        end
        writeInt32(crc ~ 0xFFFFFFFF)
        return true
    end

    return {
        file = fPng,
        writeInt32 = writeInt32,
        writeChunk = writeChunk,
        close = function()
            fPng:close()
        end
    }
end

local function updateAdler32(a, b, data)
    for i = 1, #data do
        a = (a + string.byte(data, i)) % 65521
        b = (b + a) % 65521
    end
    return a, b
end

local function bgrRowToPngScanline(rowData, width)
    if not rowData or #rowData < width * 3 then
        return nil
    end
    local parts = { '\0' }
    local out = 2
    for x = 0, width - 1 do
        local p = x * 3 + 1
        local b = string.byte(rowData, p) or 0
        local g = string.byte(rowData, p + 1) or 0
        local r = string.byte(rowData, p + 2) or 0
        parts[out] = string.char(r, g, b)
        out = out + 1
    end
    return table.concat(parts)
end

local function writePngFromRaw(rawPath, path, width, height)
    local fRaw = io.open(rawPath, 'rb')
    if not fRaw then
        return false, '无法读取截图临时文件'
    end

    local writer = makePngWriter(path)
    if not writer then
        fRaw:close()
        return false, '无法创建 PNG 文件'
    end

    local rowLen = width * 3
    local scanlineLen = rowLen + 1
    local idatLen = 2 + height * (5 + scanlineLen) + 4
    local a, b = 1, 0
    local ok = true
    local err = nil

    writer.file:write('\137PNG\r\n\026\n')
    ok, err = writer.writeChunk('IHDR', 13, function(write)
        write(string.char(
            (width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF, width & 0xFF,
            (height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF, height & 0xFF,
            8, 2, 0, 0, 0
        ))
        return true
    end)
    if not ok then
        fRaw:close()
        writer.close()
        removeFile(path)
        return false, err or 'PNG 头写入失败'
    end

    ok, err = writer.writeChunk('IDAT', idatLen, function(write)
        write('\x78\x01')
        for y = 0, height - 1 do
            local row = fRaw:read(rowLen)
            if not row or #row < rowLen then
                return false, '截图数据不足'
            end
            local scanline = bgrRowToPngScanline(row, width)
            if not scanline then
                return false, '像素转换失败'
            end
            local final = (y == height - 1) and 1 or 0
            local l = scanlineLen & 0xFF
            local h = (scanlineLen >> 8) & 0xFF
            write(string.char(final, l, h, 255 - l, 255 - h))
            write(scanline)
            a, b = updateAdler32(a, b, scanline)
        end
        write(string.char(
            (b >> 8) & 0xFF,
            b & 0xFF,
            (a >> 8) & 0xFF,
            a & 0xFF
        ))
        return true
    end)
    if not ok then
        fRaw:close()
        writer.close()
        removeFile(path)
        return false, err or 'PNG 数据写入失败'
    end

    ok, err = writer.writeChunk('IEND', 0, function()
        return true
    end)
    fRaw:close()
    writer.close()
    if not ok then
        removeFile(path)
        return false, err or 'PNG 结束块写入失败'
    end
    return true
end

local function copyStream(input, output, totalBytes)
    local remaining = tonumber(totalBytes) or 0
    while remaining > 0 do
        local requestSize = remaining > SCREENSHOT_CHUNK_SIZE and SCREENSHOT_CHUNK_SIZE or remaining
        local readOk, chunk = pcall(input.read, input, requestSize)
        if not readOk then
            return false
        end
        if not chunk or chunk == '' then
            return false
        end
        local ok = pcall(output.write, output, chunk)
        if not ok then
            return false
        end
        remaining = remaining - #chunk
    end
    return true
end

local function copyFileChunked(srcPath, dstPath, totalBytes)
    removeFile(dstPath)
    local input = io.open(srcPath, 'rb')
    local output = io.open(dstPath, 'wb')
    if not input or not output then
        if input then input:close() end
        if output then output:close() end
        return false
    end
    local ok = copyStream(input, output, totalBytes)
    input:close()
    output:close()
    if ok and fileSize(dstPath) >= totalBytes then
        return true
    end
    removeFile(dstPath)
    return false
end

local function cloneScreenshotProfile(profile, skipRows)
    return {
        name = profile.name,
        method = profile.method,
        width = profile.width,
        height = profile.height,
        strideBytes = profile.strideBytes,
        skipRows = skipRows,
        offsetBytes = profile.strideBytes * skipRows,
        rawBytes = profile.rawBytes,
        readBytes = profile.readBytes or profile.rawBytes,
        readRows = profile.readRows or profile.height,
        minRawBytes = profile.minRawBytes or profile.rawBytes,
        pixelFormat = profile.pixelFormat
    }
end

local function scoreScreenshotRaw(path, profile)
    local f = io.open(path, 'rb')
    if not f then return -1 end
    local score = 0
    local rowLen = profile.strideBytes
    local step = 6
    for y = 1, profile.height do
        local row = f:read(rowLen)
        if not row or #row < rowLen then break end
        if y % 4 == 0 then
            local x = 1
            while x <= rowLen - 2 do
                local b = string.byte(row, x) or 0
                local g = string.byte(row, x + 1) or 0
                local r = string.byte(row, x + 2) or 0
                if b > 180 and g > 70 and g < 180 and r < 80 then
                    score = score + 8
                elseif b > 130 and g > 40 and r < 100 then
                    score = score + 1
                end
                x = x + step * 3
            end
        end
    end
    f:close()
    return score
end

local function captureFramebufferSingleToFile(path, profile)
    profile = profile or getScreenshotProfile()
    removeFile(path)
    local input = io.open(FB_PATH, 'rb')
    local output = io.open(path, 'wb')
    if input and output then
        local seekOk, seekPos = pcall(input.seek, input, 'set', profile.offsetBytes)
        if seekOk and seekPos then
            copyStream(input, output, profile.readBytes or profile.rawBytes)
        end
        input:close()
        output:close()
        local size = fileSize(path)
        if size >= profile.rawBytes then
            return true
        end
        if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
            return true
        end
        removeFile(path)
    else
        if input then input:close() end
        if output then output:close() end
    end

    os.execute('dd if=' .. FB_PATH .. ' of=' .. path .. ' bs=' .. tostring(profile.strideBytes) .. ' skip=' .. tostring(profile.skipRows) .. ' count=' .. tostring(profile.readRows or profile.height) .. ' 2>/dev/null')
    local size = fileSize(path)
    if size >= profile.rawBytes then
        return true
    end
    if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
        return true
    end
    removeFile(path)
    return false
end

local function captureFramebufferToFile(path, profile)
    profile = profile or getScreenshotProfile()
    if type(profile.candidateSkipRows) ~= 'table' or #profile.candidateSkipRows == 0 then
        return captureFramebufferSingleToFile(path, profile)
    end

    local bestPath = ''
    local bestScore = -1
    for i, skipRows in ipairs(profile.candidateSkipRows) do
        local candidateProfile = cloneScreenshotProfile(profile, skipRows)
        local candidatePath = path .. '.p' .. tostring(i)
        if captureFramebufferSingleToFile(candidatePath, candidateProfile) then
            local score = scoreScreenshotRaw(candidatePath, candidateProfile)
            addLog('[shot] candidate skip=' .. tostring(skipRows) .. ' score=' .. tostring(score))
            if score > bestScore then
                if bestPath ~= '' then removeFile(bestPath) end
                bestPath = candidatePath
                bestScore = score
                profile.skipRows = skipRows
                profile.offsetBytes = candidateProfile.offsetBytes
            else
                removeFile(candidatePath)
            end
        else
            removeFile(candidatePath)
        end
    end

    if bestPath == '' then
        return false
    end
    local ok = copyFileChunked(bestPath, path, profile.rawBytes)
    removeFile(bestPath)
    return ok
end

local function captureFramebufferLegacy(path, profile)
    profile = profile or getScreenshotProfile()
    removeFile(path)
    os.execute('dd if=' .. FB_PATH .. ' of=' .. path .. ' bs=' .. tostring(profile.strideBytes) .. ' skip=' .. tostring(profile.skipRows) .. ' count=' .. tostring(profile.height) .. ' 2>/dev/null')
    local size = fileSize(path)
    if size >= profile.rawBytes then
        return true
    end
    if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
        return true
    end
    removeFile(path)
    return false
end

local function screenshotDiagText(state, profile)
    profile = profile or getScreenshotProfile()
    local allocated = 0
    local ok, kb = pcall(collectgarbage, 'count')
    if ok and kb then
        allocated = math.floor((tonumber(kb) or 0) * 1024)
    end
    return 'request_size=' .. tostring(profile.rawBytes)
        .. '\ntotal_free_heap=-'
        .. '\nlargest_free_block=-'
        .. '\ncurrent_allocated=' .. tostring(allocated)
        .. '\npid=-'
        .. '\ntid=-'
        .. '\nscreenshot_state=' .. tostring(state or '-')
        .. '\nframebuffer_size=' .. tostring(profile.rawBytes)
        .. '\npixel_format=' .. tostring(profile.pixelFormat)
        .. '\nscreenshot_profile=' .. tostring(profile.name)
        .. '\nscreen=' .. tostring(profile.width) .. 'x' .. tostring(profile.height)
        .. '\nstride_bytes=' .. tostring(profile.strideBytes)
        .. '\nskip_rows=' .. tostring(profile.skipRows)
        .. '\nread_rows=' .. tostring(profile.readRows or profile.height)
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
    local profile = getScreenshotProfile()
    local isStreamProfile = profile.method == 'stream'
    addLog('[shot] capture profile=' .. tostring(profile.name) .. ' bytes=' .. tostring(profile.rawBytes))
    writeLuaEventLog('截图诊断', '开始采集', screenshotDiagText('capture_start', profile))
    local captured = false
    if isStreamProfile then
        captured = captureFramebufferToFile(TMP_RAW, profile)
    else
        captured = captureFramebufferLegacy(TMP_RAW, profile)
    end
    if not captured then
        removeFile(TMP_RAW)
        writeLuaEventLog('截图诊断', '采集失败', screenshotDiagText('capture_failed', profile))
        return nil, '截图数据不足'
    end

    local index = nextScreenshotIndex()
    local capturedAtUnix = os.time()
    local capturedAt = os.date('%Y-%m-%d %H:%M:%S', capturedAtUnix)
    local shotId = buildScreenshotId(index, capturedAtUnix)
    local debugConfig = getScreenshotDebugConfig()
    local filename = ''
    local outPath = ''
    local quickPath = ''
    local metaFile = ''
    local metaQuickPath = ''
    local ok = false
    local source = 'framebuffer'
    local message = '截图完成'
    local rawData = nil

    if not isStreamProfile then
        local fRaw = io.open(TMP_RAW, 'rb')
        if not fRaw then
            removeFile(TMP_RAW)
            return nil, '无法读取截图临时文件'
        end
        rawData = fRaw:read('*a') or ''
        fRaw:close()
        if #rawData < profile.rawBytes then
            rawData = nil
            removeFile(TMP_RAW)
            return nil, '截图数据不足'
        end
    end

    if debugConfig.saveRaw then
        filename = buildScreenshotRawFilename(shotId)
        outPath = SCREENSHOT_DIR .. filename
        quickPath = 'internal://files/screenshots/' .. filename
        metaFile = buildScreenshotMetaFilename(shotId)
        metaQuickPath = 'internal://files/screenshots/' .. metaFile
        if isStreamProfile then
            ok = copyFileChunked(TMP_RAW, outPath, profile.rawBytes)
        else
            ok = writeBinaryFile(outPath, rawData)
        end
        if not ok then
            rawData = nil
            removeFile(TMP_RAW)
            return nil, '原始像素写入失败'
        end
        writeFile(SCREENSHOT_DIR .. metaFile, jsonEncode({
            shotId = shotId,
            capturedAt = capturedAt,
            capturedAtUnix = capturedAtUnix,
            screenWidth = SCREEN_W,
            screenHeight = SCREEN_H,
            strideBytes = STRIDE_BYTES,
            rawBytes = fileSize(outPath),
            pixelFormatGuess = 'bgr888',
            source = 'framebuffer_raw'
        }))
        source = 'framebuffer_raw'
        message = '原始像素已保存'
    else
        filename = buildScreenshotFilename(shotId)
        outPath = SCREENSHOT_DIR .. filename
        quickPath = 'internal://files/screenshots/' .. filename
        if isStreamProfile then
            ok = writePngFromRaw(TMP_RAW, outPath, profile.width, profile.height)
        else
            local rgbData = extractRgb888(rawData)
            rawData = nil
            pcall(collectgarbage, 'collect')
            ok = writePng(outPath, profile.width, profile.height, rgbData)
            rgbData = nil
        end
        if not ok then
            rawData = nil
            removeFile(TMP_RAW)
            pcall(collectgarbage, 'collect')
            return nil, 'PNG 写入失败'
        end
    end

    rawData = nil
    removeFile(TMP_RAW)
    pcall(collectgarbage, 'collect')
    writeLuaEventLog('截图诊断', '采集完成', screenshotDiagText('capture_done', profile))
    os.execute('sync')

    local item = {
        seq = req.seq,
        index = index,
        shotId = shotId,
        file = quickPath,
        metaFile = metaQuickPath,
        name = filename,
        capturedAt = capturedAt,
        capturedAtUnix = capturedAtUnix,
        requestTimestamp = tonumber(req.timestamp) or 0,
        screenWidth = SCREEN_W,
        screenHeight = SCREEN_H,
        source = source,
        message = message
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
                writeLuaEventLog('命令请求解析失败', 'cmd_request.json 解析失败',
                    '文件: cmd_request.json\n说明: 连续两次读取后仍无法解析 JSON。')
                lastParseError = now
            end
            return nil
        end
    end
    if not json.seq or not json.cmd then
        return nil
    end
    if not validateIpcGuard(json, 'cmd_request.json') then
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
    if not validateIpcGuard(json, 'screenshot_request.json') then
        return nil
    end
    return {
        seq = json.seq,
        type = 'screenshot',
        timestamp = json.timestamp
    }
end

local function readFileRequest()
    local reqFile = TARGET_DIR .. 'file_request.json'
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
    if not json.seq or not json.action then
        return nil
    end
    if not validateIpcGuard(json, 'file_request.json') then
        return nil
    end
    return {
        seq = json.seq,
        type = 'file',
        action = json.action,
        path = json.path or '/',
        dest = json.dest or '',
        content = json.content or '',
        offset = tonumber(json.offset) or 0,
        length = tonumber(json.length) or 128,
        limit = tonumber(json.limit) or 4096,
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

local function writeFileResult(req, result)
    result = result or {}
    result.type = 'file_result'
    result.seq = req and req.seq or -1
    result.action = req and req.action or ''
    result.timestamp = os.date('%H:%M:%S')
    atomicWrite('file_result.json', result)
    os.remove(TARGET_DIR .. 'file_request.json')
end

local function finishScreenshotError(message)
    local req = screenshotReq or { seq = -1 }
    local phase = screenshotPhase
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'error',
        message = message,
        timestamp = os.date('%H:%M:%S')
    })
    writeLuaEventLog('截图失败', message or '截图失败',
        '序号: ' .. tostring(req.seq or -1) .. '\n阶段: ' .. tostring(phase ~= '' and phase or '-') .. '\n结果: ' .. tostring(message or '截图失败'))
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
        message = item.message or '截图完成',
        index = item.index,
        shotId = item.shotId,
        file = item.file,
        metaFile = item.metaFile,
        name = item.name,
        capturedAt = item.capturedAt,
        capturedAtUnix = item.capturedAtUnix,
        requestTimestamp = item.requestTimestamp,
        screenWidth = item.screenWidth,
        screenHeight = item.screenHeight,
        source = item.source,
        timestamp = os.date('%H:%M:%S')
    })
    writeLuaEventLog('截图完成', item.shotId or '',
        '序号: ' .. tostring(item.seq or -1)
        .. '\n编号: ' .. tostring(item.shotId or '')
        .. '\n文件: ' .. tostring(item.file or '')
        .. '\n尺寸: ' .. tostring(item.screenWidth or 0) .. 'x' .. tostring(item.screenHeight or 0))
    writeBridgeState(false, '', '')
    notifyScreenshotSuccess()
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
    local message = '请熄屏后重新亮屏'
    writeBridgeState(true, 'screenshot', message)
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'waiting_screen_on',
        message = message,
        timestamp = os.date('%H:%M:%S')
    })
    os.remove(TARGET_DIR .. 'screenshot_request.json')
    addLog('[shot] waiting for screen on')
    writeLuaEventLog('截图请求', '等待亮屏', '序号: ' .. tostring(req.seq or -1) .. '\n状态: 请熄屏后重新亮屏')
end

local function captureLogPageScreenshot()
    if cmdBusy then
        addLog('[shot] busy')
        return
    end
    if not isRunning then
        addLog('[shot] service not running')
        return
    end
    localScreenshotSeq = localScreenshotSeq + 1
    local req = {
        seq = localScreenshotSeq,
        type = 'screenshot',
        timestamp = os.time(),
        source = 'lua_log_page'
    }
    screenshotReq = req
    screenshotPhase = 'capture_now'
    cmdBusy = true
    busyMode = 'screenshot'
    writeBridgeState(true, 'screenshot', '日志页截图中')
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'capturing',
        message = '日志页截图中',
        timestamp = os.date('%H:%M:%S')
    })
    addLog('[shot] capture from log page')
    local item, err = captureScreenshot(req)
    if item then
        addLog('[shot] saved #' .. tostring(item.index))
        finishScreenshotSuccess(item)
    else
        addLog('[shot] failed: ' .. tostring(err))
        finishScreenshotError(err or '截图失败')
    end
end

local function normalizeFileManagerPath(path)
    path = tostring(path or '/')
    if path == '' then path = '/' end
    if string.sub(path, 1, 1) ~= '/' then path = '/' .. path end
    return path
end

local function basename(path)
    path = tostring(path or '')
    if path ~= '/' and string.sub(path, -1) == '/' then
        path = string.sub(path, 1, -2)
    end
    local name = string.match(path, '([^/]+)$')
    return name or path
end

local function joinFilePath(base, name)
    base = normalizeFileManagerPath(base)
    name = tostring(name or '')
    if base == '/' then return '/' .. name end
    if string.sub(base, -1) == '/' then return base .. name end
    return base .. '/' .. name
end

local function fileManagerSize(path)
    local ok, size = pcall(function()
        local f = lvgl.fs.open_file(path, 'r')
        if not f then return nil end
        local len = f:seek('end')
        f:close()
        return len
    end)
    if ok and size then return tostring(size) end
    return '-'
end

local function fileManagerList(path)
    path = normalizeFileManagerPath(path)
    local ok, dir, msg = pcall(lvgl.fs.open_dir, path)
    if not ok or not dir then
        return { status = 'error', message = tostring(msg or 'open dir failed'), path = path, items = {} }
    end
    local items = {}
    while true do
        local readOk, entry = pcall(dir.read, dir)
        if not readOk or not entry then break end
        local isDir = string.byte(entry, 1) == string.byte('/', 1)
        local name = isDir and string.sub(entry, 2) or entry
        local fullPath
        if isDir then
            fullPath = path == '/' and entry or (path .. entry)
        else
            fullPath = joinFilePath(path, entry)
        end
        items[#items + 1] = {
            name = name,
            path = fullPath,
            isDir = isDir,
            size = isDir and '-' or fileManagerSize(fullPath)
        }
    end
    pcall(dir.close, dir)
    table.sort(items, function(a, b)
        if a.isDir ~= b.isDir then return a.isDir end
        return tostring(a.name) < tostring(b.name)
    end)
    return { status = 'ok', path = path, items = items }
end

local function fileManagerInfo(path)
    path = normalizeFileManagerPath(path)
    return { status = 'ok', path = path, name = basename(path), size = fileManagerSize(path) }
end

local function sanitizeFileText(text)
    text = tostring(text or '')
    local out = {}
    for i = 1, #text do
        local byte = string.byte(text, i)
        if byte == 9 or byte == 10 or byte == 13 or byte >= 32 then
            out[#out + 1] = string.char(byte)
        else
            out[#out + 1] = '.'
        end
    end
    return table.concat(out)
end

local function fileManagerText(path, limit)
    path = normalizeFileManagerPath(path)
    limit = tonumber(limit) or 4096
    if limit < 512 then limit = 512 end
    if limit > 16384 then limit = 16384 end
    local ok, content = pcall(function()
        local f = lvgl.fs.open_file(path, 'r')
        if not f then return nil end
        local text = f:read(limit)
        f:close()
        return text or ''
    end)
    if not ok or content == nil then
        return { status = 'error', message = 'read failed', path = path, content = '' }
    end
    return { status = 'ok', path = path, content = sanitizeFileText(content) }
end

local function fileManagerHex(path, offset, length)
    path = normalizeFileManagerPath(path)
    offset = tonumber(offset) or 0
    length = tonumber(length) or 128
    if offset < 0 then offset = 0 end
    if length < 16 then length = 16 end
    if length > 512 then length = 512 end
    local ok, content = pcall(function()
        local f = lvgl.fs.open_file(path, 'r')
        if not f then return nil end
        f:seek('set', offset)
        local bytes = f:read(length) or ''
        f:close()
        local lines = {}
        local line = string.format('%08X  ', offset)
        for i = 1, #bytes do
            line = line .. string.format('%02X ', string.byte(bytes, i))
            if i % 8 == 0 then
                lines[#lines + 1] = line
                line = string.format('%08X  ', offset + i)
            end
        end
        if #bytes % 8 ~= 0 or #bytes == 0 then
            lines[#lines + 1] = line
        end
        return table.concat(lines, '\n')
    end)
    if not ok or content == nil then
        return { status = 'error', message = 'hex read failed', path = path, content = '' }
    end
    return { status = 'ok', path = path, content = content, offset = offset }
end

local function fileManagerWrite(req)
    local path = normalizeFileManagerPath(req.path)
    local content = tostring(req.content or '')
    local ok = pcall(function()
        local f = lvgl.fs.open_file(path, 'w')
        if not f then error('open failed') end
        f:write(content)
        f:close()
    end)
    return { status = ok and 'ok' or 'error', message = ok and '保存完成' or '保存失败', path = path, size = tostring(#content) }
end

local function copyFileRaw(src, dst)
    local ok1, input = pcall(lvgl.fs.open_file, src, 'r')
    if not ok1 or not input then return false end
    local ok2, output = pcall(lvgl.fs.open_file, dst, 'w')
    if not ok2 or not output then pcall(input.close, input); return false end
    local success = true
    while true do
        local readOk, chunk = pcall(input.read, input, 4096)
        if not readOk or not chunk or chunk == '' then break end
        local writeOk = pcall(output.write, output, chunk)
        if not writeOk then success = false; break end
        if #chunk < 4096 then break end
    end
    pcall(input.close, input)
    pcall(output.close, output)
    return success
end

local function fileManagerCopy(req)
    local src = normalizeFileManagerPath(req.path)
    local dst = joinFilePath(req.dest ~= '' and req.dest or '/', basename(src))
    local ok = copyFileRaw(src, dst)
    return { status = ok and 'ok' or 'error', message = ok and '复制完成' or '复制失败', path = src, dest = dst }
end

local function fileManagerMove(req)
    local src = normalizeFileManagerPath(req.path)
    local dst = joinFilePath(req.dest ~= '' and req.dest or '/', basename(src))
    local ok = false
    if os and type(os.rename) == 'function' then
        local safe, renamed = pcall(os.rename, src, dst)
        ok = safe and renamed == true
    end
    if not ok then
        ok = copyFileRaw(src, dst)
        if ok and os and type(os.remove) == 'function' then pcall(os.remove, src) end
    end
    return { status = ok and 'ok' or 'error', message = ok and '移动完成' or '移动失败', path = src, dest = dst }
end

local function fileManagerDelete(req)
    local path = normalizeFileManagerPath(req.path)
    local ok = false
    if os and type(os.remove) == 'function' then
        local safe, removed = pcall(os.remove, path)
        ok = safe and removed == true
    end
    return { status = ok and 'ok' or 'error', message = ok and '删除完成' or '删除失败', path = path }
end

local function executeFileRequest(req)
    if req.action == 'list' then return fileManagerList(req.path) end
    if req.action == 'info' then return fileManagerInfo(req.path) end
    if req.action == 'text' then return fileManagerText(req.path, req.limit) end
    if req.action == 'write' then return fileManagerWrite(req) end
    if req.action == 'hex' then return fileManagerHex(req.path, req.offset, req.length) end
    if req.action == 'copy' then return fileManagerCopy(req) end
    if req.action == 'move' then return fileManagerMove(req) end
    if req.action == 'delete' then return fileManagerDelete(req) end
    return { status = 'error', message = '未知文件操作' }
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
    local elapsed = os.time() - cmdStartTime
    if elapsed * 1000 < CMD_TIMEOUT then return end

    local timedOutCmd = currentCmd
    local timedOutReq = currentReq
    addLog('[!] Command timed out: ' .. timedOutCmd)
    writeLuaEventLog('命令执行超时', timedOutCmd or '',
        '序号: ' .. tostring(timedOutReq and timedOutReq.seq or -1)
        .. '\n命令: ' .. tostring(timedOutCmd or '')
        .. '\n超时: ' .. tostring(CMD_TIMEOUT) .. 'ms')

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

local function checkFileRequest()
    if cmdBusy then return end
    if not isRunning then return end

    local req = readFileRequest()
    if not req then return end

    cmdBusy = true
    busyMode = 'file'
    writeBridgeState(true, 'file', '文件操作中')
    local result = executeFileRequest(req)
    writeFileResult(req, result)
    writeLuaEventLog('文件管理', req.action or '',
        '序号: ' .. tostring(req.seq or -1)
        .. '\n操作: ' .. tostring(req.action or '')
        .. '\n路径: ' .. tostring(req.path or '')
        .. '\n目标: ' .. tostring(req.dest or '')
        .. '\n状态: ' .. tostring(result and result.status or '-'))
    cmdBusy = false
    busyMode = ''
    writeBridgeState(false, '', '')
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
    cmdStartTime = os.time()
    writeBridgeState(true, 'cmd', '命令执行中')
    local result = executeShellCommand(req.cmd)
    writeCommandResult(req, result)
    local stdoutPreview = result.stdout or ''
    if #stdoutPreview > 2048 then
        stdoutPreview = stdoutPreview:sub(1, 2048) .. '\n...[truncated]'
    end
    writeLuaEventLog('命令执行', req.cmd or '',
        '序号: ' .. tostring(req.seq or -1)
        .. '\n命令: ' .. tostring(req.cmd or '')
        .. '\n退出码: ' .. tostring(result.exitcode or -1)
        .. '\nstdout字节: ' .. tostring(#(result.stdout or ''))
        .. '\nstderr字节: ' .. tostring(#(result.stderr or ''))
        .. '\n\n输出预览:\n' .. stdoutPreview)
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
    local ok, msg = resolveTargetDirByDeviceInfo()
    if not ok then
        addLog(msg)
        return
    end
    isRunning = true; cmdBusy = false; busyMode = ''
    pcall(os.execute, 'mkdir -p "' .. TARGET_DIR .. '"')
    pcall(os.execute, 'mkdir -p "' .. SCREENSHOT_DIR .. '"')
    writeBridgeState(false, '', '')
    rotateIpcGuard()
    writeHeartbeat()
    addLog('>>> Service Started')
    writeLuaEventLog('服务启动', 'Terminal Bridge 已启动',
        '设备代号: ' .. activeDeviceProduct
        .. '\n设备型号: ' .. activeDeviceModel
        .. '\n读取目录: ' .. activeDeviceSourceDir
        .. '\n工作目录: ' .. TARGET_DIR
        .. '\n屏幕: ' .. tostring(SCREEN_W) .. 'x' .. tostring(SCREEN_H))

    cmdTimer = lvgl.Timer({ period = 500, repeat_count = -1,
        cb = function()
            if isRunning then
                checkFileRequest()
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

    if startBtn then startBtn:set { bg_color = UI_DANGER } end
    if startBtnLabel then startBtnLabel:set { text = "STOP", text_color = UI_TEXT } end
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
    writeLuaEventLog('服务停止', 'Terminal Bridge 已停止', '目录: ' .. TARGET_DIR)
    if startBtn then startBtn:set { bg_color = UI_PRIMARY } end
    if startBtnLabel then startBtnLabel:set { text = "START", text_color = UI_TEXT } end
end

local function clearLog()
    statusBuffer = {}
    refreshTerminal()
end


-- ====== 页面构建（单文件多页面，切页用 root:clean() 重建）======

-- home：表盘页。上半屏居中显示时间；下半屏居中随机一只动态精灵，点击进入 shell
buildHomePage = function()
    currentPage = 'home'
    -- shell 页控件已随 root:clean() 销毁，引用置空以触发各刷新函数的 nil 守卫
    terminal = nil
    logTerminal = nil
    resetLogTap()
    startBtn = nil
    startBtnLabel = nil
    clearBtn = nil
    root:clean()

    -- 时间：在上半屏水平+垂直居中显示（仅时间，不再显示日期/星期）
    timeLabel = lvgl.Label(root, {
        x = 0, y = math.floor((math.floor(SCREEN_H / 2) - 120) / 2),
        text = os.date('%H:%M'),
        text_font = lvgl.Font("MiSans-Regular", 120),
        text_color = UI_TEXT,
        align = lvgl.ALIGN.TOP_MID,
    })

    -- 下半屏精灵容器（绝对坐标，不设 align；可点击 → 进入 shell）
    local spriteBox = lvgl.Object(root, {
        x = 0, y = math.floor(SCREEN_H / 2),
        w = SCREEN_W, h = math.floor(SCREEN_H / 2),
        bg_opa = 0,
        border_width = 0,
        pad_all = 0,
    })
    spriteBox:clear_flag(lvgl.FLAG.SCROLLABLE)
    spriteBox:add_flag(lvgl.FLAG.CLICKABLE)
    spriteBox:onevent(lvgl.EVENT.CLICKED, function() buildShellPage() end)

    -- 预建 12x12 方块网格并在下半屏居中；动画只改方块颜色/透明度，不重建
    spriteCells = {}
    local spanW = SPRITE_COLS * SPRITE_CELL
    local spanH = SPRITE_ROWS * SPRITE_CELL
    local originX = math.floor((SCREEN_W - spanW) / 2)
    local originY = math.floor((math.floor(SCREEN_H / 2) - spanH) / 2)
    for r = 1, SPRITE_ROWS do
        for c = 1, SPRITE_COLS do
            local cell = lvgl.Object(spriteBox, {
                x = originX + (c - 1) * SPRITE_CELL,
                y = originY + (r - 1) * SPRITE_CELL,
                w = SPRITE_CELL, h = SPRITE_CELL,
                bg_color = UI_TEXT,
                bg_opa = 0,
                border_width = 0,
                radius = 0,
                pad_all = 0,
            })
            cell:clear_flag(lvgl.FLAG.SCROLLABLE)
            cell:add_flag(lvgl.FLAG.EVENT_BUBBLE)  -- 点击穿透到容器 → 进入 shell
            spriteCells[(r - 1) * SPRITE_COLS + c] = cell
        end
    end

    resetSprite()
    renderSprite()
    updateClock()
end

-- shell：终端页。左侧返回按钮、右侧标题 shell++；中部日志卡片；底部 START/STOP、CLEAR
buildShellPage = function()
    currentPage = 'shell'
    logTerminal = nil
    resetLogTap()
    timeLabel = nil
    dateLabel = nil
    weekLabel = nil
    spriteCells = nil
    root:clean()

    -- 顶栏：左返回按钮（圆形：宽高相等、半径取一半）
    local backDiam = UI_TOPBAR_H - UI_GAP
    local backBtn = lvgl.Object(root, {
        x = UI_GAP, y = UI_GAP,
        w = backDiam, h = backDiam,
        bg_color = UI_CARD,
        radius = math.floor(backDiam / 2),
        border_width = 0,
        pad_all = 0,
    })
    backBtn:clear_flag(lvgl.FLAG.SCROLLABLE)
    backBtn:add_flag(lvgl.FLAG.CLICKABLE)
    local backLbl = lvgl.Label(backBtn, {
        align = lvgl.ALIGN.CENTER,
        text = '<',
        text_font = lvgl.Font("MiSans-Regular", 32),
        text_color = UI_TEXT,
    })
    backLbl:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    backBtn:onevent(lvgl.EVENT.CLICKED, function() buildHomePage() end)

    -- 顶栏：右标题，Label 用 align 靠右；垂直下移与圆形返回按钮居中对齐
    lvgl.Label(root, {
        x = 220, y = 12,
        text = 'shell++',
        text_font = lvgl.Font("MiSans-Regular", 32),
        text_color = UI_TEXT,
    })

    -- 底部按钮：缩小按钮，释放终端空间
    local panelY = SCREEN_H - UI_GAP - UI_BTN_H
    local TERM_TOP = UI_TOPBAR_H + UI_GAP
    local btnW = math.floor((SCREEN_W - UI_GAP * 3) / 2)

    terminal = lvgl.Textarea(root, {
        x = UI_GAP, y = TERM_TOP,
        w = SCREEN_W - UI_GAP * 2,
        h = panelY - UI_GAP - TERM_TOP,
        text = '',
        bg_color = UI_CARD,
        radius = UI_CARD_RADIUS,
        text_font = lvgl.Font("MiSans-Regular", 20),
        text_color = UI_TERM_TEXT,
        border_width = 0,
        pad_all = 14,
    })
    terminal:add_flag(lvgl.FLAG.SCROLLABLE)
    terminal:add_flag(lvgl.FLAG.CLICKABLE)
    terminal:onevent(lvgl.EVENT.CLICKED, function() onLogCardClicked() end)

    startBtn = lvgl.Object(root, {
        x = UI_GAP, y = panelY,
        w = btnW, h = UI_BTN_H,
        bg_color = isRunning and UI_DANGER or UI_PRIMARY,
        radius = UI_BTN_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    startBtn:clear_flag(lvgl.FLAG.SCROLLABLE)
    startBtn:add_flag(lvgl.FLAG.CLICKABLE)
    startBtnLabel = lvgl.Label(startBtn, {
        align = lvgl.ALIGN.CENTER,
        text = isRunning and 'STOP' or 'START',
        text_font = lvgl.Font("MiSans-Regular", 28),
        text_color = UI_TEXT,
    })
    startBtnLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    startBtn:onevent(lvgl.EVENT.CLICKED, function()
        if isRunning then stopService() else startService() end
    end)

    clearBtn = lvgl.Object(root, {
        x = UI_GAP * 2 + btnW, y = panelY,
        w = btnW, h = UI_BTN_H,
        bg_color = UI_CARD,
        radius = UI_BTN_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    clearBtn:clear_flag(lvgl.FLAG.SCROLLABLE)
    clearBtn:add_flag(lvgl.FLAG.CLICKABLE)
    local clearLbl = lvgl.Label(clearBtn, {
        align = lvgl.ALIGN.CENTER,
        text = 'CLEAR',
        text_font = lvgl.Font("MiSans-Regular", 28),
        text_color = UI_TEXT,
    })
    clearLbl:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    clearBtn:onevent(lvgl.EVENT.CLICKED, function() clearLog() end)

    refreshTerminal()
end

-- log：独立日志页。双击 shell 日志卡片进入，支持滚动查看长日志
buildLogPage = function()
    currentPage = 'log'
    timeLabel = nil
    dateLabel = nil
    weekLabel = nil
    spriteCells = nil
    terminal = nil
    logTerminal = nil
    startBtn = nil
    startBtnLabel = nil
    clearBtn = nil
    root:clean()

    local backDiam = UI_TOPBAR_H - UI_GAP
    local backBtn = lvgl.Object(root, {
        x = UI_GAP, y = UI_GAP,
        w = backDiam, h = backDiam,
        bg_color = UI_CARD,
        radius = math.floor(backDiam / 2),
        border_width = 0,
        pad_all = 0,
    })
    backBtn:clear_flag(lvgl.FLAG.SCROLLABLE)
    backBtn:add_flag(lvgl.FLAG.CLICKABLE)
    local backLbl = lvgl.Label(backBtn, {
        align = lvgl.ALIGN.CENTER,
        text = '<',
        text_font = lvgl.Font("MiSans-Regular", 32),
        text_color = UI_TEXT,
    })
    backLbl:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    backBtn:onevent(lvgl.EVENT.CLICKED, function() buildShellPage() end)

    lvgl.Label(root, {
        x = 88, y = 14,
        text = '日志输出',
        text_font = lvgl.Font("MiSans-Regular", 30),
        text_color = UI_TEXT,
    })

    local shotW = 116
    local clearW = 116
    local clearH = UI_BTN_H
    local clearY = SCREEN_H - UI_GAP - clearH
    logTerminal = lvgl.Textarea(root, {
        x = UI_GAP, y = UI_TOPBAR_H + UI_GAP,
        w = SCREEN_W - UI_GAP * 2,
        h = clearY - UI_GAP - (UI_TOPBAR_H + UI_GAP),
        text = '',
        bg_color = UI_CARD,
        radius = UI_CARD_RADIUS,
        text_font = lvgl.Font("MiSans-Regular", 20),
        text_color = UI_TERM_TEXT,
        border_width = 0,
        pad_all = 14,
    })
    logTerminal:add_flag(lvgl.FLAG.SCROLLABLE)
    logTerminal:add_flag(lvgl.FLAG.CLICKABLE)

    local shotBtnLog = lvgl.Object(root, {
        x = UI_GAP, y = clearY,
        w = shotW, h = clearH,
        bg_color = UI_PRIMARY,
        radius = UI_BTN_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    shotBtnLog:clear_flag(lvgl.FLAG.SCROLLABLE)
    shotBtnLog:add_flag(lvgl.FLAG.CLICKABLE)
    local shotLbl = lvgl.Label(shotBtnLog, {
        align = lvgl.ALIGN.CENTER,
        text = '截图',
        text_font = lvgl.Font("MiSans-Regular", 28),
        text_color = UI_TEXT,
    })
    shotLbl:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    shotBtnLog:onevent(lvgl.EVENT.CLICKED, function() captureLogPageScreenshot() end)

    local clearBtnLog = lvgl.Object(root, {
        x = SCREEN_W - UI_GAP - clearW, y = clearY,
        w = clearW, h = clearH,
        bg_color = UI_CARD,
        radius = UI_BTN_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    clearBtnLog:clear_flag(lvgl.FLAG.SCROLLABLE)
    clearBtnLog:add_flag(lvgl.FLAG.CLICKABLE)
    local clearLbl = lvgl.Label(clearBtnLog, {
        align = lvgl.ALIGN.CENTER,
        text = 'CLEAR',
        text_font = lvgl.Font("MiSans-Regular", 28),
        text_color = UI_TEXT,
    })
    clearLbl:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    clearBtnLog:onevent(lvgl.EVENT.CLICKED, function() clearLog() end)

    refreshTerminal()
end

-- ====== 启动：动画/时钟定时器（常驻，靠 currentPage 守卫）+ 默认进入表盘 ======

math.randomseed(os.time())

clockTimer = lvgl.Timer({ period = 1000, repeat_count = -1,
    cb = function() updateClock() end })
clockTimer:resume()

spriteTimer = lvgl.Timer({ period = 450, repeat_count = -1,
    cb = function()
        if currentPage ~= 'home' or not spriteCells then return end
        spriteFrame = spriteFrame + 1
        renderSprite()
    end })
spriteTimer:resume()

do
    local ok, msg = resolveTargetDirByDeviceInfo()
    if not ok and msg then
        addLog(msg)
    end
end

buildHomePage()
startService()

function ScreenStateChangedCB(pre, now, reason)
    if pre ~= 'ON' and now == 'ON' and currentPage == 'home' then
        resetSprite()
        renderSprite()
        updateClock()
    end
    if not screenshotPending then
        return
    end
    if pre ~= 'ON' and now == 'ON' then
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
