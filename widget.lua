--[[
    widget.lua -- conky-cores

    A companion to conky-system-redone-v2, in the same liquid-glass Lua/
    Cairo style, focused entirely on per-core CPU detail: one small line
    graph + load% + frequency per core, laid out two-per-row (the same
    side-by-side pairing conky-system-redone-v2 uses for its Up/Down
    network graphs), with as many rows as needed for however many cores
    this machine actually has -- detected once at startup via `nproc`,
    not hardcoded.
--]]

pcall(require, "cairo")

-- Portable drawing-surface helper: prefer conky_surface() (X11 + Wayland),
-- fall back to cairo_xlib_surface_create for builds without it.
-- luacheck: ignore cairo_xlib
local has_cairo_xlib, cairo_xlib = pcall(require, "cairo_xlib")
if not has_cairo_xlib then
    cairo_xlib = setmetatable({}, {
        __index = function(_, k) return _G[k] end,
    })
end

local function get_draw_surface()
    if conky_surface then
        local s = conky_surface()
        if s then return s, false end
    end
    if conky_window and cairo_xlib_surface_create then
        local s = cairo_xlib_surface_create(conky_window.display,
            conky_window.drawable, conky_window.visual,
            conky_window.width, conky_window.height)
        return s, true
    end
    return nil, false
end

-- ==================== config ====================

local CFG = {
    font = "DejaVu Sans Mono",
    margin = 14,      -- outer margin, left/right
    top_margin = 14,
    pad = 10,         -- inner padding per box
    gap = 10,         -- vertical gap between boxes
    corner_radius = 10,

    -- How many core cells sit side by side per row -- 2 matches
    -- conky-system-redone-v2's Up/Down graph pairing. 3 or 4 also work
    -- fine on a wide enough window if you have a lot of cores and want
    -- a shorter, wider window instead of a tall one.
    cores_per_row = 2,

    -- How many samples of history each core's graph keeps (one push per
    -- conky update). 60 samples at the default 1s update_interval is a
    -- 1-minute rolling window per core.
    graph_history_length = 60,

    -- Draws a bright border around the FULL conky window plus a
    -- canvas-size-vs-content-height readout -- the same sizing aid from
    -- conky-system-redone-v2, useful here since the ideal window height
    -- depends entirely on how many cores your CPU has. Off by default.
    debug_show_canvas = false,

    -- Where the content block sits vertically inside the conky window:
    -- "top" (starts at CFG.top_margin), "middle" (centers against the
    -- window's actual height, recomputed every frame), or a fixed pixel
    -- number (a quoted numeric string like "60" also works).
    vertical_align = "top",

    -- Layer 1 is the base glass fill behind every box.
    glass_base_color = 0x08081A,
    glass_base_alpha = 0.35,

    colors = {
        text    = 0xDCE142, -- yellow
        accent1 = 0xE7660B, -- orange
        accent2 = 0xDCE142, -- yellow
        accent3 = 0x42E147, -- green
        danger  = 0xFF3B30, -- red, used above 90% load
    },
}

-- ==================== generic helpers ====================

-- Division-based hex->rgb (no bitwise ops, works on Lua 5.1 and 5.3+)
local function hex_to_rgb(hex)
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    return r / 255, g / 255, b / 255
end

local function hex_to_rgba(hex, alpha)
    local r, g, b = hex_to_rgb(hex)
    return r, g, b, alpha
end

local function shell(cmd)
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a")
    h:close()
    if out then out = out:gsub("%s+$", "") end
    return out
end

-- locale-safe: treat "," as a decimal point rather than letting tonumber()
-- silently return nil on a comma-decimal locale.
local function num(s)
    if s == nil then return 0 end
    return tonumber((tostring(s):gsub(",", "."))) or 0
end

-- ==================== core detection ====================

-- `nproc` reports the number of LOGICAL cpus -- with hyperthreading/SMT
-- enabled, that's the thread count, not the physical core count (e.g. a
-- 4-core/8-thread CPU like the i5-1135G7 reports 8 here). This is what
-- the per-row grid below actually iterates over, since conky's own
-- ${cpu cpuN}/${freq_g N} report per LOGICAL cpu too -- so NUM_THREADS is
-- the right count for "how many rows do we draw", one per schedulable
-- logical cpu. Falls back to 4 if `nproc` isn't available for some reason.
local NUM_THREADS = tonumber(shell("nproc")) or 4

-- Physical core count, purely for the header readout (so it can say
-- "4 Cores / 8 Threads" instead of calling threads "cores" when SMT is
-- on). Counts unique (Core, Socket) pairs from lscpu's parseable output,
-- which is correct even on multi-socket systems. Falls back to
-- NUM_THREADS (i.e. the header just won't show a separate count) if
-- `lscpu` isn't available.
local PHYSICAL_CORES = tonumber(shell(
    "lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l"
))
if not PHYSICAL_CORES or PHYSICAL_CORES < 1 then PHYSICAL_CORES = NUM_THREADS end

-- Maps each logical cpu (conky's 1-based cpuN index) to a "Core X -
-- Thread Y" label, built once at startup from the same lscpu data as
-- PHYSICAL_CORES above (CPU,Core,Socket per logical cpu). Threads
-- sharing a physical core (SMT/hyperthreading) get the same Core number
-- and increasing Thread numbers, in the order lscpu lists them -- this
-- is what actually shows the physical-core grouping (e.g. "Core 3 -
-- Thread 1" and "Core 3 - Thread 2" both being the SAME physical core)
-- instead of implying every row is an independent core. On a CPU with
-- no SMT, a core has only one thread, so the label just says "Core X"
-- with no thread suffix at all. Falls back to an empty table (each row
-- then just shows "CPU N-1", see draw_core_cell) if lscpu isn't available.
local THREAD_LABEL = {}

-- The grid order the cells get drawn in -- NOT conky's raw 1..NUM_THREADS
-- cpu-index order. Grouped per physical core instead (all of Core 0's
-- threads consecutively, then all of Core 1's, ...), so that with
-- CFG.cores_per_row = 2, each row is one physical core's own threads
-- side by side (e.g. "Core 3 - Thread 1" next to "Core 3 - Thread 2"),
-- rather than pairing up whichever cpu numbers happen to fall in the
-- same row of the raw index order. Falls back to plain 1..NUM_THREADS
-- (built after NUM_THREADS is known, see below) if lscpu isn't available.
local DISPLAY_ORDER = nil

do
    local lscpu_out = shell("lscpu -p=CPU,Core,Socket 2>/dev/null")
    if lscpu_out and lscpu_out ~= "" then
        local core_order = {}    -- ordered list of unique "core,socket" keys
        local core_index = {}    -- "core,socket" key -> display core number (0-based)
        local cpus_per_core = {} -- "core,socket" key -> ordered list of conky cpu numbers (1-based)
        for line in lscpu_out:gmatch("[^\n]+") do
            if not line:match("^#") then
                local cpu, core, socket = line:match("^(%d+),(%d+),(%d+)")
                if cpu then
                    local key = core .. "," .. socket
                    if core_index[key] == nil then
                        core_index[key] = #core_order
                        core_order[#core_order + 1] = key
                        cpus_per_core[key] = {}
                    end
                    -- lscpu's CPU column is 0-based; conky's cpuN is 1-based
                    table.insert(cpus_per_core[key], tonumber(cpu) + 1)
                end
            end
        end
        DISPLAY_ORDER = {}
        for _, key in ipairs(core_order) do
            local cnum = core_index[key]
            local cpus = cpus_per_core[key]
            if #cpus == 1 then
                THREAD_LABEL[cpus[1]] = "Core " .. cnum
            else
                for t, cpu1 in ipairs(cpus) do
                    THREAD_LABEL[cpu1] = "Core " .. cnum .. " - Thread " .. t
                end
            end
            for _, cpu1 in ipairs(cpus) do
                DISPLAY_ORDER[#DISPLAY_ORDER + 1] = cpu1
            end
        end
    end
end

-- Fall back to plain conky cpu-index order (1, 2, 3, ... NUM_THREADS) if
-- lscpu wasn't available above (DISPLAY_ORDER is still nil), OR if lscpu
-- WAS available but disagreed with nproc on how many cpus there are
-- (e.g. inside a cgroup/container with a CPU-affinity limit -- nproc
-- respects that restriction while lscpu -p may not). Better a plain
-- sequential grid than one built from a mismatched cpu list, which could
-- pair up or drop the wrong rows entirely.
if DISPLAY_ORDER == nil or #DISPLAY_ORDER ~= NUM_THREADS then
    DISPLAY_ORDER = {}
    THREAD_LABEL = {}
    for i = 1, NUM_THREADS do DISPLAY_ORDER[i] = i end
end

-- Cosmetic only (shown in the header box) -- if this fails for any reason
-- the header just omits the model line.
local CPU_MODEL = shell("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'")

-- One rolling history buffer per thread, indexed 1..NUM_THREADS to match
-- conky's own 1-based cpuN/freq_g N numbering.
local core_hist = {}
for i = 1, NUM_THREADS do core_hist[i] = {} end

local function push_value(buffer, maxlen, value)
    table.insert(buffer, value)
    if #buffer > maxlen then table.remove(buffer, 1) end
end

-- ==================== drawing helpers ====================

local function draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_move_to(cr, x + r, y)
    cairo_line_to(cr, x + w - r, y)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_line_to(cr, x + w, y + h - r)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_line_to(cr, x + r, y + h)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_line_to(cr, x, y + r)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

-- Multi-layer liquid-glass box, ported verbatim from
-- conky-system-redone-v2's own widget.lua: base body, vertical top/bottom
-- reflections, a horizontal left highlight, a top specular gloss (scaled
-- to this box's own height), a subtle inner glow, and a gradient border.
local function draw_glass_box(cr, x, y, w, h)
    local r = CFG.corner_radius

    -- Layer 1: base glass body (configurable, see CFG.glass_base_color/alpha)
    cairo_set_source_rgba(cr, hex_to_rgba(CFG.glass_base_color, CFG.glass_base_alpha))
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_fill(cr)

    cairo_save(cr)
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_clip(cr)

    -- Layer 2: vertical gradient -- reflections top and bottom
    local g2 = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(g2, 0.00, hex_to_rgba(0xFFFFFF, 0.30))
    cairo_pattern_add_color_stop_rgba(g2, 0.06, hex_to_rgba(0xDDEEFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 0.15, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.45, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.55, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.85, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.94, hex_to_rgba(0xCCDDFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 1.00, hex_to_rgba(0xFFFFFF, 0.28))
    cairo_set_source(cr, g2)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g2)

    -- Layer 3: horizontal highlight, light from the left
    local g3 = cairo_pattern_create_linear(x, y, x + w, y)
    cairo_pattern_add_color_stop_rgba(g3, 0.00, hex_to_rgba(0xFFFFFF, 0.32))
    cairo_pattern_add_color_stop_rgba(g3, 0.08, hex_to_rgba(0xEEF4FF, 0.16))
    cairo_pattern_add_color_stop_rgba(g3, 0.20, hex_to_rgba(0xCCDDFF, 0.05))
    cairo_pattern_add_color_stop_rgba(g3, 0.50, hex_to_rgba(0x000000, 0.0))
    cairo_pattern_add_color_stop_rgba(g3, 0.80, hex_to_rgba(0x8899CC, 0.03))
    cairo_pattern_add_color_stop_rgba(g3, 0.92, hex_to_rgba(0xAABBEE, 0.08))
    cairo_pattern_add_color_stop_rgba(g3, 1.00, hex_to_rgba(0xFFFFFF, 0.18))
    cairo_set_source(cr, g3)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g3)

    -- Layer 4: specular top gloss, height proportional to this box
    local spec_h = math.min(h * 0.35, 55)
    local g4 = cairo_pattern_create_linear(x, y, x, y + spec_h)
    cairo_pattern_add_color_stop_rgba(g4, 0.00, hex_to_rgba(0xFFFFFF, 0.38))
    cairo_pattern_add_color_stop_rgba(g4, 0.25, hex_to_rgba(0xEEF4FF, 0.18))
    cairo_pattern_add_color_stop_rgba(g4, 0.60, hex_to_rgba(0xFFFFFF, 0.04))
    cairo_pattern_add_color_stop_rgba(g4, 1.00, hex_to_rgba(0xFFFFFF, 0.0))
    cairo_set_source(cr, g4)
    cairo_rectangle(cr, x, y, w, spec_h)
    cairo_fill(cr)
    cairo_pattern_destroy(g4)

    -- Layer 5: subtle inner blue glow, inset horizontally
    local inset = math.min(10, w * 0.1)
    local g5 = cairo_pattern_create_linear(x + inset, y, x + w - inset, y)
    cairo_pattern_add_color_stop_rgba(g5, 0.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_pattern_add_color_stop_rgba(g5, 0.30, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 0.50, hex_to_rgba(0x3344CC, 0.10))
    cairo_pattern_add_color_stop_rgba(g5, 0.70, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 1.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_set_source(cr, g5)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g5)

    cairo_restore(cr) -- lift the clip before stroking the border

    -- Border: vertical white/blue gradient with sharp top & bottom edges
    local gb = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(gb, 0.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_pattern_add_color_stop_rgba(gb, 0.10, hex_to_rgba(0xFFFFFF, 0.90))
    cairo_pattern_add_color_stop_rgba(gb, 0.30, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.50, hex_to_rgba(0x8899EE, 0.25))
    cairo_pattern_add_color_stop_rgba(gb, 0.70, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.90, hex_to_rgba(0xFFFFFF, 0.85))
    cairo_pattern_add_color_stop_rgba(gb, 1.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_set_source(cr, gb)
    cairo_set_line_width(cr, 1.0)
    draw_rounded_rect_path(cr, x + 0.5, y + 0.5, w - 1, h - 1, r)
    cairo_stroke(cr)
    cairo_pattern_destroy(gb)
end

local function draw_text(cr, x, y, text, size, color_hex, alpha, bold, align)
    cairo_select_font_face(cr, CFG.font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local rr, gg, bb = hex_to_rgb(color_hex)
    cairo_set_source_rgba(cr, rr, gg, bb, alpha or 1)

    local tx = x
    if align == "center" or align == "right" then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, text, ext)
        tx = (align == "center") and (x - ext.width / 2) or (x - ext.width)
    end
    cairo_move_to(cr, tx, y)
    cairo_show_text(cr, text)
end

-- Mini graph styled like graphs.lua (filled area gradient + border line).
-- Deliberately always the same fixed red(top)/green(bottom) "VU meter"
-- gradient regardless of the current reading -- so there's no
-- `color_hex` parameter here to wire up: a per-call colour would only
-- ever apply to the single-sample dot fallback below, creating a jarring
-- colour jump the moment the second sample arrives and the real gradient
-- takes over.
local function draw_mini_graph(cr, x, y, w, h, values, max)
    local n = #values
    if n < 1 then return end
    max = math.max(max, 1)
    local step = w / (CFG.graph_history_length - 1)

    cairo_save(cr)
    cairo_rectangle(cr, x, y, w, h)
    cairo_clip(cr)
    cairo_translate(cr, x, y + h)
    cairo_scale(cr, 1, -1)

    if n == 1 then
        -- Not enough history yet for a line -- draw a single dot in the
        -- gradient's own bottom-of-scale colour (bright green) so there's
        -- no jarring colour jump once the second sample arrives.
        local v0 = math.min(values[1], max)
        cairo_set_source_rgba(cr, hex_to_rgba(0x00FF00, 0.9))
        cairo_arc(cr, 0, (v0 / max) * h, 1.5, 0, 2 * math.pi)
        cairo_fill(cr)
        cairo_restore(cr)
        return
    end

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)

    -- 1. Draw the filled area (Foreground Area Gradient)
    local fg_pat = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(fg_pat, 1.0, hex_to_rgba(0xFF2021, 1.0)) -- Red at the top
    cairo_pattern_add_color_stop_rgba(fg_pat, 0.5, hex_to_rgba(0x006600, 0.5)) -- Dark green in the middle
    cairo_pattern_add_color_stop_rgba(fg_pat, 0.0, hex_to_rgba(0x00FF00, 0.5)) -- Bright green at the bottom

    cairo_move_to(cr, 0, 0)
    for i = 1, n do
        local v = math.min(values[i], max)
        cairo_line_to(cr, (i - 1) * step, (v / max) * h)
    end
    cairo_line_to(cr, (n - 1) * step, 0)
    cairo_close_path(cr)

    cairo_set_source(cr, fg_pat)
    cairo_fill(cr)
    cairo_pattern_destroy(fg_pat)

    -- 2. Draw the top line/border (Foreground Border Gradient)
    local bd_pat = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(bd_pat, 1.0, hex_to_rgba(0xFF0000, 1.0))  -- Red at the top
    cairo_pattern_add_color_stop_rgba(bd_pat, 0.34, hex_to_rgba(0x006600, 1.0)) -- Dark green in the middle
    cairo_pattern_add_color_stop_rgba(bd_pat, 0.0, hex_to_rgba(0x00FF00, 1.0))  -- Bright green at the bottom

    local v0 = math.min(values[1], max)
    cairo_move_to(cr, 0, (v0 / max) * h)
    for i = 2, n do
        local v = math.min(values[i], max)
        cairo_line_to(cr, (i - 1) * step, (v / max) * h)
    end

    cairo_set_source(cr, bd_pat)
    cairo_set_line_width(cr, 1.5) -- Overeenkomstig met fg_bd_size
    cairo_stroke(cr)
    cairo_pattern_destroy(bd_pat)

    cairo_restore(cr)
end

-- Green below 70%, yellow below 90%, red above -- the same VU-meter
-- language used throughout conky-system-redone-v2.
local function load_color(pct)
    if pct < 70 then return CFG.colors.accent3
    elseif pct < 90 then return CFG.colors.accent2
    else return CFG.colors.danger end
end

-- ==================== panels ====================

local function draw_header(cr, x, y, w, h)
    draw_text(cr, x, y + 14, "CPU Cores", 14, CFG.colors.accent1, 1, true)
    local subtitle
    if PHYSICAL_CORES == NUM_THREADS then
        subtitle = NUM_THREADS .. (NUM_THREADS == 1 and " Core" or " Cores")
    else
        subtitle = PHYSICAL_CORES .. (PHYSICAL_CORES == 1 and " Core / " or " Cores / ")
            .. NUM_THREADS .. (NUM_THREADS == 1 and " Thread" or " Threads")
    end
    draw_text(cr, x + w, y + 14, subtitle, 11, CFG.colors.text, 0.7, false, "right")
    if CPU_MODEL and CPU_MODEL ~= "" then
        draw_text(cr, x, y + 32, CPU_MODEL, 10, CFG.colors.text, 0.75)
    end
end

-- One thread's (logical cpu's) label + graph, drawn in a (x,y,w,h) cell.
-- `core_num` is 1-based (conky's own cpuN/freq_g N numbering). Two text
-- lines: the Core/Thread label on its own (it's the longest string here,
-- see the width check that motivated splitting it out -- "Core 3 -
-- Thread 2" alone fits a ~145px column comfortably, but doesn't leave
-- room for frequency on the same line, let alone with double-digit core
-- numbers), then frequency + load% together on the line below.
local function draw_core_cell(cr, x, y, w, h, core_num)
    local load = num(conky_parse("${cpu cpu" .. core_num .. "}"))
    local freq = conky_parse("${freq_g " .. core_num .. "}")
    push_value(core_hist[core_num], CFG.graph_history_length, load)

    local label = THREAD_LABEL[core_num] or ("CPU " .. (core_num - 1))
    local col = load_color(load)

    draw_text(cr, x, y + 8, label, 10, CFG.colors.text, 0.9)
    if freq and freq ~= "" and freq ~= "0.00" then
        draw_text(cr, x, y + 22, freq .. "GHz", 10, CFG.colors.text, 0.75)
    end
    draw_text(cr, x + w, y + 22, string.format("%.0f%%", load), 10, col, 1, true, "right")
    draw_mini_graph(cr, x, y + 28, w, h - 28, core_hist[core_num], 100)
end

local function cores_grid_rows()
    return math.ceil(NUM_THREADS / CFG.cores_per_row)
end

-- Height needed for the cores grid alone (no box padding) -- exposed
-- separately from draw_cores() so the layout below can size the box
-- correctly before anything is drawn.
-- ROW_H = label line (Core/Thread) + freq/pct line + graph -- 14px taller
-- than before to make room for the extra Core/Thread label line.
local ROW_H = 64
local ROW_GAP = 15
local function cores_grid_height()
    local rows = cores_grid_rows()
    return (rows * ROW_H) + ((rows - 1) * ROW_GAP) + (CFG.pad * 2)
end

local function draw_cores(cr, x, y, w, h)
    local cols = CFG.cores_per_row
    local col_gap = 12
    local col_w = (w - (cols - 1) * col_gap) / cols

    for i, core_num in ipairs(DISPLAY_ORDER) do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local cx = x + col * (col_w + col_gap)
        local cy = y + row * (ROW_H + ROW_GAP)
        draw_core_cell(cr, cx, cy, col_w, ROW_H, core_num)
    end
end

-- ==================== layout ====================

local HEADER_H = CPU_MODEL and CPU_MODEL ~= "" and 50 or 34

local SECTIONS = {
    { height = HEADER_H, draw = draw_header },
    { height = function() return cores_grid_height() end, draw = draw_cores },
}

local function sec_h(sec)
    return type(sec.height) == "function" and sec.height() or sec.height
end

local function total_content_height()
    local total = 0
    for i, sec in ipairs(SECTIONS) do
        if i > 1 then total = total + CFG.gap end
        total = total + sec_h(sec)
    end
    return total
end

local function draw_canvas_debug_overlay(cr, canvas_w, canvas_h, content_h)
    cairo_save(cr)
    cairo_set_source_rgba(cr, 1, 0, 1, 0.9)
    cairo_set_line_width(cr, 2)
    cairo_rectangle(cr, 1, 1, canvas_w - 2, canvas_h - 2)
    cairo_stroke(cr)
    cairo_restore(cr)

    local needed = math.ceil(content_h + 2 * CFG.top_margin)
    local fits = needed <= canvas_h
    local msg = string.format("canvas %dx%d | %d threads | content needs ~%dpx tall | %s",
        canvas_w, canvas_h, NUM_THREADS, needed,
        fits and "fits" or ("SHORT by " .. (needed - canvas_h) .. "px"))
    draw_text(cr, 4, canvas_h - 6, msg, 9, fits and CFG.colors.accent3 or CFG.colors.danger, 1, true)
end

local function draw_all(cr, canvas_w, canvas_h)
    local x = CFG.margin
    local w = canvas_w - 2 * CFG.margin
    local content_h = total_content_height()

    local align_num = tonumber(CFG.vertical_align)
    local y

    if CFG.vertical_align == "middle" then
        y = (canvas_h - content_h) / 2
    elseif align_num then
        -- Vang af dat max_y niet negatief wordt als de inhoud te hoog is
        local max_y = math.max(0, canvas_h - content_h)
        y = math.max(0, math.min(align_num, max_y))
    else
        y = CFG.top_margin or 0
    end

    for _, sec in ipairs(SECTIONS) do
        local h = sec_h(sec)
        draw_glass_box(cr, x, y, w, h)
        sec.draw(cr, x + CFG.pad, y + CFG.pad, w - 2 * CFG.pad, h - 2 * CFG.pad)
        y = y + h + CFG.gap
    end

    if CFG.debug_show_canvas then
        draw_canvas_debug_overlay(cr, canvas_w, canvas_h, content_h)
    end
end

-- ==================== Conky hook ====================

function conky_main()
    local surface, owns_surface = get_draw_surface()
    if not surface then return end
    local cr = cairo_create(surface)

    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
    cairo_paint(cr)
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

    local ok, err = pcall(draw_all, cr,
        conky_window and conky_window.width or 340,
        conky_window and conky_window.height or 500)
    if not ok then
        io.stderr:write("conky-cores widget.lua draw error: " .. tostring(err) .. "\n")
    end

    cairo_destroy(cr)
    if owns_surface then
        cairo_surface_destroy(surface)
    end
end