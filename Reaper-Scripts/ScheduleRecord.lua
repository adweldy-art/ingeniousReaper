-- @description Scheduled Recorder - Multi-Schedule (Persistent)
-- @author ingeniousWizard
-- @version 0.1

-- ImGui API compatibility (supports both ImGui_* and ReaImGui_* naming)
local ImGui_CreateContext    = reaper.ImGui_CreateContext    or reaper.ReaImGui_CreateContext
local ImGui_Begin            = reaper.ImGui_Begin            or reaper.ReaImGui_Begin
local ImGui_End              = reaper.ImGui_End              or reaper.ReaImGui_End
local ImGui_BeginChild       = reaper.ImGui_BeginChild       or reaper.ReaImGui_BeginChild
local ImGui_EndChild         = reaper.ImGui_EndChild         or reaper.ReaImGui_EndChild
local ImGui_Combo            = reaper.ImGui_Combo            or reaper.ReaImGui_Combo
local ImGui_InputText        = reaper.ImGui_InputText        or reaper.ReaImGui_InputText
local ImGui_Text             = reaper.ImGui_Text             or reaper.ReaImGui_Text
local ImGui_TextColored      = reaper.ImGui_TextColored      or reaper.ReaImGui_TextColored
local ImGui_SameLine         = reaper.ImGui_SameLine         or reaper.ReaImGui_SameLine
local ImGui_Button           = reaper.ImGui_Button           or reaper.ReaImGui_Button
local ImGui_Separator        = reaper.ImGui_Separator        or reaper.ReaImGui_Separator
local ImGui_Checkbox         = reaper.ImGui_Checkbox         or reaper.ReaImGui_Checkbox
local ImGui_Selectable       = reaper.ImGui_Selectable       or reaper.ReaImGui_Selectable
local ImGui_SetNextItemWidth  = reaper.ImGui_SetNextItemWidth  or reaper.ReaImGui_SetNextItemWidth
local ImGui_SetNextWindowSize       = reaper.ImGui_SetNextWindowSize       or reaper.ReaImGui_SetNextWindowSize
local ImGui_WindowFlags_AlwaysOnTop = reaper.ImGui_WindowFlags_AlwaysOnTop or reaper.ReaImGui_WindowFlags_AlwaysOnTop or function() return 0x0080 end

local has_imgui    = ImGui_CreateContext ~= nil
local has_js_dialog = reaper.JS_Dialog_BrowseForFolder ~= nil
local imgui        = has_imgui and ImGui_CreateContext('Scheduled Recorder') or nil

-- Resolve data file: same folder as this script, .dat extension
local SCRIPT_PATH = debug.getinfo(1, "S").source:match("@(.+)")
local DATA_FILE   = SCRIPT_PATH:gsub("[^/\\]+$", "") .. "ScheduleRecord.dat"
local sep         = package.config:sub(1, 1)

-- Day labels; DAY_DOW maps list index to os.date("%w") value (0=Sun..6=Sat)
local DAY_LABELS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local DAY_DOW    = { 1, 2, 3, 4, 5, 6, 0 }

-- ─── Templates ───────────────────────────────────────────────────────────────
local templates      = {}
local template_names = "None (Default)\0"

local function RefreshTemplates()
    templates      = {}
    template_names = "None (Default)\0"
    local t_dir    = reaper.GetResourcePath() .. sep .. "ProjectTemplates"
    local i = 0
    repeat
        local file = reaper.EnumerateFiles(t_dir, i)
        if file and file:lower():match("%.rpp$") then
            table.insert(templates, t_dir .. sep .. file)
            template_names = template_names .. file .. "\0"
        end
        i = i + 1
    until not file
end
RefreshTemplates()

-- ─── Persistence ─────────────────────────────────────────────────────────────
local function DefaultSchedule()
    return {
        name         = "New Schedule",
        template_idx = 0,
        start_time   = "20:00:00",
        end_time     = "21:00:00",
        proj_name    = "Recording",
        save_path    = "",
        target_date  = os.date("%Y-%m-%d"),
        repeat_days  = { false, false, false, false, false, false, false },
        enabled      = true,
        has_started  = false,
        countdown_active = false,
        countdown_prompted_stamp = "",
        last_start_stamp = "",
        last_cancel_stamp = "",
    }
end

local function SerializeSchedules(scheds)
    local out = { "return {" }
    for _, s in ipairs(scheds) do
        local days = {}
        for _, v in ipairs(s.repeat_days) do days[#days + 1] = v and "true" or "false" end
        out[#out + 1] = string.format(
            '  {name=%q,template_idx=%d,start_time=%q,end_time=%q,' ..
            'proj_name=%q,save_path=%q,target_date=%q,enabled=%s,repeat_days={%s}},',
            s.name, s.template_idx, s.start_time, s.end_time,
            s.proj_name, s.save_path, s.target_date,
            s.enabled and "true" or "false", table.concat(days, ",")
        )
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

local function SaveSchedules(scheds)
    local f = io.open(DATA_FILE, "w")
    if f then f:write(SerializeSchedules(scheds)); f:close() end
end

local function LoadSchedules()
    local f = io.open(DATA_FILE, "r")
    if not f then return {} end
    local src = f:read("*a"); f:close()
    local fn = load(src)
    if not fn then return {} end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then return {} end
    for _, s in ipairs(result) do
        s.has_started = false
        s.countdown_active = false
        s.countdown_prompted_stamp = s.countdown_prompted_stamp or ""
        s.last_start_stamp = s.last_start_stamp or ""
        s.last_cancel_stamp = s.last_cancel_stamp or ""
        if type(s.repeat_days) ~= "table" or #s.repeat_days ~= 7 then
            s.repeat_days = { false, false, false, false, false, false, false }
        end
    end
    return result
end

-- ─── State ───────────────────────────────────────────────────────────────────
local schedules    = LoadSchedules()
local system_armed = false
local sel_idx      = 1
local edit_buf     = nil
local first_frame  = true
local last_save_status = "Loaded schedules from: " .. DATA_FILE
local tick_status           = "Scheduler not started."
local countdown_popup_sched = nil
local countdown_popup_stamp = ""

local function CopySchedule(s)
    local c = {}
    for k, v in pairs(s) do c[k] = v end
    c.repeat_days = {}
    for i, v in ipairs(s.repeat_days) do c.repeat_days[i] = v end
    return c
end

local function SchedulesEqual(a, b)
    if not a or not b then return false end
    local keys = { "name", "template_idx", "start_time", "end_time", "proj_name", "save_path", "target_date", "enabled" }
    for _, k in ipairs(keys) do
        if a[k] ~= b[k] then return false end
    end
    for i = 1, 7 do
        if (a.repeat_days and a.repeat_days[i]) ~= (b.repeat_days and b.repeat_days[i]) then return false end
    end
    return true
end

local function SaveSchedulesWithStatus(scheds)
    local f, err = io.open(DATA_FILE, "w")
    if not f then
        last_save_status = "Save failed: " .. tostring(err)
        return false
    end
    f:write(SerializeSchedules(scheds))
    f:close()
    last_save_status = "Saved at " .. os.date("%H:%M:%S")
    return true
end

local function SelectSchedule(idx)
    sel_idx  = idx
    edit_buf = schedules[idx] and CopySchedule(schedules[idx]) or nil
end

if #schedules > 0 then SelectSchedule(1) end

-- ─── Scheduler engine ────────────────────────────────────────────────────────
local function ParseClockToSeconds(clock)
    local h, m, s = tostring(clock):match("^(%d%d?):(%d%d?):(%d%d?)$")
    if not h then
        h, m = tostring(clock):match("^(%d%d?):(%d%d?)$")
        s = "0"
    end
    h, m, s = tonumber(h), tonumber(m), tonumber(s)
    if not h or not m or not s then return nil end
    if h < 0 or h > 23 or m < 0 or m > 59 or s < 0 or s > 59 then return nil end
    return (h * 3600) + (m * 60) + s
end

local function ScheduleMatchesDay(sched, date_str, dow)
    local any_dow = false
    for _, v in ipairs(sched.repeat_days) do
        if v then any_dow = true; break end
    end
    if any_dow then
        for i, v in ipairs(sched.repeat_days) do
            if v and DAY_DOW[i] == dow then return true end
        end
        return false
    end
    return date_str == sched.target_date
end

local function GetBasePath(sched)
    if sched.save_path and sched.save_path ~= "" then return sched.save_path end
    return reaper.GetResourcePath()
end

local function RunStartSequence(sched)
    local date_str    = os.date("%Y-%m-%d")
    local proj_folder = GetBasePath(sched) .. sep .. sched.proj_name .. "_" .. date_str
    local full_path   = proj_folder .. sep .. sched.proj_name .. "_" .. date_str .. ".rpp"
    local tmpl_path   = (sched.template_idx > 0) and templates[sched.template_idx] or nil

    -- 1. Create session folder before touching REAPER
    reaper.RecursiveCreateDirectory(proj_folder, 0)

    -- 2. Copy the template to the destination path before opening it.
    --    REAPER opens the copy directly -- the original template file is never the active project.
    if tmpl_path then
        local src_f = io.open(tmpl_path, "rb")
        if src_f then
            local content = src_f:read("*a")
            src_f:close()
            local dst_f = io.open(full_path, "wb")
            if dst_f then dst_f:write(content); dst_f:close() end
        end
    end

    -- 3. Open a new tab, then load the copied file (or blank project if no template)
    reaper.Main_OnCommand(41929, 0)  -- New project tab
    reaper.Main_openProject(tmpl_path and full_path or "")

    -- Remember the path so RunStopAndSave knows where to save
    sched.session_proj_path = full_path

    reaper.defer(function()
        local cur_proj = reaper.EnumProjects(-1)
        -- 4. Lock recording path to the session subfolder
        reaper.GetSetProjectInfo_String(cur_proj, "RECORD_PATH", proj_folder, true)
        -- 5. For blank projects (no template), save to the correct path now
        if not tmpl_path then
            reaper.Main_SaveProjectEx(cur_proj, full_path, 0)
        end
        -- 6. Arm all tracks
        for i = 0, reaper.CountTracks(cur_proj) - 1 do
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(cur_proj, i), "I_RECARM", 1)
        end
        -- 7. Start recording
        reaper.Main_OnCommand(1013, 0)
        sched.has_started = true
        sched.countdown_active = false
    end)
end

local function RunStopAndSave(sched)
    reaper.Main_OnCommand(1016, 0)  -- Stop
    local cur_proj = reaper.EnumProjects(-1)

    -- Unarm all tracks
    for i = 0, reaper.CountTracks(cur_proj) - 1 do
        reaper.SetMediaTrackInfo_Value(reaper.GetTrack(cur_proj, i), "I_RECARM", 0)
    end

    -- Final save
    if sched.session_proj_path and sched.session_proj_path ~= "" then
        reaper.Main_SaveProjectEx(cur_proj, sched.session_proj_path, 0)
    else
        reaper.Main_SaveProject(cur_proj, false)
    end

    local end_time = os.date("%H:%M:%S")
    reaper.ShowConsoleMsg(string.format(
        "\n[Scheduled Recorder] '%s' recording complete at %s.\nSaved to: %s\n",
        sched.name, end_time, tostring(sched.session_proj_path or "(default location)")))

    sched.has_started = false
    sched.session_proj_path = nil
    if countdown_popup_sched == sched then countdown_popup_sched = nil end
end

local function TickScheduler()
    if not system_armed then
        tick_status = "Scheduler not armed."
        return
    end
    if #schedules == 0 then
        tick_status = "No schedules loaded."
        return
    end

    local now_clock = os.date("%H:%M:%S")
    local now_sec   = ParseClockToSeconds(now_clock)
    if not now_sec then
        tick_status = "ERROR: clock parse failed: " .. tostring(now_clock)
        return
    end

    local d   = os.date("%Y-%m-%d")
    local dow = tonumber(os.date("%w")) or -1

    for _, sched in ipairs(schedules) do
        if not sched.enabled then
            tick_status = "[" .. sched.name .. "] DISABLED"
        else
            local start_sec = ParseClockToSeconds(sched.start_time)
            local end_sec   = ParseClockToSeconds(sched.end_time)
            local day_ok    = ScheduleMatchesDay(sched, d, dow)

            if not start_sec then
                tick_status = "[" .. sched.name .. "] ERR: bad start_time: " .. tostring(sched.start_time)
            elseif not end_sec then
                tick_status = "[" .. sched.name .. "] ERR: bad end_time: " .. tostring(sched.end_time)
            elseif not day_ok then
                tick_status = string.format("[%s] WAITING: today=%s(dow=%d) target_date=%s",
                    sched.name, d, dow, tostring(sched.target_date))
            else
                local secs_left = start_sec - now_sec
                local stamp     = d .. "|" .. sched.start_time

                if sched.has_started then
                    tick_status = string.format("[%s] RECORDING | %.0fs to stop", sched.name, end_sec - now_sec)
                    if now_sec >= end_sec then
                        RunStopAndSave(sched)
                    end
                elseif secs_left <= 0
                    and sched.last_start_stamp ~= stamp
                    and sched.last_cancel_stamp ~= stamp then
                    tick_status = "[" .. sched.name .. "] FIRING START SEQUENCE"
                    RunStartSequence(sched)
                    sched.last_start_stamp = stamp
                elseif secs_left > 0 and secs_left <= 30
                    and sched.last_cancel_stamp ~= stamp
                    and sched.countdown_prompted_stamp ~= stamp then
                    sched.countdown_active = true
                    sched.countdown_prompted_stamp = stamp
                    tick_status = string.format("[%s] COUNTDOWN: %.0fs to start", sched.name, secs_left)
                    if not countdown_popup_sched then
                        countdown_popup_sched = sched
                        countdown_popup_stamp = stamp
                    end
                elseif sched.last_start_stamp == stamp then
                    tick_status = string.format("[%s] already fired this occurrence", sched.name)
                elseif sched.last_cancel_stamp == stamp then
                    tick_status = string.format("[%s] CANCELLED for this occurrence", sched.name)
                else
                    tick_status = string.format("[%s] ARMED | %.0fs to start | %s -> %s",
                        sched.name, secs_left, sched.start_time, sched.end_time)
                end
            end
        end
    end
end

-- ─── UI ──────────────────────────────────────────────────────────────────────
local function DrawScheduleList()
    ImGui_BeginChild(imgui, "##list", 190, 0)
    for i, s in ipairs(schedules) do
        local label   = (s.enabled and "[ON]  " or "[OFF] ") .. s.name
        local clicked = ImGui_Selectable(imgui, label, i == sel_idx)
        if clicked then SelectSchedule(i) end
    end
    ImGui_Separator(imgui)
    if ImGui_Button(imgui, "Add", 88, 0) then
        table.insert(schedules, DefaultSchedule())
        SelectSchedule(#schedules)
        SaveSchedulesWithStatus(schedules)
    end
    ImGui_SameLine(imgui)
    if ImGui_Button(imgui, "Delete", 88, 0) and #schedules > 0 then
        local name    = schedules[sel_idx] and schedules[sel_idx].name or ""
        local confirm = reaper.ShowMessageBox("Delete '" .. name .. "'?", "Confirm", 4)
        if confirm == 6 then
            table.remove(schedules, sel_idx)
            sel_idx = math.max(1, math.min(sel_idx, #schedules))
            SelectSchedule(sel_idx)
            SaveSchedulesWithStatus(schedules)
        end
    end
    ImGui_EndChild(imgui)
end

local function DrawEditForm()
    if not edit_buf then
        ImGui_Text(imgui, "No schedule. Click Add.")
        return
    end

    ImGui_Text(imgui, "Name:")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, nm = ImGui_InputText(imgui, "##name", edit_buf.name)
    edit_buf.name = nm

    ImGui_Text(imgui, "Template:")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, ti = ImGui_Combo(imgui, "##tmpl", edit_buf.template_idx, template_names)
    edit_buf.template_idx = ti

    ImGui_Text(imgui, "Start (HH:MM:SS):")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, st = ImGui_InputText(imgui, "##start", edit_buf.start_time)
    edit_buf.start_time = st

    ImGui_Text(imgui, "End (HH:MM:SS):")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, et = ImGui_InputText(imgui, "##end", edit_buf.end_time)
    edit_buf.end_time = et

    ImGui_Text(imgui, "Project Name:")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, pn = ImGui_InputText(imgui, "##pname", edit_buf.proj_name)
    edit_buf.proj_name = pn

    ImGui_Text(imgui, "Save Folder:")
    ImGui_SetNextItemWidth(imgui, has_js_dialog and -46 or -1)
    local _, sp = ImGui_InputText(imgui, "##spath", edit_buf.save_path)
    edit_buf.save_path = sp
    if has_js_dialog then
        ImGui_SameLine(imgui)
        if ImGui_Button(imgui, "...", 40, 0) then
            local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Folder", "")
            if ok then edit_buf.save_path = folder end
        end
    end

    ImGui_Separator(imgui)

    local any_dow = false
    for _, v in ipairs(edit_buf.repeat_days) do if v then any_dow = true; break end end

    ImGui_Text(imgui, any_dow and "Date: (ignored - DOW mode active)" or "Date (YYYY-MM-DD):")
    ImGui_SetNextItemWidth(imgui, -1)
    local _, td = ImGui_InputText(imgui, "##date", edit_buf.target_date)
    if not any_dow then edit_buf.target_date = td end

    ImGui_Text(imgui, "Repeat on:")
    for i, label in ipairs(DAY_LABELS) do
        local _, checked = ImGui_Checkbox(imgui, label, edit_buf.repeat_days[i])
        edit_buf.repeat_days[i] = checked
        if i < #DAY_LABELS then ImGui_SameLine(imgui) end
    end

    ImGui_Separator(imgui)
    local _, en = ImGui_Checkbox(imgui, "Enabled", edit_buf.enabled)
    edit_buf.enabled = en

    ImGui_Separator(imgui)
    if schedules[sel_idx] and not SchedulesEqual(edit_buf, schedules[sel_idx]) then
        ImGui_TextColored(imgui, 0xFFA500FF, "Unsaved changes")
    else
        ImGui_Text(imgui, "No unsaved changes")
    end
    ImGui_Text(imgui, last_save_status)
    if ImGui_Button(imgui, "Save Changes", -1, 0) then
        schedules[sel_idx]             = CopySchedule(edit_buf)
        schedules[sel_idx].has_started = false
        schedules[sel_idx].countdown_prompted_stamp = ""
        SaveSchedulesWithStatus(schedules)
    end
end

function loop()
    if not has_imgui then
        reaper.ShowMessageBox(
            "ImGui API unavailable. Install ReaImGui and restart.",
            "Scheduled Recorder", 0)
        return
    end

    -- Run scheduler before opening an ImGui frame because countdown alerts use modal dialogs.
    TickScheduler()

    if first_frame and ImGui_SetNextWindowSize then
        ImGui_SetNextWindowSize(imgui, 620, 440, 8)  -- 8 = FirstUseEver
        first_frame = false
    end

    local visible, open = ImGui_Begin(imgui, 'Scheduled Recorder', true)
    if visible then
        local now = os.date("%H:%M:%S")
        if system_armed then
            ImGui_TextColored(imgui, 0x00FF00FF, "SCHEDULER ACTIVE  " .. now)
        else
            ImGui_Text(imgui, "Scheduler Idle   " .. now)
        end
        ImGui_Text(imgui, "Tracks are armed at start time only, just before recording begins.")
        ImGui_TextColored(imgui, 0xAAFFAAFF, tick_status)
        ImGui_Text(imgui, last_save_status)
        ImGui_Separator(imgui)

        DrawScheduleList()
        ImGui_SameLine(imgui)
        ImGui_BeginChild(imgui, "##edit", 0, 0)
        DrawEditForm()
        ImGui_EndChild(imgui)

        ImGui_Separator(imgui)
        if not system_armed then
            if ImGui_Button(imgui, "START SCHEDULER", -1, 30) then
                if edit_buf and schedules[sel_idx] then
                    schedules[sel_idx] = CopySchedule(edit_buf)
                    schedules[sel_idx].has_started = false
                    schedules[sel_idx].countdown_active = false
                    schedules[sel_idx].countdown_prompted_stamp = ""
                    SaveSchedulesWithStatus(schedules)
                end
                system_armed = true
            end
        else
            if ImGui_Button(imgui, "STOP SCHEDULER", -1, 30) then
                system_armed = false
                for _, s in ipairs(schedules) do
                    s.has_started = false
                    s.countdown_active = false
                    s.countdown_prompted_stamp = ""
                end
            end
        end

        ImGui_End(imgui)
    end

    -- Standalone always-on-top countdown alert (visible even when main window is behind other apps)
    if countdown_popup_sched then
        local s = countdown_popup_sched
        if s.has_started then
            countdown_popup_sched = nil  -- auto-dismiss once recording begins
        else
            local ns  = ParseClockToSeconds(os.date("%H:%M:%S"))
            local ss  = ParseClockToSeconds(s.start_time)
            local rem = (ns and ss) and math.max(0, ss - ns) or 0
            ImGui_SetNextWindowSize(imgui, 370, 115, 8)  -- 8 = FirstUseEver
            local alert_vis, alert_open = ImGui_Begin(imgui, "!! Recording Alert !!", true,
                ImGui_WindowFlags_AlwaysOnTop())
            if alert_vis then
                ImGui_TextColored(imgui, 0xFF4444FF, string.format("UPCOMING: '%s'", s.name))
                ImGui_Text(imgui, string.format(
                    "Recording starts in %.0f seconds at %s", rem, s.start_time))
                ImGui_Separator(imgui)
                if ImGui_Button(imgui, "OK  (dismiss)", 165, 0) then
                    countdown_popup_sched = nil
                end
                ImGui_SameLine(imgui)
                if ImGui_Button(imgui, "Cancel recording", 155, 0) then
                    s.last_cancel_stamp   = countdown_popup_stamp
                    s.countdown_active    = false
                    countdown_popup_sched = nil
                end
                ImGui_End(imgui)
            end
            if alert_open == false then
                countdown_popup_sched = nil  -- user closed via X = dismiss (not cancel)
            end
        end
    end

    -- Some ReaImGui variants return nil for `open`; keep running unless explicitly false.
    if open ~= false then reaper.defer(loop) end
end

reaper.defer(loop)