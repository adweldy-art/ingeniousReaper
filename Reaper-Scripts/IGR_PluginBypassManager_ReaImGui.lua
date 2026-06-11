-- @description IGR Plugin Bypass Manager (ReaImGui)
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Scan the current project for FX instances, choose a plugin by name,
--   then bypass or re-enable every matching instance across all tracks.
--   Requires ReaImGui extension.

local ImGui_CreateContext = reaper.ImGui_CreateContext or reaper.ReaImGui_CreateContext
local ImGui_DestroyContext = reaper.ImGui_DestroyContext or reaper.ReaImGui_DestroyContext
local ImGui_Begin = reaper.ImGui_Begin or reaper.ReaImGui_Begin
local ImGui_End = reaper.ImGui_End or reaper.ReaImGui_End
local ImGui_Text = reaper.ImGui_Text or reaper.ReaImGui_Text
local ImGui_TextWrapped = reaper.ImGui_TextWrapped or reaper.ReaImGui_TextWrapped
local ImGui_Separator = reaper.ImGui_Separator or reaper.ReaImGui_Separator
local ImGui_Spacing = reaper.ImGui_Spacing or reaper.ReaImGui_Spacing
local ImGui_Button = reaper.ImGui_Button or reaper.ReaImGui_Button
local ImGui_Combo = reaper.ImGui_Combo or reaper.ReaImGui_Combo
local ImGui_BeginChild = reaper.ImGui_BeginChild or reaper.ReaImGui_BeginChild
local ImGui_EndChild = reaper.ImGui_EndChild or reaper.ReaImGui_EndChild
local ImGui_WindowFlags_AlwaysAutoResize = reaper.ImGui_WindowFlags_AlwaysAutoResize or reaper.ReaImGui_WindowFlags_AlwaysAutoResize

if not ImGui_CreateContext then
  reaper.MB(
    "ReaImGui is not available.\n\nInstall ReaImGui from ReaPack, then run this script again.",
    "IGR Plugin Bypass Manager",
    0
  )
  return
end

local EXT_SECTION = "IGR_PLUGIN_BYPASS_MANAGER"
local EXT_PLUGIN_KEY = "selected_plugin"
local WINDOW_TITLE = "IGR Plugin Bypass Manager"

local ctx = ImGui_CreateContext(WINDOW_TITLE)
local visible = true
local plugin_names = {}
local plugin_items = ""
local plugin_index = 0
local selected_plugin_name = ""
local match_summary = {
  total_instances = 0,
  enabled_instances = 0,
  bypassed_instances = 0,
  track_labels = {},
}
local status_msg = "Scanning project FX..."

local function destroy_context_if_available()
  if ImGui_DestroyContext and ctx then
    ImGui_DestroyContext(ctx)
  end
end

local function build_combo_items(items)
  if #items == 0 then
    return ""
  end
  return table.concat(items, "\0") .. "\0"
end

local function get_track_label(track, is_master)
  local ok, name = reaper.GetTrackName(track)
  if not ok or name == "" then
    name = "(unnamed)"
  end
  if is_master then
    return "[MASTER] " .. name
  end
  return name
end

local function collect_tracks()
  local tracks = {}
  local master = reaper.GetMasterTrack(0)
  if master then
    tracks[#tracks + 1] = { track = master, label = get_track_label(master, true) }
  end

  local track_count = reaper.CountTracks(0)
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    if track then
      tracks[#tracks + 1] = { track = track, label = get_track_label(track, false) }
    end
  end

  return tracks
end

local function plugin_enabled(track, fx_index)
  if reaper.TrackFX_GetEnabled then
    return reaper.TrackFX_GetEnabled(track, fx_index)
  end
  return true
end

local function scan_plugins()
  local seen = {}
  local names = {}
  local tracks = collect_tracks()

  for track_index = 1, #tracks do
    local entry = tracks[track_index]
    local fx_count = reaper.TrackFX_GetCount(entry.track)
    for fx_index = 0, fx_count - 1 do
      local ok, fx_name = reaper.TrackFX_GetFXName(entry.track, fx_index, "")
      if ok and fx_name ~= "" and not seen[fx_name] then
        seen[fx_name] = true
        names[#names + 1] = fx_name
      end
    end
  end

  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)

  plugin_names = names
  plugin_items = build_combo_items(plugin_names)
end

local function load_saved_selection()
  local saved = reaper.GetExtState(EXT_SECTION, EXT_PLUGIN_KEY)
  if saved == nil or saved == "" then
    return
  end

  for index = 1, #plugin_names do
    if plugin_names[index] == saved then
      plugin_index = index - 1
      selected_plugin_name = saved
      return
    end
  end
end

local function save_selection(name)
  reaper.SetExtState(EXT_SECTION, EXT_PLUGIN_KEY, name or "", false)
end

local function summarize_plugin(name)
  local summary = {
    total_instances = 0,
    enabled_instances = 0,
    bypassed_instances = 0,
    track_labels = {},
  }

  if not name or name == "" then
    return summary
  end

  local seen_labels = {}
  local tracks = collect_tracks()
  for track_index = 1, #tracks do
    local entry = tracks[track_index]
    local fx_count = reaper.TrackFX_GetCount(entry.track)
    for fx_index = 0, fx_count - 1 do
      local ok, fx_name = reaper.TrackFX_GetFXName(entry.track, fx_index, "")
      if ok and fx_name == name then
        summary.total_instances = summary.total_instances + 1
        if plugin_enabled(entry.track, fx_index) then
          summary.enabled_instances = summary.enabled_instances + 1
        else
          summary.bypassed_instances = summary.bypassed_instances + 1
        end
        if not seen_labels[entry.label] then
          seen_labels[entry.label] = true
          summary.track_labels[#summary.track_labels + 1] = entry.label
        end
      end
    end
  end

  return summary
end

local function refresh_scan(keep_status)
  local previous = selected_plugin_name
  scan_plugins()

  if #plugin_names == 0 then
    plugin_index = 0
    selected_plugin_name = ""
    match_summary = summarize_plugin(nil)
    if not keep_status then
      status_msg = "No FX found in the current project."
    end
    return
  end

  local found_previous = false
  if previous and previous ~= "" then
    for index = 1, #plugin_names do
      if plugin_names[index] == previous then
        plugin_index = index - 1
        selected_plugin_name = previous
        found_previous = true
        break
      end
    end
  end

  if not found_previous then
    plugin_index = 0
    selected_plugin_name = plugin_names[1]
    save_selection(selected_plugin_name)
  end

  match_summary = summarize_plugin(selected_plugin_name)
  if not keep_status then
    status_msg = string.format("Found %d distinct FX names in this project.", #plugin_names)
  end
end

local function apply_enabled_state(plugin_name, enabled)
  if not plugin_name or plugin_name == "" then
    status_msg = "Choose a plugin first."
    return
  end

  local changed_instances = 0
  local touched_tracks = {}
  local tracks = collect_tracks()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for track_index = 1, #tracks do
    local entry = tracks[track_index]
    local fx_count = reaper.TrackFX_GetCount(entry.track)
    for fx_index = 0, fx_count - 1 do
      local ok, fx_name = reaper.TrackFX_GetFXName(entry.track, fx_index, "")
      if ok and fx_name == plugin_name then
        local current_enabled = plugin_enabled(entry.track, fx_index)
        if current_enabled ~= enabled then
          reaper.TrackFX_SetEnabled(entry.track, fx_index, enabled)
          changed_instances = changed_instances + 1
          touched_tracks[entry.label] = true
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  if enabled then
    reaper.Undo_EndBlock("Enable all instances of " .. plugin_name, -1)
  else
    reaper.Undo_EndBlock("Bypass all instances of " .. plugin_name, -1)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  refresh_scan(true)

  local touched_track_count = 0
  for _ in pairs(touched_tracks) do
    touched_track_count = touched_track_count + 1
  end

  if changed_instances == 0 then
    if enabled then
      status_msg = "All matching instances were already enabled."
    else
      status_msg = "All matching instances were already bypassed."
    end
    return
  end

  if enabled then
    status_msg = string.format(
      "Enabled %d instances across %d tracks for %s.",
      changed_instances,
      touched_track_count,
      plugin_name
    )
  else
    status_msg = string.format(
      "Bypassed %d instances across %d tracks for %s.",
      changed_instances,
      touched_track_count,
      plugin_name
    )
  end
end

local function draw_match_preview()
  if not selected_plugin_name or selected_plugin_name == "" then
    ImGui_TextWrapped(ctx, "Choose a plugin to inspect matching instances.")
    return
  end

  ImGui_TextWrapped(ctx, "Selected plugin: " .. selected_plugin_name)
  ImGui_TextWrapped(ctx, string.format(
    "Instances: %d total, %d enabled, %d bypassed",
    match_summary.total_instances,
    match_summary.enabled_instances,
    match_summary.bypassed_instances
  ))

  ImGui_Spacing(ctx)
  ImGui_Text(ctx, "Tracks with matches:")
  if ImGui_BeginChild(ctx, "##match_tracks", 560, 180) then
    if #match_summary.track_labels == 0 then
      ImGui_TextWrapped(ctx, "No matching instances found for the selected plugin.")
    else
      for index = 1, #match_summary.track_labels do
        ImGui_TextWrapped(ctx, match_summary.track_labels[index])
      end
    end
    ImGui_EndChild(ctx)
  end
end

local function main_loop()
  if not visible then
    destroy_context_if_available()
    return
  end

  local flags = ImGui_WindowFlags_AlwaysAutoResize and ImGui_WindowFlags_AlwaysAutoResize() or 0
  local window_visible, window_open = ImGui_Begin(ctx, WINDOW_TITLE, true, flags)
  if window_open ~= nil then
    visible = window_open
  end

  if window_visible then
    ImGui_Text(ctx, "Project-wide Plugin Bypass Tool")
    ImGui_TextWrapped(ctx, "Select a plugin name from the current project, then bypass or re-enable every matching instance across all tracks and the master track.")
    ImGui_Separator(ctx)

    if ImGui_Button(ctx, "Refresh FX Scan", 160, 26) then
      refresh_scan(false)
    end

    ImGui_Spacing(ctx)
    ImGui_Text(ctx, "Plugin:")
    if #plugin_names == 0 then
      ImGui_TextWrapped(ctx, "No plugins found in the current project.")
    else
      local changed, new_index = ImGui_Combo(
        ctx,
        "##plugin_combo",
        plugin_index,
        plugin_items,
        #plugin_names
      )
      if changed then
        plugin_index = new_index
        selected_plugin_name = plugin_names[plugin_index + 1] or ""
        save_selection(selected_plugin_name)
        match_summary = summarize_plugin(selected_plugin_name)
        status_msg = "Plugin selection updated."
      end
    end

    ImGui_Spacing(ctx)
    draw_match_preview()

    ImGui_Spacing(ctx)
    ImGui_Separator(ctx)

    if ImGui_Button(ctx, "Bypass All Instances", 260, 30) then
      apply_enabled_state(selected_plugin_name, false)
    end

    if ImGui_Button(ctx, "Enable All Instances", 260, 30) then
      apply_enabled_state(selected_plugin_name, true)
    end

    ImGui_Spacing(ctx)
    ImGui_Separator(ctx)
    ImGui_TextWrapped(ctx, "Status: " .. status_msg)

    ImGui_End(ctx)
  end

  reaper.defer(main_loop)
end

refresh_scan(false)
load_saved_selection()
if selected_plugin_name == "" and #plugin_names > 0 then
  selected_plugin_name = plugin_names[plugin_index + 1] or ""
  save_selection(selected_plugin_name)
end
match_summary = summarize_plugin(selected_plugin_name)
main_loop()