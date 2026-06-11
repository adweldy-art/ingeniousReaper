-- @description IGR Parameter Grid Configurator (ReaImGui)
-- @version 0.2
-- @author ingeniousWizard
-- @about
--   Interactive UI for setting up parameter-grid capture runs.
--   Configure DUT, select parameters, set grid ranges, and launch capture.
--   Requires ReaImGui extension.

if not reaper.ImGui_CreateContext then
  reaper.MB(
    "ReaImGui is not available.\n\nInstall ReaImGui from ReaPack, then run this script again.",
    "IGR Configurator",
    0
  )
  return
end

local function script_dir()
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  src = src:gsub("^@", "")
  return src:match("^(.*[\\/])") or ""
end

local BASE_DIR = script_dir()
local CAPTURE_PATH = BASE_DIR .. "CapturePluginParameterGrid.lua"
local EXT_SECTION = "IGR_PARAM_CAPTURE"

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function ext_set(key, value)
  reaper.SetExtState(EXT_SECTION, key, tostring(value or ""), false)
end

local function ext_get(key, default)
  local v = reaper.GetExtState(EXT_SECTION, key)
  if v == nil or v == "" then return default end
  return v
end

local ctx = reaper.ImGui_CreateContext("IGR Parameter Grid Configurator")
local visible = true

-- State
local tracks = {}
local track_names = {}
local selected_track_idx = 0
local selected_fx_idx = 0
local fx_list = {}
local param_info = {}
local param_checked = {}
local param_configs = {}

local signal_type = 0  -- 0=sine, 1=pink
local levels_str = "-30;-24;-18"
local status_msg = "Ready. Select track and FX to begin."

-- UI state
local tab_selected = 1

local function build_combo_items(items)
  if #items == 0 then return "" end
  return table.concat(items, "\0") .. "\0"
end

local function scan_tracks()
  tracks = {}
  track_names = {}
  
  local tcount = reaper.CountTracks(0)
  for ti = -1, tcount - 1 do
    local track = (ti == -1) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, ti)
    if track then
      local ok, name = reaper.GetTrackName(track)
      if not ok then name = "(unnamed)" end
      if ti == -1 then name = "[MASTER] " .. name end
      tracks[#tracks + 1] = track
      track_names[#track_names + 1] = name
    end
  end
end

local function scan_fx_on_track(track)
  fx_list = {}
  param_info = {}
  param_checked = {}
  param_configs = {}
  
  if not track then return end
  
  local fx_count = reaper.TrackFX_GetCount(track)
  for fi = 0, fx_count - 1 do
    local ok, name = reaper.TrackFX_GetFXName(track, fi, "")
    if ok then
      fx_list[#fx_list + 1] = {
        name = name,
        index = fi,
        param_count = reaper.TrackFX_GetNumParams(track, fi),
      }
    end
  end
end

local function load_fx_params(track, fx_idx)
  param_info = {}
  param_checked = {}
  param_configs = {}
  
  if not track or fx_idx < 0 or fx_idx >= #fx_list then return end
  
  local fx = fx_list[fx_idx + 1]
  local param_count = fx.param_count
  
  for pi = 0, param_count - 1 do
    local ok, name = reaper.TrackFX_GetParamName(track, fx.index, pi, "")
    local pname = ok and name or "Param " .. tostring(pi + 1)
    
    param_info[#param_info + 1] = {
      index_0based = pi,
      index_1based = pi + 1,
      name = pname,
    }
    
    param_checked[pi + 1] = false
    param_configs[pi + 1] = {
      min_norm = 0.0,
      max_norm = 1.0,
      steps = 5,
    }
  end
end

local function build_param_spec_string()
  local parts = {}
  for i = 1, #param_info do
    if param_checked[i] then
      local cfg = param_configs[i]
      local spec = string.format(
        "%d:%.6f:%.6f:%d",
        i,
        cfg.min_norm,
        cfg.max_norm,
        cfg.steps
      )
      parts[#parts + 1] = spec
    end
  end
  return table.concat(parts, ";")
end

local function launch_capture_from_ui(track_mode, track_num, dut_fx_1based, signal, levels, param_specs)
  if not file_exists(CAPTURE_PATH) then
    status_msg = "ERROR: Capture script not found"
    return
  end

  ext_set("use_external", "1")
  ext_set("track_mode", track_mode)
  ext_set("track_num", track_num)
  ext_set("dut_fx", dut_fx_1based)
  ext_set("signal_type", signal)
  ext_set("levels", levels)
  ext_set("param_specs", param_specs)
  ext_set("cancel", "0")

  local ok, err = pcall(dofile, CAPTURE_PATH)
  if ok then
    status_msg = "Capture launched. Monitoring live status below."
  else
    status_msg = "ERROR launching capture: " .. tostring(err)
  end
end

local function stop_capture_from_ui()
  ext_set("cancel", "1")
  status_msg = "Stop requested. Waiting for capture loop to exit..."
end

local function main_loop()
  if not visible then
    reaper.ImGui_DestroyContext(ctx)
    return
  end

  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
  visible, _ = reaper.ImGui_Begin(ctx, "IGR Parameter Grid Configurator", true, flags)

  if visible then
    reaper.ImGui_Text(ctx, "Parameter Grid Configurator")
    reaper.ImGui_TextWrapped(ctx, "Set up and launch plugin analysis captures")
    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then
      -- TAB 1: Select DUT
      if reaper.ImGui_BeginTabItem(ctx, "1. Select DUT") then
        reaper.ImGui_Text(ctx, "Choose track and FX to analyze:")
        reaper.ImGui_Spacing(ctx)

        if reaper.ImGui_Button(ctx, "Rescan Tracks", 140, 24) then
          scan_tracks()
          status_msg = "Tracks rescanned (" .. #tracks .. " found)"
        end
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_Text(ctx, "Track:")
        if #track_names == 0 then
          reaper.ImGui_TextWrapped(ctx, "No tracks found")
        else
          local changed_track, new_track_idx = reaper.ImGui_Combo(
            ctx,
            "##track_combo",
            selected_track_idx,
            build_combo_items(track_names),
            #track_names
          )

          if changed_track then
            selected_track_idx = new_track_idx
          local track = (selected_track_idx >= 0 and selected_track_idx < #tracks) and tracks[selected_track_idx + 1] or nil
          scan_fx_on_track(track)
          selected_fx_idx = 0
          status_msg = "Track selected: " .. (track_names[selected_track_idx + 1] or "?")
          end
        end

        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_Text(ctx, "FX (Device Under Test):")
        if #fx_list == 0 then
          reaper.ImGui_TextWrapped(ctx, "No FX found on selected track")
        else
          local fx_names = {}
          for i = 1, #fx_list do
            fx_names[i] = fx_list[i].name
          end

          local changed_fx, new_fx_idx = reaper.ImGui_Combo(
            ctx,
            "##fx_combo",
            selected_fx_idx,
            build_combo_items(fx_names),
            #fx_names
          )

          if changed_fx then
            selected_fx_idx = new_fx_idx
            local track = (selected_track_idx >= 0 and selected_track_idx < #tracks) and tracks[selected_track_idx + 1] or nil
            load_fx_params(track, selected_fx_idx)
            status_msg = "FX loaded: " .. (fx_list[selected_fx_idx + 1] and fx_list[selected_fx_idx + 1].name or "?")
          end
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      -- TAB 2: Configure Parameters
      if reaper.ImGui_BeginTabItem(ctx, "2. Configure Params") then
        if #param_info == 0 then
          reaper.ImGui_TextWrapped(ctx, "Select a DUT first in Tab 1")
        else
          reaper.ImGui_TextWrapped(ctx, "Check parameters to include. Configure normalized range (0-1) and step count.")
          reaper.ImGui_Spacing(ctx)

          if reaper.ImGui_BeginChild(ctx, "ParamList", 700, 350) then
            for i = 1, #param_info do
              local p = param_info[i]
              local checked_before = param_checked[i] or false
              local _, checked = reaper.ImGui_Checkbox(ctx, p.name .. "##chk_" .. i, checked_before)
              param_checked[i] = checked

              if checked then
                reaper.ImGui_SameLine(ctx, 280)
                local cfg = param_configs[i]
                
                reaper.ImGui_PushItemWidth(ctx, 50)
                local changed_min, new_min = reaper.ImGui_InputDouble(ctx, "##min_" .. i, cfg.min_norm, 0.01, 0, "%.3f")
                if changed_min then cfg.min_norm = math.max(0, math.min(1, new_min)) end
                
                reaper.ImGui_SameLine(ctx, 340)
                local changed_max, new_max = reaper.ImGui_InputDouble(ctx, "##max_" .. i, cfg.max_norm, 0.01, 0, "%.3f")
                if changed_max then cfg.max_norm = math.max(0, math.min(1, new_max)) end
                
                reaper.ImGui_SameLine(ctx, 400)
                local changed_steps, new_steps = reaper.ImGui_InputInt(ctx, "##steps_" .. i, cfg.steps)
                if changed_steps then cfg.steps = math.max(1, new_steps) end
                
                reaper.ImGui_PopItemWidth(ctx)

                param_configs[i] = cfg
              end
            end
            reaper.ImGui_EndChild(ctx)
          end
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      -- TAB 3: Test Settings
      if reaper.ImGui_BeginTabItem(ctx, "3. Test Settings") then
        reaper.ImGui_Text(ctx, "Signal Type:")
        if reaper.ImGui_RadioButton(ctx, "Sine Sweep##sig0", signal_type == 0) then
          signal_type = 0
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_RadioButton(ctx, "Pink Noise##sig1", signal_type == 1) then
          signal_type = 1
        end
        
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Text(ctx, "Input Levels (dB; semicolon-separated):")
        local changed_levels, new_levels = reaper.ImGui_InputText(ctx, "##levels_input", levels_str, 256)
        if changed_levels then levels_str = new_levels end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)

        local checked_count = 0
        local combo_count = 1
        for i = 1, #param_info do
          if param_checked[i] then
            checked_count = checked_count + 1
            combo_count = combo_count * param_configs[i].steps
          end
        end

        local levels_count = 0
        for token in string.gmatch(levels_str, "[^;]+") do
          if tonumber(token:match("%-?%d+%.?%d*")) then levels_count = levels_count + 1 end
        end

        reaper.ImGui_TextWrapped(ctx, string.format(
          "Estimated total passes: %d params x %d levels = %d",
          checked_count,
          math.max(1, levels_count),
          combo_count * math.max(1, levels_count)
        ))
        reaper.ImGui_Spacing(ctx)

        local is_running = ext_get("running", "0") == "1"
        local run_status = ext_get("status", "idle")
        local run_progress = ext_get("progress", "")

        reaper.ImGui_TextWrapped(ctx, "Capture Status: " .. (is_running and "RUNNING" or "IDLE"))
        reaper.ImGui_TextWrapped(ctx, "Backend: " .. run_status)
        if run_progress ~= "" then
          reaper.ImGui_TextWrapped(ctx, "Progress: " .. run_progress)
        end
        reaper.ImGui_Spacing(ctx)

        if reaper.ImGui_Button(ctx, "Launch Capture", 200, 28) then
          if checked_count == 0 then
            status_msg = "ERROR: Select at least one parameter"
          elseif #fx_list == 0 then
            status_msg = "ERROR: Select a DUT FX first"
          elseif is_running then
            status_msg = "ERROR: A capture is already running. Stop it first."
          else
            local param_specs = build_param_spec_string()
            local track_mode = (selected_track_idx == 0) and 0 or 2
            local track_num = selected_track_idx
            local dut_fx_1based = selected_fx_idx + 1
            launch_capture_from_ui(track_mode, track_num, dut_fx_1based, signal_type, levels_str, param_specs)
          end
        end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Stop Capture", 200, 28) then
          if is_running then
            stop_capture_from_ui()
          else
            status_msg = "No active capture to stop"
          end
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, "Status: " .. status_msg)

    reaper.ImGui_End(ctx)
  end

  reaper.defer(main_loop)
end

scan_tracks()
main_loop()
