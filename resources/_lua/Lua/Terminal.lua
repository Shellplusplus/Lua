-- Terminal.lua

--
--                        _oo0oo_
--                       o8888888o
--                       88" . "88
--                       (| -_- |)
--                       0\  =  /0
--                     ___/`---'\___
--                   .' \\|     |// '.
--                  / \\|||  :  |||// \
--                 / _||||| -:- |||||- \
--                |   | \\\  - /// |   |
--                | \_|  ''\---/''  |_/ |
--                \  .-\__  '-'  ___/-. /
--              ___'. .'  /--.--\  `. .'___
--           ."" '<  `.___\_<|>_/___.' >' "".
--          | | :  `- \`.;`\ _ /`;.`/ - ` : | |
--          \  \ `_.   \_ __\ /__ _/   .-` /  /
--      =====`-.____`.___ \_____/___.-`___.-'=====
--                        `=---='
--
--
--      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
--            佛祖保佑       永不OOM     永不触发BUG
--
--

--
-- @Author        : AzumaChiaki, IKUN-CXKPRO, ziyimiao, ziyimiao5054
-- @Date          : 2026-06-14 17:21:15
-- @LastEditTime  : 2026-08-07 16:27:28
-- @Project       : Shell++ Lua Backend
--



local BAND9_PRO_DIR = '/data/quickapp/files/com.shell.liangyi/'
local BAND10_PRO_DIR = '/data/data/com.shell.liangyi/'
local BAND10_PRO_FILES_DIR = '/data/files/com.shell.liangyi/'
local DEVICE_INFO_FILE = 'device_info.json'
local SCREENSHOT_DEBUG_FILE = 'screenshot_debug.json'
local DEBUG_TEST_FILE = 'debug_test_mode.json'
local LUA_EXTENSION_SETTINGS_FILE = 'lua_extension_settings.json'
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
FILE_TRANSFER_DEFAULT_CHUNK_SIZE = 16 * 1024
FILE_TRANSFER_MIN_CHUNK_SIZE = 8 * 1024
FILE_TRANSFER_MAX_CHUNK_SIZE = 64 * 1024
fileTransferSession = nil



local isRunning = false
local cmdTimer = nil
local heartbeatTimer = nil
local watchdogTimer = nil
cpuMonitorTimer = nil
cpuLogClearTimer = nil
memoryMonitorTimer = nil
memoryLogClearTimer = nil
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
cpuMonitorEnabled = false
cpuFloatEnabled = false
cpuFloatLayer = nil
cpuFloatLabel = nil
cpuLatestPercent = 0
cpuLatestText = 'CPU:0%'
cpuLogBuffer = {}
cpuRawLogged = false
memoryMonitorEnabled = false
memoryFloatEnabled = false
memoryFloatLayer = nil
memoryFloatLabel = nil
memoryLatestPercent = 0
memoryLatestText = 'MEM:0%'
memoryLogBuffer = {}
memoryRawLogged = false
memoryTotalKb = 0
memoryUsedKb = 0
memoryAvailableKb = 0
memoryFreeKb = 0
memoryLuaKb = 0
screenshotFloatEnabled = false
screenshotFloatLayer = nil
screenshotFloatLabel = nil
screenshotFloatCaptureTimer = nil
CPU_MONITOR_LOG_LIMIT = 12
CPU_MONITOR_INTERVAL_MS = 500
CPU_MONITOR_LOG_CLEAR_MS = 10000
CPU_FLOAT_W = 150
CPU_FLOAT_H = 52
MEMORY_MONITOR_LOG_LIMIT = 12
MEMORY_MONITOR_INTERVAL_MS = 800
MEMORY_MONITOR_LOG_CLEAR_MS = 10000
MEMORY_FLOAT_W = 150
MEMORY_FLOAT_H = 52
MEMORY_FLOAT_Y = CPU_FLOAT_H - 6
SCREENSHOT_FLOAT_W = 150
SCREENSHOT_FLOAT_H = 52
SCREENSHOT_FLOAT_Y = MEMORY_FLOAT_Y + MEMORY_FLOAT_H - 6

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
local currentPage = 'home'      -- 'home' | 'shell' | 'log' | 'cpu' | 'memory'
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
pageRefreshTimer = nil
monitorStatusLabel = nil
monitorLogArea = nil
monitorPageKind = ''
luaExtensionStatusLabel = nil
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
    resetLogTap()
    if false then
        addLog('[menu] lua extension disabled')
        writeLuaEventLog('Lua扩展菜单', '入口未开启', '请在 QuickApp 设置中打开 Lua扩展菜单')
        refreshTerminal()
        return
    end
    buildLogPage()
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

local function containsXiaomiWatchS4(value)
    local compact = string.lower(tostring(value or '')):gsub('%s+', '')
    return compact:find('xiaomiwatchs4', 1, true) ~= nil
end

local function isXiaomiWatchS4()
    return containsXiaomiWatchS4(activeDeviceProduct)
        or containsXiaomiWatchS4(activeDeviceModel)
end

local function getCpuFloatLabelX()
    local product = string.lower(tostring(activeDeviceProduct or ''))
    local model = string.lower(tostring(activeDeviceModel or ''))
    if product == 'redmi watch 6'
        or product == 'redmi watch6'
        or product:find('redmi watch 6', 1, true) ~= nil
        or product:find('redmi watch6', 1, true) ~= nil
        or model == 'm2523w1' then
        return 9
    end
    if product == 'xiaomi smart band 9 pro'
        or product:find('xiaomi smart band 9 pro', 1, true) ~= nil then
        return -16
    end
    if product == 'xiaomi smart band 10 pro'
        or product:find('xiaomi smart band 10 pro', 1, true) ~= nil then
        return -20
    end
    return 9
end

local function getScreenshotProfile()
    local skipRows = SCREEN_H
    local method = 'legacy'
    local name = 'legacy'
    local minRows = SCREEN_H
    local readRows = SCREEN_H
    local candidateSkipRows = nil

    if isXiaomiWatchS4() then
        return {
            name = 'xiaomi_watch_s4_bgr565',
            method = 'stream',
            width = 466,
            height = 466,
            strideBytes = 480 * 2,
            skipRows = 0,
            offsetBytes = 0,
            rawBytes = 480 * 2 * 466,
            readBytes = 480 * 2 * 466,
            readRows = 466,
            minRawBytes = 480 * 2 * 466,
            pixelFormat = 'bgr565le',
            pngConverter = 'o63',
            sourceBpp = 16,
            sourceVirtualWidth = 480,
            sourceVirtualHeight = 932,
            sourceFramebufferBytes = 480 * 2 * 932,
            readMode = 'rows',
            reopenRows = 4,
            candidateSkipRows = { 0, 466 },
            atomicPng = true
        }
    elseif isRedmiWatch6() then
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


local function isLuaExtensionMenuEnabled()
    local content = readFile(TARGET_DIR .. LUA_EXTENSION_SETTINGS_FILE)
    if not content or content == '' then return false end
    local data = jsonDecode(content)
    return type(data) == 'table' and data.enabled == true
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
        or containsXiaomiWatchS4(product) then
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
    if updateCpuFloatLayout then pcall(updateCpuFloatLayout) end
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


-- ====== CPU 悬浮监控 ======

function appendCpuMonitorLog(line)
    table.insert(cpuLogBuffer, 1, tostring(line or ''))
    while #cpuLogBuffer > CPU_MONITOR_LOG_LIMIT do
        table.remove(cpuLogBuffer)
    end
end

function readCpuLoad()
    local f = io.open('/proc/cpuload', 'r')
    if not f then return 'ERR:open', 0, nil end
    local content = f:read('*all')
    f:close()
    if not content or content == '' then return 'ERR:empty', 0, nil end

    local vals = {}
    for n in content:gmatch('[%d%.]+') do
        vals[#vals + 1] = n
    end
    if #vals == 0 then return 'NODATA', 0, content end

    local pct = 0
    if #vals == 1 then
        pct = math.floor(tonumber(vals[1]) or 0)
    elseif #vals >= 2 then
        local total = tonumber(vals[1]) or 0
        local used = tonumber(vals[2]) or 0
        if total > 0 then
            pct = math.floor(used / total * 100)
        end
    end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return string.format('CPU:%d%%', pct), pct, content
end

function writeCpuMonitorState()
    local logs = {}
    for i = 1, #cpuLogBuffer do
        logs[i] = cpuLogBuffer[i]
    end
    atomicWriteJson('cpu_monitor_state.json', {
        type = 'cpu_monitor_state',
        timestamp = tostring(os.time()),
        monitoring = cpuMonitorEnabled == true,
        floating = cpuFloatEnabled == true,
        percent = cpuLatestPercent,
        latest = cpuLatestText,
        logs = logs
    })
end

function updateCpuFloatLayout()
    if cpuFloatLayer then
        cpuFloatLayer:set { w = CPU_FLOAT_W, h = CPU_FLOAT_H }
    end
    if cpuFloatLabel then
        cpuFloatLabel:set { x = getCpuFloatLabelX(), w = CPU_FLOAT_W, h = CPU_FLOAT_H }
    end
end

function initCpuFloatLayer()
    if cpuFloatLayer and cpuFloatLabel then return true end
    local ok, disp = pcall(function() return lvgl.disp.get_default() end)
    if not ok or not disp then return false end

    cpuFloatLayer = lvgl.Object(disp:get_layer_top(), {
        x = 10,
        y = 0,
        w = CPU_FLOAT_W,
        h = CPU_FLOAT_H,
        bg_opa = lvgl.OPA(0),
        border_width = 0,
    })
    cpuFloatLayer:clear_flag(lvgl.FLAG.CLICKABLE)
    pcall(function() cpuFloatLayer:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    cpuFloatLayer:add_flag(lvgl.FLAG.HIDDEN)

    cpuFloatLabel = lvgl.Label(cpuFloatLayer, {
        x = getCpuFloatLabelX(),
        y = 0,
        w = CPU_FLOAT_W,
        h = CPU_FLOAT_H,
        text = cpuLatestText,
        font_size = 20,
        font = lvgl.BUILTIN_FONT.MONTSERRAT_24,
        text_color = '#00ff66',
        bg_opa = 0,
    })
    pcall(function() cpuFloatLabel:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    updateCpuFloatLayout()
    return true
end

function updateCpuFloatLabel()
    if cpuFloatLabel and cpuFloatEnabled then
        updateCpuFloatLayout()
        cpuFloatLabel:set { text = cpuLatestText }
    end
end

function collectCpuMonitorOnce()
    local text, pct, raw = readCpuLoad()
    cpuLatestText = text
    cpuLatestPercent = pct
    if not cpuFloatEnabled then
        appendCpuMonitorLog(string.format('[%s] %s', os.date('%H:%M:%S'), text))
        if not cpuRawLogged then
            cpuRawLogged = true
            local escaped = tostring(raw or 'nil'):gsub('\n', '\\n'):gsub('\r', '\\r')
            appendCpuMonitorLog('>>> RAW: [' .. escaped .. ']')
        end
    end
    updateCpuFloatLabel()
    writeCpuMonitorState()
end

function clearCpuMonitorLogByTimer()
    if not cpuMonitorEnabled then return end
    cpuLogBuffer = {}
    cpuRawLogged = false
    writeCpuMonitorState()
end

function startCpuMonitorLogCleaner()
    if cpuLogClearTimer then
        cpuLogClearTimer:resume()
        return
    end
    cpuLogClearTimer = lvgl.Timer({ period = CPU_MONITOR_LOG_CLEAR_MS, repeat_count = -1,
        cb = function() clearCpuMonitorLogByTimer() end })
    cpuLogClearTimer:resume()
end

function startCpuMonitor()
    if cpuMonitorEnabled then return '检测已开启' end
    cpuMonitorEnabled = true
    if not cpuMonitorTimer then
        cpuMonitorTimer = lvgl.Timer({ period = CPU_MONITOR_INTERVAL_MS, repeat_count = -1,
            cb = function()
                if cpuMonitorEnabled then collectCpuMonitorOnce() end
            end })
    end
    cpuMonitorTimer:resume()
    startCpuMonitorLogCleaner()
    appendCpuMonitorLog('>>> Monitoring Started (500ms interval)')
    collectCpuMonitorOnce()
    writeLuaEventLog('CPU检测', '开启检测', '周期: ' .. tostring(CPU_MONITOR_INTERVAL_MS) .. 'ms')
    return '检测已开启'
end

function stopCpuMonitor()
    if not cpuMonitorEnabled then return '检测已停止' end
    cpuMonitorEnabled = false
    if cpuMonitorTimer then
        pcall(function() cpuMonitorTimer:pause() end)
    end
    cpuLogBuffer = {}
    cpuRawLogged = false
    appendCpuMonitorLog('>>> Monitoring Stopped')
    writeCpuMonitorState()
    writeLuaEventLog('CPU检测', '关闭检测', '最后数值: ' .. tostring(cpuLatestText))
    return '检测已停止'
end

function clearCpuMonitorLog()
    cpuLogBuffer = {}
    cpuRawLogged = false
    cpuLatestPercent = 0
    cpuLatestText = 'CPU:0%'
    updateCpuFloatLabel()
    writeCpuMonitorState()
    return '日志已清空'
end

function showCpuFloatLayer()
    if not initCpuFloatLayer() then
        writeCpuMonitorState()
        return '悬浮层创建失败'
    end
    local changed = not cpuFloatEnabled
    cpuFloatEnabled = true
    cpuFloatLayer:clear_flag(lvgl.FLAG.HIDDEN)
    cpuLogBuffer = {}
    cpuRawLogged = false
    updateCpuFloatLabel()
    writeCpuMonitorState()
    if changed then
        writeLuaEventLog('CPU悬浮', '开启悬浮', '当前数值: ' .. tostring(cpuLatestText))
    end
    return '悬浮已开启'
end

function hideCpuFloatLayer()
    local changed = cpuFloatEnabled == true
    cpuFloatEnabled = false
    if cpuFloatLayer then cpuFloatLayer:add_flag(lvgl.FLAG.HIDDEN) end
    writeCpuMonitorState()
    if changed then
        writeLuaEventLog('CPU悬浮', '关闭悬浮', '当前数值: ' .. tostring(cpuLatestText))
    end
    return '悬浮已关闭'
end

function executeCpuMonitorAction(action)
    if action == 'monitor_start' then return startCpuMonitor() end
    if action == 'monitor_stop' then return stopCpuMonitor() end
    if action == 'clear' then return clearCpuMonitorLog() end
    if action == 'float_on' then return showCpuFloatLayer() end
    if action == 'float_off' then return hideCpuFloatLayer() end
    if action == 'status' then writeCpuMonitorState(); return '状态已刷新' end
    return '未知 CPU 操作'
end


-- ====== 内存悬浮监控 ======

function appendMemoryMonitorLog(line)
    table.insert(memoryLogBuffer, 1, tostring(line or ''))
    while #memoryLogBuffer > MEMORY_MONITOR_LOG_LIMIT do
        table.remove(memoryLogBuffer)
    end
end

function formatMemoryKb(kb)
    kb = tonumber(kb) or 0
    if kb >= 1024 then
        return string.format('%.1fMB', kb / 1024)
    end
    return tostring(math.floor(kb)) .. 'KB'
end

function parseMemoryInfoFallback(content)
    if not content or content == '' then return nil end
    local previousNumeric = nil
    local currentNumeric = nil
    for line in content:gmatch('[^\r\n]+') do
        local nums = {}
        for n in line:gmatch('%d+') do
            nums[#nums + 1] = tonumber(n) or 0
        end
        local compact = line:gsub('%s+', '')
        if compact == 'Umem' and previousNumeric and #previousNumeric >= 3 then
            return previousNumeric[1], previousNumeric[2], previousNumeric[3]
        end
        if #nums >= 3 and not string.find(line, '[%a_]') then
            previousNumeric = currentNumeric
            currentNumeric = nums
        end
    end
    local total, used, free = content:match('[%a_]*[Mm]em:%s*(%d+)%s+(%d+)%s+(%d+)')
    if total then
        return tonumber(total) or 0, tonumber(used) or 0, tonumber(free) or 0
    end
    total, used, free = content:match('[%a_]*[Hh]eap:%s*(%d+)%s+(%d+)%s+(%d+)')
    if total then
        return tonumber(total) or 0, tonumber(used) or 0, tonumber(free) or 0
    end
    total = content:match('[Tt]otal[^%d]*(%d+)')
    used = content:match('[Uu]sed[^%d]*(%d+)')
    free = content:match('[Ff]ree[^%d]*(%d+)')
    if total then
        total = tonumber(total) or 0
        used = tonumber(used) or 0
        free = tonumber(free) or 0
        if used <= 0 and free > 0 then used = total - free end
        return total, used, free
    end
    return nil
end

function normalizeRealtimeMemoryKb(total, used, free, available)
    total = tonumber(total) or 0
    used = tonumber(used) or 0
    free = tonumber(free) or 0
    available = tonumber(available) or 0
    if total > 1024 * 1024 or used > 1024 * 1024 or free > 1024 * 1024 or available > 1024 * 1024 then
        total = math.floor(total / 1024)
        used = math.floor(used / 1024)
        free = math.floor(free / 1024)
        available = math.floor(available / 1024)
    end
    return total, used, free, available
end

function findThreeConsecutiveNumbers(content, minFirst)
    minFirst = minFirst or 100
    local nums = {}
    for n in content:gmatch('%d+') do
        nums[#nums + 1] = tonumber(n)
    end
    for i = 1, #nums - 2 do
        local a, b, c = nums[i], nums[i + 1], nums[i + 2]
        if a >= minFirst and b <= a and c <= a then return a, b, c end
    end
    return nil
end

function parseNuttXMemoryInfo(content)
    if not content or content == '' then return nil end

    for line in content:gmatch('[^\r\n]+') do
        if line:find('Umem') then
            local nums = {}
            for n in line:gmatch('(%d+)') do nums[#nums + 1] = tonumber(n) end
            if #nums >= 3 then return nums[1], nums[2], nums[3] end
        end
    end

    for line in content:gmatch('[^\r\n]+') do
        local t, u, f = line:match('Umem:%s*(%d+)%s+(%d+)%s+(%d+)')
        if t then return tonumber(t), tonumber(u), tonumber(f) end
        t, u, f = line:match('[Mm]em[Tt]otal:%s*(%d+).*[Mm]em[Ff]ree:%s*(%d+)')
        if t then
            local tv = tonumber(t)
            local fv = tonumber(f)
            if tv and fv then return tv, tv - fv, fv end
        end
    end

    local nums = {}
    for n in content:gmatch('%d+') do nums[#nums + 1] = tonumber(n) end
    for i = 1, #nums - 2 do
        local a, b, c = nums[i], nums[i + 1], nums[i + 2]
        if a >= 1000 and b <= a and c <= a then return a, b, c end
    end
    if #nums >= 1 and nums[1] > 1000 then
        return nums[1], 0, 0
    end

    return nil
end

function readMemoryInfo()
    local luaKb = 0
    local okGc, gcKb = pcall(function() return collectgarbage('count') end)
    if okGc and gcKb then luaKb = math.floor(tonumber(gcKb) or 0) end

    local naStats = { totalKb = 0, usedKb = 0, availableKb = 0, freeKb = 0, luaKb = luaKb }

    local f = io.open('/proc/meminfo', 'r')
    if not f then
        naStats.source = 'proc_meminfo_open_failed'
        return 'MEM:N/A', 0, 'open /proc/meminfo failed', naStats
    end
    local content = f:read('*all')
    f:close()
    if not content or content == '' then
        naStats.source = 'proc_meminfo_empty'
        return 'MEM:N/A', 0, 'empty /proc/meminfo', naStats
    end

    local stats = {}
    for key, value in content:gmatch('([%w_]+):%s*(%d+)') do
        stats[key] = tonumber(value) or 0
    end

    local total = stats.MemTotal or stats.MemTotalKB or stats.Total or 0
    local free = stats.MemFree or stats.Free or 0
    local available = stats.MemAvailable or stats.Available or 0

    local nuttxTotal, nuttxUsed, nuttxFree = parseNuttXMemoryInfo(content)
    if total <= 0 and nuttxTotal then
        total = nuttxTotal
        free = nuttxFree or 0
        available = free
    end

    if total <= 0 then
        naStats.source = 'proc_meminfo_parse_failed'
        return 'MEM:N/A', 0, content, naStats
    end

    local unitIsKb = content:find('[Kk][Bb]') ~= nil
    local div = unitIsKb and 1 or 1024
    if div > 1 then
        total = math.floor(total / div)
        free = math.floor(free / div)
        available = math.floor(available / div)
    end
    if nuttxUsed and nuttxUsed > 0 and div > 1 then
        nuttxUsed = math.floor(nuttxUsed / div)
        nuttxFree = math.floor((nuttxFree or 0) / div)
    end

    local buffersKb = math.floor((stats.Buffers or 0) / div)
    local cachedKb = math.floor((stats.Cached or 0) / div)

    if available <= 0 then
        available = free + buffersKb + cachedKb
    end

    local used = 0
    if nuttxUsed and nuttxUsed > 0 then
        used = nuttxUsed
    elseif total > 0 and available > 0 then
        used = total - available
    elseif total > 0 and free > 0 then
        used = total - free
    elseif total > 0 and buffersKb + cachedKb > 0 then
        used = total - buffersKb - cachedKb
    elseif total > 0 then
        used = total
    end

    if used < 0 then used = 0 end
    if total > 0 and used > total then used = total end

    local pct = 0
    if total > 0 then pct = math.floor(used * 100 / total) end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end

    return string.format('MEM:%d%%', pct), pct, content, {
        totalKb = total,
        usedKb = used,
        availableKb = available,
        freeKb = free,
        luaKb = luaKb
    }
end

function writeMemoryMonitorState()
    local logs = {}
    for i = 1, #memoryLogBuffer do
        logs[i] = memoryLogBuffer[i]
    end
    atomicWriteJson('memory_monitor_state.json', {
        type = 'memory_monitor_state',
        timestamp = tostring(os.time()),
        monitoring = memoryMonitorEnabled == true,
        floating = memoryFloatEnabled == true,
        percent = memoryLatestPercent,
        latest = memoryLatestText,
        totalKb = memoryTotalKb,
        usedKb = memoryUsedKb,
        availableKb = memoryAvailableKb,
        freeKb = memoryFreeKb,
        luaKb = memoryLuaKb,
        totalText = formatMemoryKb(memoryTotalKb),
        usedText = formatMemoryKb(memoryUsedKb),
        availableText = formatMemoryKb(memoryAvailableKb),
        freeText = formatMemoryKb(memoryFreeKb),
        luaText = formatMemoryKb(memoryLuaKb),
        logs = logs
    })
end

function updateMemoryFloatLayout()
    if memoryFloatLayer then
        memoryFloatLayer:set { w = MEMORY_FLOAT_W, h = MEMORY_FLOAT_H, y = MEMORY_FLOAT_Y }
    end
    if memoryFloatLabel then
        memoryFloatLabel:set { x = getCpuFloatLabelX(), w = MEMORY_FLOAT_W, h = MEMORY_FLOAT_H }
    end
end

function initMemoryFloatLayer()
    if memoryFloatLayer and memoryFloatLabel then return true end
    local ok, disp = pcall(function() return lvgl.disp.get_default() end)
    if not ok or not disp then return false end

    memoryFloatLayer = lvgl.Object(disp:get_layer_top(), {
        x = 10,
        y = MEMORY_FLOAT_Y,
        w = MEMORY_FLOAT_W,
        h = MEMORY_FLOAT_H,
        bg_opa = lvgl.OPA(0),
        border_width = 0,
    })
    memoryFloatLayer:clear_flag(lvgl.FLAG.CLICKABLE)
    pcall(function() memoryFloatLayer:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    memoryFloatLayer:add_flag(lvgl.FLAG.HIDDEN)

    memoryFloatLabel = lvgl.Label(memoryFloatLayer, {
        x = getCpuFloatLabelX(),
        y = 0,
        w = MEMORY_FLOAT_W,
        h = MEMORY_FLOAT_H,
        text = memoryLatestText,
        font_size = 20,
        font = lvgl.BUILTIN_FONT.MONTSERRAT_24,
        text_color = '#66ccff',
        bg_opa = 0,
    })
    pcall(function() memoryFloatLabel:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    updateMemoryFloatLayout()
    return true
end

function updateMemoryFloatLabel()
    writeMemoryMonitorState()
    if memoryFloatLabel and memoryFloatEnabled then
        updateMemoryFloatLayout()
        memoryFloatLabel:set { text = memoryLatestText }
    end
end

function collectMemoryMonitorOnce()
    local text, pct, raw, stats = readMemoryInfo()
    stats = stats or {}
    memoryLatestPercent = pct
    memoryTotalKb = stats.totalKb or 0
    memoryUsedKb = stats.usedKb or 0
    memoryAvailableKb = stats.availableKb or 0
    memoryFreeKb = stats.freeKb or 0
    memoryLuaKb = stats.luaKb or 0
    memoryLatestText = formatMemoryKb(memoryUsedKb) .. '/' .. formatMemoryKb(memoryTotalKb) .. ' ' .. pct .. '%'
    if not memoryFloatEnabled then
        appendMemoryMonitorLog(string.format('[%s] %s/%s %d%%', os.date('%H:%M:%S'), formatMemoryKb(memoryUsedKb), formatMemoryKb(memoryTotalKb), pct))
        if not memoryRawLogged then
            memoryRawLogged = true
            local escaped = tostring(raw or 'nil'):gsub('\n', '\\n'):gsub('\r', '\\r')
            appendMemoryMonitorLog('>>> RAW: [' .. escaped .. ']')
        end
    end
    updateMemoryFloatLabel()
    writeMemoryMonitorState()
    writeMemoryMonitorState()
end

function clearMemoryMonitorLogByTimer()
    if not memoryMonitorEnabled then return end
    memoryLogBuffer = {}
    memoryRawLogged = false
    writeMemoryMonitorState()
end

function startMemoryMonitorLogCleaner()
    if memoryLogClearTimer then
        memoryLogClearTimer:resume()
        return
    end
    memoryLogClearTimer = lvgl.Timer({ period = MEMORY_MONITOR_LOG_CLEAR_MS, repeat_count = -1,
        cb = function() clearMemoryMonitorLogByTimer() end })
    memoryLogClearTimer:resume()
end

function startMemoryMonitor()
    if memoryMonitorEnabled then return '检测已开启' end
    memoryMonitorEnabled = true
    if not memoryMonitorTimer then
        memoryMonitorTimer = lvgl.Timer({ period = MEMORY_MONITOR_INTERVAL_MS, repeat_count = -1,
            cb = function()
                if memoryMonitorEnabled then collectMemoryMonitorOnce() end
            end })
    end
    memoryMonitorTimer:resume()
    startMemoryMonitorLogCleaner()
    appendMemoryMonitorLog('>>> Monitoring Started (800ms interval)')
    collectMemoryMonitorOnce()
    writeLuaEventLog('内存检测', '开启检测', '周期: ' .. tostring(MEMORY_MONITOR_INTERVAL_MS) .. 'ms')
    return '检测已开启'
end

function stopMemoryMonitor()
    if not memoryMonitorEnabled then return '检测已停止' end
    memoryMonitorEnabled = false
    if memoryMonitorTimer then
        pcall(function() memoryMonitorTimer:pause() end)
    end
    memoryLogBuffer = {}
    memoryRawLogged = false
    memoryLatestText = 'MEM:0%'
    memoryLatestPercent = 0
    pcall(os.remove, TARGET_DIR .. 'memory_monitor_state.json')
    pcall(os.remove, TARGET_DIR .. 'memory_monitor_result.json')
    writeLuaEventLog('内存检测', '关闭检测', '最后数值: ' .. tostring(memoryLatestText))
    return '检测已停止'
end

function clearMemoryMonitorLog()
    memoryLogBuffer = {}
    memoryRawLogged = false
    memoryLatestText = 'MEM:0%'
    memoryLatestPercent = 0
    updateMemoryFloatLabel()
    writeMemoryMonitorState()
    pcall(os.remove, TARGET_DIR .. 'memory_monitor_state.json')
    pcall(os.remove, TARGET_DIR .. 'memory_monitor_result.json')
    return '日志已清空'
end

function showMemoryFloatLayer()
    if not initMemoryFloatLayer() then
        pcall(os.remove, TARGET_DIR .. 'memory_monitor_state.json')
        return '悬浮层创建失败'
    end
    local changed = not memoryFloatEnabled
    memoryFloatEnabled = true
    memoryFloatLayer:clear_flag(lvgl.FLAG.HIDDEN)
    memoryLogBuffer = {}
    memoryRawLogged = false
    updateMemoryFloatLabel()
    writeMemoryMonitorState()
    if changed then
        writeLuaEventLog('内存悬浮', '开启悬浮', '当前数值: ' .. tostring(memoryLatestText))
    end
    return '悬浮已开启'
end

function hideMemoryFloatLayer()
    local changed = memoryFloatEnabled == true
    memoryFloatEnabled = false
    if memoryFloatLayer then memoryFloatLayer:add_flag(lvgl.FLAG.HIDDEN) end
    if changed then
        writeLuaEventLog('内存悬浮', '关闭悬浮', '当前数值: ' .. tostring(memoryLatestText))
    writeMemoryMonitorState()
    end
    return '悬浮已关闭'
end

function executeMemoryMonitorAction(action)
    if action == 'monitor_start' then return startMemoryMonitor() end
    if action == 'monitor_stop' then return stopMemoryMonitor() end
    if action == 'clear' then return clearMemoryMonitorLog() end
    if action == 'float_on' then return showMemoryFloatLayer() end
    if action == 'float_off' then return hideMemoryFloatLayer() end
    if action == 'status' then
        if memoryMonitorEnabled then writeMemoryMonitorState() end
        return '状态已刷新'
    end
    return '未知内存操作'
end

function writeScreenshotFloatState()
    atomicWriteJson('screenshot_float_state.json', {
        type = 'screenshot_float_state',
        timestamp = tostring(os.time()),
        floating = screenshotFloatEnabled == true
    })
end

function updateScreenshotFloatLayout()
    if screenshotFloatLayer then
        screenshotFloatLayer:set { w = SCREENSHOT_FLOAT_W, h = SCREENSHOT_FLOAT_H, y = SCREENSHOT_FLOAT_Y }
    end
    if screenshotFloatLabel then
        screenshotFloatLabel:set { x = getCpuFloatLabelX(), w = SCREENSHOT_FLOAT_W, h = SCREENSHOT_FLOAT_H }
    end
end

function initScreenshotFloatLayer()
    if screenshotFloatLayer and screenshotFloatLabel then return true end
    local ok, disp = pcall(function() return lvgl.disp.get_default() end)
    if not ok or not disp then return false end

    screenshotFloatLayer = lvgl.Object(disp:get_layer_top(), {
        x = 10,
        y = SCREENSHOT_FLOAT_Y,
        w = SCREENSHOT_FLOAT_W,
        h = SCREENSHOT_FLOAT_H,
        bg_opa = lvgl.OPA(0),
        border_width = 0,
    })
    screenshotFloatLayer:add_flag(lvgl.FLAG.CLICKABLE)
    pcall(function() screenshotFloatLayer:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    screenshotFloatLayer:add_flag(lvgl.FLAG.HIDDEN)

    screenshotFloatLabel = lvgl.Label(screenshotFloatLayer, {
        x = getCpuFloatLabelX(),
        y = 0,
        w = SCREENSHOT_FLOAT_W,
        h = SCREENSHOT_FLOAT_H,
        text = 'SHOT',
        font_size = 20,
        font = lvgl.BUILTIN_FONT.MONTSERRAT_24,
        text_color = UI_PRIMARY,
        bg_opa = 0,
    })
    screenshotFloatLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    pcall(function() screenshotFloatLabel:add_flag(lvgl.FLAG.OVERFLOW_VISIBLE) end)
    screenshotFloatLayer:onevent(lvgl.EVENT.CLICKED, function() captureScreenshotFromFloat() end)
    updateScreenshotFloatLayout()
    return true
end

function showScreenshotFloatLayer()
    if not initScreenshotFloatLayer() then
        writeScreenshotFloatState()
        return '悬浮层创建失败'
    end
    local changed = not screenshotFloatEnabled
    screenshotFloatEnabled = true
    screenshotFloatLayer:clear_flag(lvgl.FLAG.HIDDEN)
    updateScreenshotFloatLayout()
    writeScreenshotFloatState()
    if changed then
        writeLuaEventLog('截图悬浮', '开启悬浮', '点击悬浮文字可立即截图')
    end
    return '悬浮已开启'
end

function hideScreenshotFloatLayer()
    local changed = screenshotFloatEnabled == true
    screenshotFloatEnabled = false
    if screenshotFloatCaptureTimer then
        pcall(function() screenshotFloatCaptureTimer:delete() end)
        screenshotFloatCaptureTimer = nil
        if busyMode == 'screenshot' then
            cmdBusy = false
            busyMode = ''
            writeBridgeState(false, '', '')
        end
    end
    if screenshotFloatLayer then screenshotFloatLayer:add_flag(lvgl.FLAG.HIDDEN) end
    writeScreenshotFloatState()
    if changed then
        writeLuaEventLog('截图悬浮', '关闭悬浮', '截图悬浮按钮已隐藏')
    end
    return '悬浮已关闭'
end

function executeScreenshotFloatAction(action)
    if action == 'float_on' then return showScreenshotFloatLayer() end
    if action == 'float_off' then return hideScreenshotFloatLayer() end
    if action == 'status' then writeScreenshotFloatState(); return '状态已刷新' end
    return '未知截图悬浮操作'
end


-- ====== 应用/缓存管理 IPC ======

CACHE_CLEAN_PATHS = {
    '/data/persist.db.bk',
    '/data/app/notifications/icon/',
    '/data/app/notifications/small/',
    '/data/mass/tmp/watchface/',
    '/data/mass/tmp/ota/',
    '/data/mass/tmp/res/',
    '/data/mass/tmp/app/',
    '/data/quickapp/cache',
    '/data/quickapp/tmp',
    '/data/offlinelog/',
    '/data/power_event/',
    '/data/usage_stats/',
    '/data/app/cache',
    '/data/cache/',
    '/data/log/',
    '/data/tmp/',
}

function cachePathDisplayName(path)
    local name = tostring(path or '')
    name = name:gsub('/+$', '')
    local idx = name:match('^.*()/')
    if idx then name = name:sub(idx + 1) end
    if name == '' then name = tostring(path or '') end
    return name
end

function formatCacheSize(size)
    size = tonumber(size) or 0
    if size >= 1024 * 1024 then
        return string.format('%.2f MB', size / 1024 / 1024)
    end
    if size >= 1024 then
        return string.format('%.1f KB', size / 1024)
    end
    return tostring(size) .. ' B'
end

function cacheFileSize(path)
    return fileSize(path)
end

function cacheFolderSize(path)
    if not path or path == '' then return 0 end
    local dir = nil
    local ok, opened = pcall(function() return lvgl.fs.open_dir(path) end)
    if not ok or not opened then
        return cacheFileSize(path)
    end
    dir = opened
    local size = 0
    local prefix = path
    if string.sub(prefix, -1) ~= '/' then prefix = prefix .. '/' end
    while true do
        local readOk, entry = pcall(dir.read, dir)
        if not readOk or not entry then break end
        local isDir = string.byte(entry, 1) == string.byte('/', 1)
        local cleanName = isDir and string.sub(entry, 2) or entry
        if cleanName ~= '' and cleanName ~= '.' and cleanName ~= '..' then
            local fullPath = prefix .. cleanName
            if isDir then
                size = size + cacheFolderSize(fullPath)
            else
                size = size + cacheFileSize(fullPath)
            end
        end
    end
    pcall(dir.close, dir)
    return size
end

function cachePathExists(path)
    if fileExists(path) then return true end
    return dirExists(path)
end

function deleteCachePath(path)
    if not cachePathExists(path) then return true end
    local safe = false
    for i = 1, #CACHE_CLEAN_PATHS do
        if path == CACHE_CLEAN_PATHS[i] then safe = true; break end
    end
    if not safe then return false end
    if tostring(path):find('[;&|`$<>]') then return false end

    local okDir, dir = pcall(function() return lvgl.fs.open_dir(path) end)
    local cmd = nil
    if okDir and dir then
        cmd = 'rm -r "' .. tostring(path):gsub('"', '\"') .. '"'
        pcall(dir.close, dir)
    elseif fileExists(path) then
        cmd = 'rm "' .. tostring(path):gsub('"', '\"') .. '"'
    end
    if not cmd then return true end
    local ok = pcall(os.execute, cmd)
    return ok == true
end

function deleteMassRootLooseFiles()
    local folderPath = '/data/mass/'
    local ok, dir = pcall(function() return lvgl.fs.open_dir(folderPath) end)
    if not ok or not dir then return end
    while true do
        local readOk, entry = pcall(dir.read, dir)
        if not readOk or not entry then break end
        local isDir = string.byte(entry, 1) == string.byte('/', 1)
        if not isDir then
            pcall(os.remove, folderPath .. entry)
        end
    end
    pcall(dir.close, dir)
end

function buildCacheItems()
    local items = {}
    local total = 0
    for i = 1, #CACHE_CLEAN_PATHS do
        local path = CACHE_CLEAN_PATHS[i]
        local size = cacheFolderSize(path)
        total = total + size
        items[#items + 1] = {
            path = path,
            name = cachePathDisplayName(path),
            sizeBytes = size,
            size = formatCacheSize(size),
            exists = cachePathExists(path)
        }
    end
    return items, total
end

function usesFlatQuickAppRoot()
    local product = tostring(activeDeviceProduct or '')
    return product == 'Xiaomi Smart Band 10 Pro'
        or string.find(product, 'Xiaomi Watch S5', 1, true) ~= nil
end

function getQuickAppRoot()
    if usesFlatQuickAppRoot() then
        return '/data/'
    end
    if fileExists('/data/quickapp/apps.json') or dirExists('/data/quickapp') then
        return '/data/quickapp/'
    end
    return '/data/'
end

function getAppManagerPaths()
    local rootPath = getQuickAppRoot()
    local systemDir = '/data/quickapp/system/'
    if rootPath == '/data/quickapp/' then
        systemDir = rootPath .. 'system/'
    end
    return {
        root = rootPath,
        visibleJson = rootPath .. 'apps.json',
        hiddenJson = rootPath .. 'apps.json_hide',
        appDir = rootPath .. 'app/',
        systemDir = systemDir,
        dirs = {
            rootPath .. 'app/',
            systemDir,
            rootPath .. 'cache/',
            rootPath .. 'files/',
            rootPath .. 'mass/'
        }
    }
end

function normalizeAppsJson(obj)
    if type(obj) ~= 'table' then obj = {} end
    if type(obj.InstalledApps) ~= 'table' then obj.InstalledApps = {} end
    return obj
end

function loadAppsJson(path)
    local text = readFile(path)
    if not text or text == '' then
        return { InstalledApps = {} }
    end
    return normalizeAppsJson(jsonDecode(text))
end

function saveAppsJson(path, obj)
    obj = normalizeAppsJson(obj)
    return writeFile(path, jsonEncode(obj))
end

function cloneAppInfo(app)
    local out = {}
    if type(app) == 'table' then
        for k, v in pairs(app) do out[k] = v end
    end
    return out
end

function packageIsShellPlusPlus(packageName)
    return tostring(packageName or '') == 'com.shell.liangyi'
end

function appDisplayName(app)
    return tostring(app.name or app.appName or app.label or app.title or app.package or '')
end

function appPackage(app)
    return tostring(app and app.package or '')
end

function managedAppIconCacheDir()
    return TARGET_DIR .. 'app_icons/'
end

function clearManagedAppIconCache()
    local cacheDir = managedAppIconCacheDir()
    pcall(os.execute, 'rm -rf "' .. cacheDir .. '"')
    pcall(os.execute, 'mkdir -p "' .. cacheDir .. '"')
    return dirExists(cacheDir)
end

function copyManagedAppIcon(packageName, sourcePath)
    if not sourcePath or not fileExists(sourcePath) then return '' end
    local safePackage = tostring(packageName or ''):gsub('[^%w%._%-]', '_')
    if safePackage == '' then return '' end
    local extension = tostring(sourcePath):match('%.([%w]+)$')
    if not extension then return '' end
    extension = string.lower(extension)
    if extension ~= 'png' and extension ~= 'jpg' and extension ~= 'jpeg' and extension ~= 'bmp' then
        return ''
    end
    local filename = safePackage .. '.' .. extension
    local cacheDir = managedAppIconCacheDir()
    local targetPath = cacheDir .. filename
    if fileExists(targetPath) then
        return 'internal://files/app_icons/' .. filename
    end
    mkdir(cacheDir)
    local input = io.open(sourcePath, 'rb')
    if not input then return '' end
    local output = io.open(targetPath, 'wb')
    if not output then input:close(); return '' end
    local ok = true
    while true do
        local chunk = input:read(4096)
        if not chunk or chunk == '' then break end
        local wrote = output:write(chunk)
        if not wrote then ok = false; break end
    end
    input:close()
    output:close()
    if not ok then
        os.remove(targetPath)
        return ''
    end
    return 'internal://files/app_icons/' .. filename
end

function appendManagedApp(list, seen, app, hidden, appDir)
    local packageName = appPackage(app)
    if packageName == '' or seen[packageName] then return end
    seen[packageName] = true
    local item = cloneAppInfo(app)
    item.package = packageName
    item.name = appDisplayName(item)
    item.hidden = hidden == true
    item.hideFlag = hidden == true and true or nil
    item.locked = packageIsShellPlusPlus(packageName)
    if appDir and item.icon then
        local sourceIconPath = appDir .. packageName .. '/' .. item.icon
        local quickIconPath = copyManagedAppIcon(packageName, sourceIconPath)
        if quickIconPath ~= '' then item.iconPath = quickIconPath end
    end
    list[#list + 1] = item
end

function buildManagedApps()
    local paths = getAppManagerPaths()
    local visible = loadAppsJson(paths.visibleJson)
    local hidden = loadAppsJson(paths.hiddenJson)
    local apps = {}
    local seen = {}
    for i = 1, #visible.InstalledApps do
        appendManagedApp(apps, seen, visible.InstalledApps[i], false, paths.appDir)
    end
    for i = 1, #hidden.InstalledApps do
        appendManagedApp(apps, seen, hidden.InstalledApps[i], true, paths.appDir)
    end
    table.sort(apps, function(a, b) return tostring(a.name or a.package) < tostring(b.name or b.package) end)
    return apps, paths
end

function selectedPackageSet(req, apps)
    local set = {}
    if req.all == true then
        for i = 1, #apps do
            if not apps[i].locked then set[apps[i].package] = true end
        end
        return set
    end
    if type(req.packages) == 'table' then
        for i = 1, #req.packages do
            local packageName = tostring(req.packages[i] or '')
            if packageName ~= '' and not packageIsShellPlusPlus(packageName) then
                set[packageName] = true
            end
        end
    end
    return set
end

function setHasAny(set)
    for _ in pairs(set) do return true end
    return false
end

function moveAppBetweenLists(src, dst, packageSet, makeHidden)
    local moved = 0
    local i = 1
    while i <= #src.InstalledApps do
        local app = src.InstalledApps[i]
        local packageName = appPackage(app)
        if packageSet[packageName] and not packageIsShellPlusPlus(packageName) then
            local item = cloneAppInfo(app)
            if makeHidden then item.hideFlag = true else item.hideFlag = nil end
            table.remove(src.InstalledApps, i)
            dst.InstalledApps[#dst.InstalledApps + 1] = item
            moved = moved + 1
        else
            i = i + 1
        end
    end
    return moved
end

function removeAppsFromList(obj, packageSet)
    local removed = 0
    local i = 1
    while i <= #obj.InstalledApps do
        local packageName = appPackage(obj.InstalledApps[i])
        if packageSet[packageName] and not packageIsShellPlusPlus(packageName) then
            table.remove(obj.InstalledApps, i)
            removed = removed + 1
        else
            i = i + 1
        end
    end
    return removed
end

function safeDeleteAppPackageDir(baseDir, packageName)
    packageName = tostring(packageName or '')
    if packageName == '' or packageIsShellPlusPlus(packageName) then return false end
    if packageName:find('[;&|`$<>/\\]') or packageName:find('%.%.', 1, true) then return false end
    local path = tostring(baseDir or '') .. packageName .. '/'
    local ok, dir = pcall(function() return lvgl.fs.open_dir(path) end)
    if ok and dir then
        pcall(dir.close, dir)
        return pcall(os.execute, 'rm -r "' .. path:gsub('"', '\"') .. '"')
    end
    return true
end

function deleteManagedAppFiles(paths, packageSet)
    local deleted = 0
    for packageName in pairs(packageSet) do
        if not packageIsShellPlusPlus(packageName) then
            for i = 1, #paths.dirs do
                if safeDeleteAppPackageDir(paths.dirs[i], packageName) then deleted = deleted + 1 end
            end
        end
    end
    return deleted
end

function appManagerListResult(action)
    local apps, paths = buildManagedApps()
    return {
        status = 'ok',
        action = action or 'apps',
        message = '读取完成',
        root = paths.root,
        apps = apps
    }
end

function appManagerSetVisible(req)
    local apps, paths = buildManagedApps()
    local packageSet = selectedPackageSet(req, apps)
    if not setHasAny(packageSet) then
        return { status = 'error', action = req.action, message = '没有可操作的快应用', apps = apps }
    end
    local visible = loadAppsJson(paths.visibleJson)
    local hidden = loadAppsJson(paths.hiddenJson)
    local moved = 0
    if req.visible == false or req.operation == 'hide' then
        moved = moveAppBetweenLists(visible, hidden, packageSet, true)
    else
        moved = moveAppBetweenLists(hidden, visible, packageSet, false)
    end
    saveAppsJson(paths.visibleJson, visible)
    saveAppsJson(paths.hiddenJson, hidden)
    local nextApps = buildManagedApps()
    return {
        status = 'ok',
        action = req.action,
        message = moved > 0 and ('已处理 ' .. tostring(moved) .. ' 个，重启后生效') or '没有需要变更的快应用',
        changed = moved,
        apps = nextApps
    }
end

function appManagerDelete(req)
    local apps, paths = buildManagedApps()
    local packageSet = selectedPackageSet(req, apps)
    if not setHasAny(packageSet) then
        return { status = 'error', action = req.action, message = '没有可删除的快应用', apps = apps }
    end
    local visible = loadAppsJson(paths.visibleJson)
    local hidden = loadAppsJson(paths.hiddenJson)
    local removed = removeAppsFromList(visible, packageSet) + removeAppsFromList(hidden, packageSet)
    saveAppsJson(paths.visibleJson, visible)
    saveAppsJson(paths.hiddenJson, hidden)
    deleteManagedAppFiles(paths, packageSet)
    local nextApps = buildManagedApps()
    return {
        status = 'ok',
        action = req.action,
        message = removed > 0 and ('已删除 ' .. tostring(removed) .. ' 个，建议重启') or '没有找到要删除的快应用',
        changed = removed,
        apps = nextApps
    }
end

function getSingleAppSize(packageName)
    local paths = getAppManagerPaths()
    local total = 0
    for i = 1, #paths.dirs do
        local p = paths.dirs[i] .. packageName .. '/'
        local ok, dir = pcall(function() return lvgl.fs.open_dir(p) end)
        if ok and dir then
            pcall(dir.close, dir)
            local sz = cacheFolderSize(p)
            total = total + (sz or 0)
        end
    end
    return total
end

function formatAppSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return string.format('%.1fMB', bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format('%.1fKB', bytes / 1024)
    end
    return tostring(bytes) .. 'B'
end

function appManagerAppSize(req)
    local packageName = tostring(req and req.package or '')
    if packageName == '' then
        return { status = 'error', action = 'app_size', message = '缺少 package 参数' }
    end
    local bytes = getSingleAppSize(packageName)
    return {
        status = 'ok',
        action = 'app_size',
        package = packageName,
        bytes = bytes,
        size = formatAppSize(bytes)
    }
end

function appManagerReboot(req)
    local ok = pcall(os.execute, 'reboot')
    return {
        status = ok and 'ok' or 'error',
        action = req and req.action or 'reboot_system',
        message = ok and '正在重启系统' or '重启命令执行失败'
    }
end

function executeAppManagerRequest(req)
    local action = req and req.action or ''
    if action == 'cache_status' then
        local items, total = buildCacheItems()
        return {
            status = 'ok',
            action = action,
            message = '统计完成',
            totalBytes = total,
            totalSize = formatCacheSize(total),
            items = items
        }
    end
    if action == 'cache_clear' then
        local beforeItems, beforeTotal = buildCacheItems()
        for i = 1, #CACHE_CLEAN_PATHS do
            deleteCachePath(CACHE_CLEAN_PATHS[i])
        end
        -- RW6 将本地音乐直接存放在 /data/mass/ 根目录，不能按缓存删除。
        if not isRedmiWatch6() then
            deleteMassRootLooseFiles()
        end
        pcall(collectgarbage, 'collect')
        local afterItems, afterTotal = buildCacheItems()
        local freed = beforeTotal - afterTotal
        if freed < 0 then freed = 0 end
        return {
            status = 'ok',
            action = action,
            message = '清理完成',
            beforeBytes = beforeTotal,
            beforeSize = formatCacheSize(beforeTotal),
            totalBytes = afterTotal,
            totalSize = formatCacheSize(afterTotal),
            freedBytes = freed,
            freedSize = formatCacheSize(freed),
            beforeItems = beforeItems,
            items = afterItems
        }
    end
    if action == 'apps' then return appManagerListResult(action) end
    if action == 'icon_cache_reset' then
        local ok = clearManagedAppIconCache()
        return {
            status = ok and 'ok' or 'error',
            action = action,
            message = ok and '图标缓存已清理' or '图标缓存清理失败'
        }
    end
    if action == 'set_visible' then return appManagerSetVisible(req) end
    if action == 'delete' then return appManagerDelete(req) end
    if action == 'app_size' then return appManagerAppSize(req) end
    if action == 'reboot_system' then return appManagerReboot(req) end
    return { status = 'error', action = action, message = '未知应用管理操作' }
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
        'file_transfer_request.json', 'file_transfer_result.json', 'file_transfer/',
        'app_manager_request.json', 'app_manager_result.json',
        'cpu_monitor_request.json', 'cpu_monitor_result.json', 'cpu_monitor_state.json',
        'memory_monitor_request.json', 'memory_monitor_result.json', 'memory_monitor_state.json',
        'screenshot_float_request.json', 'screenshot_float_result.json', 'screenshot_float_state.json',
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

local function isNoIpcDebugEnabled()
    local content = readFile(TARGET_DIR .. DEBUG_TEST_FILE)
    if not content or content == '' then return false end
    local data = jsonDecode(content)
    return type(data) == 'table' and data.noIpc == true
end

-- ====== 命令执行 ======

local function executeShellCommand(cmd, noIpc)
    if not cmd or cmd == '' then
        return { stdout = '', stderr = '', exitcode = -1 }
    end
    local noIpcDebugEnabled = noIpc == true or isNoIpcDebugEnabled()
    if not noIpcDebugEnabled and commandTouchesProtectedIpc(cmd) then
        writeLuaEventLog('命令被拦截', cmd, '命令包含 Shell++ IPC 受保护路径或文件名')
        return { stdout = '', stderr = 'Blocked: command touches protected Shell++ IPC files', exitcode = -2 }
    end
    if not noIpcDebugEnabled and commandLooksLikeNestedScript(cmd) then
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

local function screenshotBytesPerPixel(pixelFormat)
    if pixelFormat == 'rgb565le' or pixelFormat == 'bgr565le' then
        return 2
    end
    if pixelFormat == 'bgra8888'
        or pixelFormat == 'rgba8888'
        or pixelFormat == 'bgrx8888'
        or pixelFormat == 'rgbx8888'
        or pixelFormat == 'rgb24_padded32'
        or pixelFormat == 'xrgb8888_le' then
        return 4
    end
    return 3
end

local function bgrRowToPngScanline(rowData, width, pixelFormat)
    local bytesPerPixel = screenshotBytesPerPixel(pixelFormat)
    if not rowData or #rowData < width * bytesPerPixel then
        return nil
    end
    local parts = { '\0' }
    local out = 2
    for x = 0, width - 1 do
        local p = x * bytesPerPixel + 1
        local b, g, r
        if pixelFormat == 'rgba8888' or pixelFormat == 'rgbx8888' then
            r = string.byte(rowData, p) or 0
            g = string.byte(rowData, p + 1) or 0
            b = string.byte(rowData, p + 2) or 0
        else
            b = string.byte(rowData, p) or 0
            g = string.byte(rowData, p + 1) or 0
            r = string.byte(rowData, p + 2) or 0
        end
        parts[out] = string.char(r, g, b)
        out = out + 1
    end
    return table.concat(parts)
end

local function writePngRows(rawPath, path, width, height, pixelFormat, sourceStrideBytes, rowDecoder)
    local fRaw = io.open(rawPath, 'rb')
    if not fRaw then
        return false, '无法读取截图临时文件'
    end

    local writer = makePngWriter(path)
    if not writer then
        fRaw:close()
        return false, '无法创建 PNG 文件'
    end

    local bytesPerPixel = screenshotBytesPerPixel(pixelFormat)
    local rowLen = tonumber(sourceStrideBytes) or width * bytesPerPixel
    if rowLen < width * bytesPerPixel then
        fRaw:close()
        writer.close()
        removeFile(path)
        return false, '截图行跨度不足'
    end
    local scanlineLen = width * 3 + 1
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
            local scanline = rowDecoder(row, width, pixelFormat)
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

writeO63PngFromRaw = function(rawPath, path, profile)
    local width = tonumber(profile.width) or 466
    local height = tonumber(profile.height) or 466
    local rawSize = fileSize(rawPath)
    local pixelFormat = tostring(profile.pixelFormat or '')
    local rgb565Size = width * height * 2
    if pixelFormat == 'rgb565le' or pixelFormat == 'bgr565le' or rawSize == rgb565Size then
        local stride = tonumber(profile.strideBytes) or width * 2
        if stride < width * 2 or rawSize < stride * height then
            return false, 'O63 BGR565 截图数据长度或行跨度无效'
        end
        local function decodeRgb565(rowData, rowWidth, format)
            if not rowData or #rowData < rowWidth * 2 then return nil end
            local parts = { '\0' }
            local out = 2
            for x = 0, rowWidth - 1 do
                local p = x * 2 + 1
                local pixel = (string.byte(rowData, p) or 0)
                    | ((string.byte(rowData, p + 1) or 0) << 8)
                local high5 = (pixel >> 11) & 0x1F
                local g6 = (pixel >> 5) & 0x3F
                local low5 = pixel & 0x1F
                local isBgr = format == 'bgr565le'
                local r5 = isBgr and low5 or high5
                local b5 = isBgr and high5 or low5
                parts[out] = string.char(
                    (r5 << 3) | (r5 >> 2),
                    (g6 << 2) | (g6 >> 4),
                    (b5 << 3) | (b5 >> 2)
                )
                out = out + 1
            end
            return table.concat(parts)
        end
        return writePngRows(rawPath, path, width, height, pixelFormat == 'bgr565le' and 'bgr565le' or 'rgb565le', stride,
            decodeRgb565)
    end
    local stride = tonumber(profile.strideBytes) or 1920
    if stride < width * 4 or rawSize < stride * height then
        return false, 'O63 截图数据长度或行跨度无效'
    end
    local function decodeXrgb8888(rowData, rowWidth)
        if not rowData or #rowData < rowWidth * 4 then return nil end
        local parts = { '\0' }
        local out = 2
        for x = 0, rowWidth - 1 do
            local p = x * 4 + 1
            parts[out] = string.char(
                string.byte(rowData, p + 2) or 0,
                string.byte(rowData, p + 1) or 0,
                string.byte(rowData, p) or 0
            )
            out = out + 1
        end
        return table.concat(parts)
    end
    return writePngRows(rawPath, path, width, height, 'xrgb8888_le', stride,
        decodeXrgb8888)
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

-- NuttX framebuffer reads can become corrupted when requested in large chunks.
-- Keep each physical scanline as a separate read.
local function copyRows(input, output, rowBytes, rows)
    rowBytes = tonumber(rowBytes) or 0
    rows = tonumber(rows) or 0
    if rowBytes <= 0 or rows <= 0 then return false end
    for _ = 1, rows do
        local row = ''
        while #row < rowBytes do
            local ok, chunk = pcall(input.read, input, rowBytes - #row)
            if not ok or not chunk or chunk == '' then return false end
            row = row .. chunk
        end
        if #row > rowBytes then row = string.sub(row, 1, rowBytes) end
        local ok = pcall(output.write, output, row)
        if not ok then return false end
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
        pixelFormat = profile.pixelFormat,
        sourceBpp = profile.sourceBpp,
        sourceVirtualWidth = profile.sourceVirtualWidth,
        sourceVirtualHeight = profile.sourceVirtualHeight,
        sourceFramebufferBytes = profile.sourceFramebufferBytes,
        readMode = profile.readMode,
        reopenRows = profile.reopenRows,
        directDd = profile.directDd,
        directDdRows = profile.directDdRows,
        seekChunkBytes = profile.seekChunkBytes,
        atomicPng = profile.atomicPng
    }
end

local function scoreScreenshotRaw(path, profile)
    local f = io.open(path, 'rb')
    if not f then return -1 end
    local score = 0
    local rowLen = profile.strideBytes
    local visibleRowLen = profile.width * screenshotBytesPerPixel(profile.pixelFormat)
    local bytesPerPixel = screenshotBytesPerPixel(profile.pixelFormat)
    local step = 6
    for y = 1, profile.height do
        local row = f:read(rowLen)
        if not row or #row < rowLen then break end
        if y % 4 == 0 then
            local x = 1
            while x <= visibleRowLen - (bytesPerPixel - 1) do
                local b, g, r
                if profile.pixelFormat == 'bgr565le' then
                    local pixel = (string.byte(row, x) or 0)
                        | ((string.byte(row, x + 1) or 0) << 8)
                    local b5 = (pixel >> 11) & 0x1F
                    local g6 = (pixel >> 5) & 0x3F
                    local r5 = pixel & 0x1F
                    b = (b5 << 3) | (b5 >> 2)
                    g = (g6 << 2) | (g6 >> 4)
                    r = (r5 << 3) | (r5 >> 2)
                else
                    b = string.byte(row, x) or 0
                    g = string.byte(row, x + 1) or 0
                    r = string.byte(row, x + 2) or 0
                end
                if b > 180 and g > 70 and g < 180 and r < 80 then
                    score = score + 8
                elseif b > 130 and g > 40 and r < 100 then
                    score = score + 1
                end
                x = x + step * bytesPerPixel
            end
        end
    end
    f:close()
    return score
end

local function captureFramebufferSingleToFile(path, profile)
    profile = profile or getScreenshotProfile()
    if profile.reopenRows then
        removeFile(path)
        local output = io.open(path, 'wb')
        if not output then return false end
        local rowsPerOpen = tonumber(profile.reopenRows) or 1
        local totalRows = tonumber(profile.readRows) or profile.height
        local row = 0
        local okAll = true
        while row < totalRows do
            local rows = math.min(rowsPerOpen, totalRows - row)
            local bytes = rows * profile.strideBytes
            local offset = ((profile.skipRows or 0) + row) * profile.strideBytes
            local input = io.open(FB_PATH, 'rb')
            local chunk = nil
            if input then
                local seekOk, seekPos = pcall(input.seek, input, 'set', offset)
                if seekOk and seekPos then
                    local readOk, data = pcall(input.read, input, bytes)
                    if readOk then chunk = data end
                end
                input:close()
            end
            if not chunk or #chunk ~= bytes then
                okAll = false
                break
            end
            local writeOk = pcall(output.write, output, chunk)
            if not writeOk then
                okAll = false
                break
            end
            row = row + rows
        end
        output:close()
        if okAll and fileSize(path) == profile.rawBytes then return true end
        removeFile(path)
        return false
    end
    if profile.seekChunkBytes then
        removeFile(path)
        local input = io.open(FB_PATH, 'rb')
        local output = io.open(path, 'wb')
        if not input or not output then
            if input then input:close() end
            if output then output:close() end
            return false
        end
        local chunkBytes = tonumber(profile.seekChunkBytes) or 64
        local okAll = true
        for y = 0, (profile.readRows or profile.height) - 1 do
            local row = ''
            local rowBase = (profile.skipRows or 0) * profile.strideBytes + y * profile.strideBytes
            for x = 0, profile.strideBytes - 1, chunkBytes do
                local want = math.min(chunkBytes, profile.strideBytes - x)
                local seekOk, seekPos = pcall(input.seek, input, 'set', rowBase + x)
                local readOk, chunk = false, nil
                if seekOk and seekPos then
                    readOk, chunk = pcall(input.read, input, want)
                end
                if not readOk or not chunk or #chunk < want then
                    okAll = false
                    break
                end
                row = row .. chunk
            end
            if not okAll then break end
            local writeOk = pcall(output.write, output, row)
            if not writeOk then okAll = false; break end
        end
        input:close()
        output:close()
        if okAll and fileSize(path) >= profile.rawBytes then return true end
        removeFile(path)
        return false
    end
    if profile.directDdRows then
        removeFile(path)
        local output = io.open(path, 'wb')
        if not output then return false end
        local tmp = path .. '.row'
        local okAll = true
        for y = 0, (profile.readRows or profile.height) - 1 do
            removeFile(tmp)
            local skipBytes = (profile.skipRows or 0) * profile.strideBytes + y * profile.strideBytes
            os.execute('dd if=' .. FB_PATH .. ' of=' .. tmp
                .. ' bs=1 skip=' .. tostring(skipBytes)
                .. ' count=' .. tostring(profile.strideBytes)
                .. ' 2>/dev/null')
            local input = io.open(tmp, 'rb')
            local row = input and input:read(profile.strideBytes) or nil
            if input then input:close() end
            if not row or #row < profile.strideBytes then
                okAll = false
                break
            end
            local writeOk = pcall(output.write, output, row)
            if not writeOk then
                okAll = false
                break
            end
        end
        output:close()
        removeFile(tmp)
        if okAll and fileSize(path) >= profile.rawBytes then return true end
        removeFile(path)
        return false
    end
    if profile.directDd then
        removeFile(path)
        os.execute('dd if=' .. FB_PATH .. ' of=' .. path
            .. ' bs=' .. tostring(profile.strideBytes)
            .. ' skip=' .. tostring(profile.skipRows or 0)
            .. ' count=' .. tostring(profile.readRows or profile.height)
            .. ' 2>/dev/null')
        if fileSize(path) >= profile.rawBytes then return true end
        removeFile(path)
        return false
    end
    local function tryReadAt(offsetBytes)
        removeFile(path)
        local input = io.open(FB_PATH, 'rb')
        local output = io.open(path, 'wb')
        if input and output then
            local seekOk, seekPos = pcall(input.seek, input, 'set', offsetBytes)
            local copied = false
            if seekOk and seekPos then
                if profile.readMode == 'rows' then
                    copied = copyRows(input, output, profile.strideBytes, profile.readRows or profile.height)
                else
                    copied = copyStream(input, output, profile.readBytes or profile.rawBytes)
                end
            end
            input:close()
            output:close()
            input = nil
            output = nil
            local size = fileSize(path)
            if copied and size >= profile.rawBytes then
                return true
            end
            if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
                return true
            end
        end
        if input then input:close() end
        if output then output:close() end
        removeFile(path)
        return false
    end

    if tryReadAt(profile.offsetBytes) then
        return true
    end
    if profile.offsetBytes ~= 0 and tryReadAt(0) then
        return true
    end

    os.execute('dd if=' .. FB_PATH .. ' of=' .. path .. ' bs=' .. tostring(profile.strideBytes) .. ' skip=' .. tostring(profile.skipRows) .. ' count=' .. tostring(profile.readRows or profile.height) .. ' 2>/dev/null')
    local size = fileSize(path)
    if size >= profile.rawBytes then
        return true
    end
    if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
        return true
    end
    if profile.offsetBytes ~= 0 then
        os.execute('dd if=' .. FB_PATH .. ' of=' .. path .. ' bs=' .. tostring(profile.strideBytes) .. ' skip=0 count=' .. tostring(profile.height) .. ' 2>/dev/null')
        size = fileSize(path)
        if size >= profile.rawBytes then
            return true
        end
        if size >= (profile.minRawBytes or profile.rawBytes) and padFileToSize(path, profile.rawBytes) then
            return true
        end
    end
    removeFile(path)
    return false
end

local function captureFramebufferToFile(path, profile)
    profile = profile or getScreenshotProfile()
    profile.candidateScores = {}
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
            profile.candidateScores[#profile.candidateScores + 1] =
                'skip=' .. tostring(skipRows)
                .. ',score=' .. tostring(score)
                .. ',bytes=' .. tostring(fileSize(candidatePath))
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
    profile.selectedCandidate = 'skip=' .. tostring(profile.skipRows)
        .. ',score=' .. tostring(bestScore)
        .. ',bytes=' .. tostring(fileSize(bestPath))
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

local function screenshotDisplayInfo()
    local result = 'lvgl_res=?x?'
    local ok, disp = pcall(function() return lvgl.disp.get_default() end)
    if ok and disp then
        local got, w, h = pcall(function() return disp:get_res() end)
        if got and w and h then
            result = 'lvgl_res=' .. tostring(w) .. 'x' .. tostring(h)
        end
    end
    return result
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
        .. '\ndevice_product=' .. tostring(activeDeviceProduct or '-')
        .. '\ndevice_model=' .. tostring(activeDeviceModel or '-')
        .. '\ntarget_dir=' .. tostring(TARGET_DIR or '-')
        .. '\n' .. screenshotDisplayInfo()
        .. '\nframebuffer_size=' .. tostring(profile.rawBytes)
        .. '\npixel_format=' .. tostring(profile.pixelFormat)
        .. '\nscreenshot_profile=' .. tostring(profile.name)
        .. '\nscreen=' .. tostring(profile.width) .. 'x' .. tostring(profile.height)
        .. '\nstride_bytes=' .. tostring(profile.strideBytes)
        .. '\nsource_bpp=' .. tostring(profile.sourceBpp or '-')
        .. '\nsource_virtual=' .. tostring(profile.sourceVirtualWidth or '-')
        .. 'x' .. tostring(profile.sourceVirtualHeight or '-')
        .. '\nsource_fblen=' .. tostring(profile.sourceFramebufferBytes or '-')
        .. '\noffset_bytes=' .. tostring(profile.offsetBytes)
        .. '\nskip_rows=' .. tostring(profile.skipRows)
        .. '\nread_rows=' .. tostring(profile.readRows or profile.height)
        .. '\nread_bytes=' .. tostring(profile.readBytes or profile.rawBytes)
        .. '\nmin_raw_bytes=' .. tostring(profile.minRawBytes or profile.rawBytes)
        .. '\ncandidate_scores=' .. tostring(table.concat(profile.candidateScores or {}, ';'))
        .. '\nselected_candidate=' .. tostring(profile.selectedCandidate or '-')
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
    -- Keep the full diagnostic visible in the in-app Lua log as well as the
    -- optional persisted lua_log_*.txt file.
    addLog('[shot] diag_start\n' .. screenshotDiagText('capture_start', profile))
    writeLuaEventLog('截图诊断', '开始采集', screenshotDiagText('capture_start', profile))
    local captured = false
    if isStreamProfile then
        captured = captureFramebufferToFile(TMP_RAW, profile)
    else
        captured = captureFramebufferLegacy(TMP_RAW, profile)
    end
    if not captured then
        removeFile(TMP_RAW)
        addLog('[shot] diag_failed\n' .. screenshotDiagText('capture_failed', profile))
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
            screenWidth = profile.width,
            screenHeight = profile.height,
            strideBytes = profile.strideBytes,
            sourceStrideBytes = profile.strideBytes,
            sourceFramebufferBytes = profile.sourceFramebufferBytes,
            rawBytes = fileSize(outPath),
            pixelFormatGuess = profile.pixelFormat,
            source = 'framebuffer_raw'
        }))
        source = 'framebuffer_raw'
        message = '原始像素已保存'
    else
        filename = buildScreenshotFilename(shotId)
        outPath = SCREENSHOT_DIR .. filename
        quickPath = 'internal://files/screenshots/' .. filename
        if isStreamProfile then
            if profile.atomicPng then
                local temporaryPng = outPath .. '.tmp'
                removeFile(temporaryPng)
                if profile.pngConverter == 'o63' then
                    ok = writeO63PngFromRaw(TMP_RAW, temporaryPng, profile)
                else
                    ok = writePngRows(TMP_RAW, temporaryPng, profile.width, profile.height,
                        profile.pixelFormat, profile.strideBytes, bgrRowToPngScanline)
                end
                if ok then
                    removeFile(outPath)
                    local renameSafe, renamed = pcall(os.rename, temporaryPng, outPath)
                    ok = renameSafe and renamed and true or false
                end
                if not ok then removeFile(temporaryPng) end
            else
                if profile.pngConverter == 'o63' then
                    ok = writeO63PngFromRaw(TMP_RAW, outPath, profile)
                else
                    ok = writePngRows(TMP_RAW, outPath, profile.width, profile.height,
                        profile.pixelFormat, profile.strideBytes, bgrRowToPngScanline)
                end
            end
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
    addLog('[shot] diag_done\n' .. screenshotDiagText('capture_done', profile))
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
        screenWidth = profile.width,
        screenHeight = profile.height,
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



function readAppManagerRequest()
    local reqFile = TARGET_DIR .. 'app_manager_request.json'
    if not fileExists(reqFile) then return nil end

    local content = readFile(reqFile)
    if not content or content == '' then return nil end

    local json = jsonDecode(content)
    if not json then
        os.execute('sleep 0.1')
        content = readFile(reqFile)
        if not content or content == '' then return nil end
        json = jsonDecode(content)
        if not json then return nil end
    end
    if not json.seq or not json.action then return nil end
    if not validateIpcGuard(json, 'app_manager_request.json') then return nil end
    return {
        seq = json.seq,
        type = 'app_manager',
        action = json.action,
        operation = json.operation,
        visible = json.visible,
        all = json.all,
        package = json.package,
        packages = json.packages,
        timestamp = json.timestamp
    }
end

function readCpuMonitorRequest()
    local reqFile = TARGET_DIR .. 'cpu_monitor_request.json'
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
    if not validateIpcGuard(json, 'cpu_monitor_request.json') then
        return nil
    end
    return {
        seq = json.seq,
        type = 'cpu_monitor',
        action = json.action,
        timestamp = json.timestamp
    }
end

function readMemoryMonitorRequest()
    local reqFile = TARGET_DIR .. 'memory_monitor_request.json'
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
    if not validateIpcGuard(json, 'memory_monitor_request.json') then
        return nil
    end
    return {
        seq = json.seq,
        type = 'memory_monitor',
        action = json.action,
        timestamp = json.timestamp
    }
end

function readScreenshotFloatRequest()
    local reqFile = TARGET_DIR .. 'screenshot_float_request.json'
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
    if not validateIpcGuard(json, 'screenshot_float_request.json') then
        return nil
    end
    return {
        seq = json.seq,
        type = 'screenshot_float',
        action = json.action,
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

function readFileTransferRequest()
    local reqFile = TARGET_DIR .. 'file_transfer_request.json'
    if not fileExists(reqFile) then return nil end
    local content = readFile(reqFile)
    if not content or content == '' then return nil end
    local json = jsonDecode(content)
    if not json then
        os.execute('sleep 0.1')
        content = readFile(reqFile)
        if not content or content == '' then return nil end
        json = jsonDecode(content)
        if not json then return nil end
    end
    if not json.seq or not json.action or not json.sessionId then return nil end
    if not validateIpcGuard(json, 'file_transfer_request.json') then return nil end
    return {
        seq = json.seq,
        type = 'file_transfer',
        action = json.action,
        sessionId = tostring(json.sessionId),
        path = json.path or '',
        offset = tonumber(json.offset) or 0,
        length = tonumber(json.length) or 0,
        index = tonumber(json.index) or 0,
        chunkSize = tonumber(json.chunkSize) or FILE_TRANSFER_DEFAULT_CHUNK_SIZE,
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



function writeAppManagerResult(req, result)
    result = result or {}
    result.type = 'app_manager_result'
    result.seq = req and req.seq or -1
    result.action = result.action or (req and req.action or '')
    result.timestamp = os.date('%H:%M:%S')
    atomicWrite('app_manager_result.json', result)
    os.remove(TARGET_DIR .. 'app_manager_request.json')
end

function writeCpuMonitorResult(req, status, message)
    atomicWrite('cpu_monitor_result.json', {
        type = 'cpu_monitor_result',
        seq = req and req.seq or -1,
        action = req and req.action or '',
        status = status or 'ok',
        message = message or '',
        timestamp = os.date('%H:%M:%S')
    })
    os.remove(TARGET_DIR .. 'cpu_monitor_request.json')
end

function writeMemoryMonitorResult(req, status, message)
    atomicWrite('memory_monitor_result.json', {
        type = 'memory_monitor_result',
        seq = req and req.seq or -1,
        action = req and req.action or '',
        status = status or 'ok',
        message = message or '',
        timestamp = os.date('%H:%M:%S')
    })
    os.remove(TARGET_DIR .. 'memory_monitor_request.json')
end

function writeScreenshotFloatResult(req, status, message)
    atomicWrite('screenshot_float_result.json', {
        type = 'screenshot_float_result',
        seq = req and req.seq or -1,
        action = req and req.action or '',
        status = status or 'ok',
        message = message or '',
        timestamp = os.date('%H:%M:%S')
    })
    os.remove(TARGET_DIR .. 'screenshot_float_request.json')
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

function writeFileTransferResult(req, result)
    result = result or {}
    result.type = 'file_transfer_result'
    result.seq = req and req.seq or -1
    result.action = req and req.action or ''
    result.sessionId = req and req.sessionId or ''
    result.timestamp = os.date('%H:%M:%S')
    atomicWrite('file_transfer_result.json', result)
    os.remove(TARGET_DIR .. 'file_transfer_request.json')
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

function captureScreenshotFromFloat()
    if not screenshotFloatEnabled then return end
    if screenshotFloatCaptureTimer then
        addLog('[shot] float waiting')
        return
    end
    if cmdBusy then
        addLog('[shot] float busy')
        writeLuaEventLog('截图悬浮', '截图被跳过', '当前已有任务执行中')
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
        source = 'lua_float_button'
    }
    cmdBusy = true
    busyMode = 'screenshot'
    if screenshotFloatLayer then
        screenshotFloatLayer:add_flag(lvgl.FLAG.HIDDEN)
    end
    writeBridgeState(true, 'screenshot', '悬浮按钮截图中')
    writeScreenshotResult({
        type = 'screenshot_result',
        seq = req.seq,
        status = 'capturing',
        message = '悬浮按钮截图中',
        timestamp = os.date('%H:%M:%S')
    })
    addLog('[shot] hide float before capture')
    screenshotFloatCaptureTimer = lvgl.Timer({
        period = 160,
        repeat_count = 1,
        cb = function(timer)
            pcall(function() timer:delete() end)
            screenshotFloatCaptureTimer = nil
            addLog('[shot] capture from float button')
            local item, err = captureScreenshot(req)
            if item then
                addLog('[shot] saved #' .. tostring(item.index))
                finishScreenshotSuccess(item)
            else
                addLog('[shot] failed: ' .. tostring(err))
                finishScreenshotError(err or '截图失败')
            end
            if screenshotFloatEnabled and screenshotFloatLayer then
                updateScreenshotFloatLayout()
                screenshotFloatLayer:clear_flag(lvgl.FLAG.HIDDEN)
                writeScreenshotFloatState()
            end
        end
    })
    screenshotFloatCaptureTimer:resume()
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
        if luaExtensionStatusLabel then luaExtensionStatusLabel:set { text = '当前忙碌，请稍后重试' } end
        return
    end
    if not isRunning then
        addLog('[shot] service not running')
        if luaExtensionStatusLabel then luaExtensionStatusLabel:set { text = 'Lua 后端未运行' } end
        return
    end
    localScreenshotSeq = localScreenshotSeq + 1
    local req = {
        seq = localScreenshotSeq,
        type = 'screenshot',
        timestamp = os.time(),
        source = 'lua_log_page'
    }
    addLog('[shot] local request waiting for screen on')
    if luaExtensionStatusLabel then luaExtensionStatusLabel:set { text = '请熄屏后亮屏' } end
    prepareScreenshotRequest(req)
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

function fileManagerSizeBytes(path)
    local ok, size = pcall(function()
        local f = lvgl.fs.open_file(path, 'r')
        if not f then return nil end
        local len = f:seek('end')
        f:close()
        return tonumber(len)
    end)
    if ok and size and size >= 0 then return math.floor(size) end
    return 0
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
    if length > 2048 then length = 2048 end
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

function isValidFileTransferSessionId(sessionId)
    return type(sessionId) == 'string' and #sessionId > 0 and #sessionId <= 64
        and string.match(sessionId, '^[%w_-]+$') ~= nil
end

function fileTransferStagePath(sessionId)
    return TARGET_DIR .. 'file_transfer/' .. sessionId .. '.part'
end

function stageFileTransferChunk(session, index)
    if index < 0 or index >= session.total then return nil, 0, 'invalid_chunk_index' end
    local offset = session.offset + index * session.chunkSize
    local rangeEnd = session.offset + session.length
    local expected = math.min(rangeEnd - offset, session.chunkSize)
    if expected <= 0 then return nil, 0, 'empty_chunk' end
    local ok, actual = pcall(function()
        local input = lvgl.fs.open_file(session.path, 'r')
        if not input then return nil end
        input:seek('set', offset)
        mkdir(TARGET_DIR .. 'file_transfer/')
        local output = io.open(fileTransferStagePath(session.sessionId), 'wb')
        if not output then input:close(); return nil end
        local remaining = expected
        local written = 0
        while remaining > 0 do
            local chunk = input:read(math.min(4096, remaining))
            if not chunk or chunk == '' then break end
            output:write(chunk)
            written = written + #chunk
            remaining = remaining - #chunk
        end
        input:close()
        output:close()
        return written
    end)
    if not ok or not actual or actual <= 0 then
        os.remove(fileTransferStagePath(session.sessionId))
        return nil, 0, 'stage_failed'
    end
    return 'file_transfer/' .. session.sessionId .. '.part', actual, ''
end

function executeFileTransferRequest(req)
    if not isValidFileTransferSessionId(req.sessionId) then
        return { status = 'error', message = 'invalid_session_id' }
    end
    if req.action == 'start' then
        -- 覆盖旧会话：RPK 异常退出时旧会话会残留导致永久 busy
        -- 新 start 请求到来时直接作废旧会话，并清空整个 file_transfer/ 目录
        -- 原始实现（会导致死锁）：if fileTransferSession then return { status = 'error', message = 'busy' } end
        if fileTransferSession then
            fileTransferSession = nil
        end
        -- 清空 file_transfer/ 目录下所有残留 .part（历史孤儿文件也一并清理）
        pcall(os.execute, 'rm -rf "' .. TARGET_DIR .. 'file_transfer/"')
        mkdir(TARGET_DIR .. 'file_transfer/')
        local path = normalizeFileManagerPath(req.path)
        local size = fileManagerSizeBytes(path)
        if size <= 0 then return { status = 'error', message = 'file_not_found_or_empty', path = path } end
        local offset = tonumber(req.offset) or 0
        if offset < 0 then offset = 0 end
        if offset >= size then return { status = 'error', message = 'offset_out_of_range', path = path, sizeBytes = size } end
        local length = tonumber(req.length) or 0
        if length <= 0 then length = size - offset end
        if offset + length > size then length = size - offset end
        local chunkSize = math.floor(req.chunkSize or FILE_TRANSFER_DEFAULT_CHUNK_SIZE)
        if chunkSize < FILE_TRANSFER_MIN_CHUNK_SIZE then chunkSize = FILE_TRANSFER_MIN_CHUNK_SIZE end
        if chunkSize > FILE_TRANSFER_MAX_CHUNK_SIZE then chunkSize = FILE_TRANSFER_MAX_CHUNK_SIZE end
        fileTransferSession = {
            sessionId = req.sessionId,
            path = path,
            name = basename(path),
            size = size,
            offset = offset,
            length = length,
            chunkSize = chunkSize,
            total = math.max(0, math.ceil(length / chunkSize))
        }
        return {
            status = 'ok', path = path, name = basename(path), sizeBytes = size,
            offset = offset, length = length, chunkSize = chunkSize, total = fileTransferSession.total
        }
    end
    local session = fileTransferSession
    if not session or session.sessionId ~= req.sessionId then
        return { status = 'error', message = 'session_not_found' }
    end
    if req.action == 'chunk' then
        local stagedFile, sizeBytes, message = stageFileTransferChunk(session, math.floor(req.index or 0))
        if not stagedFile then return { status = 'error', message = message, path = session.path } end
        return {
            status = 'ok', path = session.path, stagedFile = stagedFile,
            sizeBytes = sizeBytes, offset = session.offset + math.floor(req.index or 0) * session.chunkSize,
            index = math.floor(req.index or 0), total = session.total
        }
    end
    if req.action == 'finish' or req.action == 'abort' then
        os.remove(fileTransferStagePath(session.sessionId))
        fileTransferSession = nil
        return { status = 'ok', path = session.path }
    end
    return { status = 'error', message = 'unknown_action' }
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



function checkAppManagerRequest()
    if cmdBusy then return end
    if not isRunning then return end

    local req = readAppManagerRequest()
    if not req then return end

    cmdBusy = true
    busyMode = 'app_manager'
    writeBridgeState(true, 'app_manager', '应用管理操作中')
    local ok, result = pcall(function()
        return executeAppManagerRequest(req)
    end)
    if ok then
        writeAppManagerResult(req, result)
        if req.action ~= 'cache_status' and req.action ~= 'cache_clear' then
            writeLuaEventLog('应用管理', req.action or '',
                '序号: ' .. tostring(req.seq or -1)
                .. '\n操作: ' .. tostring(req.action or '')
                .. '\n状态: ' .. tostring(result and result.status or '-'))
        end
    else
        writeAppManagerResult(req, { status = 'error', action = req.action, message = tostring(result or '应用管理操作失败') })
    end
    cmdBusy = false
    busyMode = ''
    writeBridgeState(false, '', '')
end

function checkCpuMonitorRequest()

    if not isRunning then return end

    local req = readCpuMonitorRequest()
    if not req then return end

    local ok, message = pcall(function()
        return executeCpuMonitorAction(req.action)
    end)
    if ok then
        writeCpuMonitorResult(req, 'ok', message or '完成')
    else
        writeCpuMonitorResult(req, 'error', tostring(message or 'CPU 操作失败'))
    end
end

function checkMemoryMonitorRequest()
    if not isRunning then return end

    local req = readMemoryMonitorRequest()
    if not req then return end

    local ok, message = pcall(function()
        return executeMemoryMonitorAction(req.action)
    end)
    if ok then
        writeMemoryMonitorResult(req, 'ok', message or '完成')
    else
        writeMemoryMonitorResult(req, 'error', tostring(message or '内存操作失败'))
    end
end

function checkScreenshotFloatRequest()
    if not isRunning then return end

    local req = readScreenshotFloatRequest()
    if not req then return end

    local ok, message = pcall(function()
        return executeScreenshotFloatAction(req.action)
    end)
    if ok then
        writeScreenshotFloatResult(req, 'ok', message or '完成')
    else
        writeScreenshotFloatResult(req, 'error', tostring(message or '截图悬浮操作失败'))
    end
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

function checkFileTransferRequest()
    if cmdBusy then return end
    if not isRunning then return end
    local req = readFileTransferRequest()
    if not req then return end
    cmdBusy = true
    busyMode = 'file_transfer'
    writeBridgeState(true, 'file_transfer', '文件传输准备中')
    local ok, result = pcall(function() return executeFileTransferRequest(req) end)
    if ok then
        writeFileTransferResult(req, result)
    else
        writeFileTransferResult(req, { status = 'error', message = tostring(result or 'file_transfer_failed') })
    end
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
    local result = executeShellCommand(req.cmd, req.noIpc == true)
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

-- ====== 振动请求（QuickApp 点击触发） ======

local function checkVibrationRequest()
    if not isRunning then return end
    local reqFile = TARGET_DIR .. 'vibration_request.json'
    if not fileExists(reqFile) then return end
    local content = readFile(reqFile)
    if not content or content == '' then return end
    local json = jsonDecode(content)
    if not json or type(json.value) ~= 'number' then
        os.remove(reqFile)
        return
    end
    local v = tonumber(json.value) or -1
    if v < 0 or v > 14 then
        os.remove(reqFile)
        return
    end
    pcall(function()
        if vibrator and type(vibrator.start) == 'function' then
            vibrator.start(v)
        end
    end)
    os.remove(reqFile)
    addLog('[vib] vibrator.start(' .. tostring(v) .. ')')
end

-- ====== MCU 算力检测（QuickApp 触发） ======

local function checkMcuBenchRequest()
    if not isRunning then return end
    local reqFile = TARGET_DIR .. 'mcu_bench_request.json'
    if not fileExists(reqFile) then return end
    local content = readFile(reqFile)
    if not content or content == '' then return end
    local json = jsonDecode(content)
    if not json or json.action ~= 'start' then
        os.remove(reqFile)
        return
    end
    local loops = tonumber(json.loops) or 30000
    if loops < 1000 then loops = 1000 end
    if loops > 200000 then loops = 200000 end
    addLog('[bench] Lua MCU test: ' .. tostring(loops) .. ' loops')
    local start = os.clock()
    local x = 1.5
    for i = 1, loops do
        x = math.sqrt(x * 1.0001 + 0.5)
    end
    local elapsed = os.clock() - start
    local ops = math.floor(loops / elapsed)
    atomicWrite('mcu_bench_result.json', {
        loops = loops,
        ops_per_sec = ops,
        elapsed_ms = math.floor(elapsed * 1000),
        volatile = string.format('%.2f', x)
    })
    os.remove(reqFile)
    addLog('[bench] ' .. tostring(ops) .. ' ops/s, ' .. tostring(math.floor(elapsed * 1000)) .. 'ms')
end


local function writeHeartbeat()
    local data = {
        type = 'system_info',
        timestamp = tostring(os.time())
    }
    atomicWrite('system_info.json', data)
end
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
    writeCpuMonitorState()
    if memoryMonitorEnabled then writeMemoryMonitorState()
    else pcall(os.remove, TARGET_DIR .. 'memory_monitor_state.json') end
    writeScreenshotFloatState()
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
                checkMcuBenchRequest()
                checkVibrationRequest()
                checkCpuMonitorRequest()
                checkMemoryMonitorRequest()
                checkScreenshotFloatRequest()
                checkAppManagerRequest()
                checkFileTransferRequest()
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
    if cpuMonitorTimer then cpuMonitorTimer:pause() end
    if cpuLogClearTimer then cpuLogClearTimer:pause() end
    if memoryMonitorTimer then memoryMonitorTimer:pause() end
    if memoryLogClearTimer then memoryLogClearTimer:pause() end
    cpuMonitorEnabled = false
    hideCpuFloatLayer()
    memoryMonitorEnabled = false
    hideMemoryFloatLayer()
    hideScreenshotFloatLayer()
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

function stopPageRefreshTimer()
    if pageRefreshTimer then
        pcall(function() pageRefreshTimer:delete() end)
        pageRefreshTimer = nil
    end
    monitorStatusLabel = nil
    monitorLogArea = nil
    monitorPageKind = ''
    luaExtensionStatusLabel = nil
end

function makeCardButton(parent, x, y, w, h, title, subtitle, bgColor, cb)
    local btn = lvgl.Object(parent, {
        x = x, y = y,
        w = w, h = h,
        bg_color = bgColor or UI_CARD,
        radius = UI_CARD_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    btn:clear_flag(lvgl.FLAG.SCROLLABLE)
    btn:add_flag(lvgl.FLAG.CLICKABLE)
    local titleY = subtitle and 10 or math.floor((h - 30) / 2)
    local titleLabel = lvgl.Label(btn, {
        x = 18, y = titleY,
        w = w - 36, h = 34,
        text = title,
        text_font = lvgl.Font("MiSans-Regular", 26),
        text_color = UI_TEXT,
    })
    titleLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    if subtitle and subtitle ~= '' then
        local subLabel = lvgl.Label(btn, {
            x = 18, y = titleY + 34,
            w = w - 36, h = 28,
            text = subtitle,
            text_font = lvgl.Font("MiSans-Regular", 18),
            text_color = UI_TERM_TEXT,
        })
        subLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    end
    btn:onevent(lvgl.EVENT.CLICKED, cb)
    return btn
end

function makeRoundBack(parent, cb)
    local backDiam = UI_TOPBAR_H - UI_GAP
    local backBtn = lvgl.Object(parent, {
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
    backBtn:onevent(lvgl.EVENT.CLICKED, cb)
    return backBtn
end

function makeWideBack(parent, cb)
    local backH = UI_TOPBAR_H - UI_GAP
    local backBtn = lvgl.Object(parent, {
        x = UI_GAP, y = UI_GAP,
        w = 72, h = backH,
        bg_color = UI_CARD,
        radius = math.floor(backH / 2),
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
    backBtn:onevent(lvgl.EVENT.CLICKED, cb)
    return backBtn
end

function readStorageUsage()
    local outputPath = TARGET_DIR .. '.storage_usage.txt'
    pcall(os.remove, outputPath)
    pcall(os.execute, 'df -h > "' .. outputPath .. '"')
    local output = readAll(outputPath, 8192)
    pcall(os.remove, outputPath)
    local systemUsage = '未知'
    local userUsage = '未知'
    for line in tostring(output or ''):gmatch('[^\r\n]+') do
        local parts = {}
        for part in line:gmatch('%S+') do
            parts[#parts + 1] = part
        end
        if #parts >= 4 then
            local mountPoint = parts[#parts]
            local usage = tostring(parts[3]) .. '/' .. tostring(parts[2])
            if mountPoint == '/system' then
                systemUsage = usage
            elseif mountPoint == '/data' then
                userUsage = usage
            end
        end
    end
    return systemUsage, userUsage
end

function monitorLogsToText(kind)
    local logs = kind == 'memory' and memoryLogBuffer or cpuLogBuffer
    local text = ''
    for i = 1, #logs do
        text = text .. tostring(logs[i]) .. '\n'
    end
    if text == '' then
        text = '暂无日志'
    end
    return text
end

function refreshMonitorPage()
    if monitorPageKind == 'cpu' then
        if monitorStatusLabel then
            monitorStatusLabel:set { text = tostring(cpuLatestText or 'CPU:0%') .. '  ' .. (cpuMonitorEnabled and '检测中' or '已停止') .. '  ' .. (cpuFloatEnabled and '悬浮开' or '悬浮关') }
        end
        if monitorLogArea then monitorLogArea:set { text = monitorLogsToText('cpu') } end
    elseif monitorPageKind == 'memory' then
        if monitorStatusLabel then
            monitorStatusLabel:set { text = tostring(memoryLatestText or 'MEM:0%') .. '  ' .. (memoryMonitorEnabled and '检测中' or '已停止') .. '  ' .. (memoryFloatEnabled and '悬浮开' or '悬浮关') }
        end
        if monitorLogArea then monitorLogArea:set { text = monitorLogsToText('memory') } end
    end
end

function startMonitorPageRefresh(kind)
    monitorPageKind = kind
    refreshMonitorPage()
    pageRefreshTimer = lvgl.Timer({
        period = 800,
        repeat_count = -1,
        cb = function()
            if currentPage == monitorPageKind then refreshMonitorPage() end
        end,
    })
    pageRefreshTimer:resume()
end

function runMonitorPageAction(kind, action)
    if kind == 'cpu' then
        executeCpuMonitorAction(action)
    else
        executeMemoryMonitorAction(action)
    end
    refreshMonitorPage()
end


-- ====== 页面构建（单文件多页面，切页用 root:clean() 重建）======

-- home：表盘页。上半屏居中显示时间；下半屏居中随机一只动态精灵，点击进入 shell
buildHomePage = function()
    stopPageRefreshTimer()
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
    stopPageRefreshTimer()
    currentPage = 'shell'
    logTerminal = nil
    resetLogTap()
    timeLabel = nil
    dateLabel = nil
    weekLabel = nil
    spriteCells = nil
    root:clean()

    makeWideBack(root, function() buildHomePage() end)

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

-- log：Lua 扩展菜单
buildLogPage = function()
    stopPageRefreshTimer()
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

    makeWideBack(root, function() buildShellPage() end)

    lvgl.Label(root, {
        x = 96, y = 14,
        text = '扩展菜单',
        text_font = lvgl.Font("MiSans-Regular", 30),
        text_color = UI_TEXT,
    })

    local _, userUsage = readStorageUsage()
    local storageY = UI_TOPBAR_H + UI_GAP
    local storageH = 148
    local storageCard = lvgl.Object(root, {
        x = UI_GAP, y = storageY,
        w = SCREEN_W - UI_GAP * 2,
        h = storageH,
        bg_color = UI_CARD,
        radius = UI_CARD_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    storageCard:clear_flag(lvgl.FLAG.SCROLLABLE)
    lvgl.Label(storageCard, {
        x = 18, y = 13,
        w = 110, h = 34,
        text = '用户存储',
        text_font = lvgl.Font("MiSans-Regular", 24),
        text_color = UI_TEXT,
    })
    lvgl.Label(storageCard, {
        x = 128, y = 13,
        w = SCREEN_W - UI_GAP * 2 - 146, h = 34,
        text = userUsage,
        text_font = lvgl.Font("MiSans-Regular", 24),
        text_color = UI_TERM_TEXT,
    })
    lvgl.Label(storageCard, {
        x = 18, y = 58,
        w = SCREEN_W - UI_GAP * 2 - 36, h = 76,
        text = '手表用户存储空间>45M、手环用户存储空间>35M可能无法正常使用Shell++',
        text_font = lvgl.Font("MiSans-Regular", 18),
        text_color = UI_TERM_TEXT,
    })

    local actionY = storageY + storageH + UI_GAP
    makeCardButton(root, UI_GAP, actionY, SCREEN_W - UI_GAP * 2, 68, 'CPU占用显示', '检测与悬浮显示', UI_CARD, function() buildCpuMonitorPage() end)
    makeCardButton(root, UI_GAP, actionY + 68 + UI_GAP, SCREEN_W - UI_GAP * 2, 68, '内存占用显示', '检测与悬浮显示', UI_CARD, function() buildMemoryMonitorPage() end)

    local backY = SCREEN_H - UI_GAP - UI_BTN_H
    local backBtnLog = lvgl.Object(root, {
        x = UI_GAP, y = backY,
        w = SCREEN_W - UI_GAP * 2, h = UI_BTN_H,
        bg_color = UI_PRIMARY,
        radius = UI_BTN_RADIUS,
        border_width = 0,
        pad_all = 0,
    })
    backBtnLog:clear_flag(lvgl.FLAG.SCROLLABLE)
    backBtnLog:add_flag(lvgl.FLAG.CLICKABLE)
    local backLblLog = lvgl.Label(backBtnLog, {
        align = lvgl.ALIGN.CENTER,
        text = '返回',
        text_font = lvgl.Font("MiSans-Regular", 28),
        text_color = UI_TEXT,
    })
    backLblLog:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    backBtnLog:onevent(lvgl.EVENT.CLICKED, function() buildShellPage() end)
end

function buildMonitorControlPage(kind, title, color)
    stopPageRefreshTimer()
    currentPage = kind
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

    makeRoundBack(root, function() buildLogPage() end)

    lvgl.Label(root, {
        x = 88, y = 14,
        text = title,
        text_font = lvgl.Font("MiSans-Regular", 30),
        text_color = UI_TEXT,
    })

    monitorStatusLabel = lvgl.Label(root, {
        x = UI_GAP, y = UI_TOPBAR_H + UI_GAP,
        w = SCREEN_W - UI_GAP * 2,
        h = 34,
        text = '',
        text_font = lvgl.Font("MiSans-Regular", 20),
        text_color = color,
    })

    local btnY = UI_TOPBAR_H + UI_GAP + 40
    local btnW = math.floor((SCREEN_W - UI_GAP * 3) / 2)
    local btnH = 48
    makeCardButton(root, UI_GAP, btnY, btnW, btnH, '开始', nil, UI_PRIMARY, function() runMonitorPageAction(kind, 'monitor_start') end)
    makeCardButton(root, UI_GAP * 2 + btnW, btnY, btnW, btnH, '停止', nil, UI_DANGER, function() runMonitorPageAction(kind, 'monitor_stop') end)
    makeCardButton(root, UI_GAP, btnY + btnH + UI_GAP, btnW, btnH, '悬浮开', nil, UI_CARD, function() runMonitorPageAction(kind, 'float_on') end)
    makeCardButton(root, UI_GAP * 2 + btnW, btnY + btnH + UI_GAP, btnW, btnH, '悬浮关', nil, UI_CARD, function() runMonitorPageAction(kind, 'float_off') end)

    local logY = btnY + (btnH + UI_GAP) * 2
    monitorLogArea = lvgl.Textarea(root, {
        x = UI_GAP, y = logY,
        w = SCREEN_W - UI_GAP * 2,
        h = SCREEN_H - logY - UI_GAP,
        text = '',
        bg_color = UI_CARD,
        radius = UI_CARD_RADIUS,
        text_font = lvgl.Font("MiSans-Regular", 18),
        text_color = UI_TERM_TEXT,
        border_width = 0,
        pad_all = 14,
    })
    monitorLogArea:add_flag(lvgl.FLAG.SCROLLABLE)
    startMonitorPageRefresh(kind)
end

buildCpuMonitorPage = function()
    buildMonitorControlPage('cpu', 'CPU占用', '#00ff66')
end

buildMemoryMonitorPage = function()
    buildMonitorControlPage('memory', '内存占用', '#66ccff')
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
