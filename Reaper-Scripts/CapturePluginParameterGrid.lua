-- @description Capture analyzer data across plugin parameter combinations
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Analysis-only capture workflow.
--   Requires two JSFX instances in the project:
--   1) JS: IGR_AnalyzerLab in Source mode
--   2) JS: IGR_AnalyzerLab in Probe mode (after DUT)
--
--   The script sweeps selected DUT FX parameters over normalized ranges,
--   runs analyzer passes at each combination and level, and writes:
--   - one CSV with per-step measurements
--   - one JSON sidecar with run metadata and combo definitions

local FX_NAME = "JS: IGR_AnalyzerLab"
local GMEM_BUS = "IGR_ANALYZER_LAB"
local EXT_SECTION = "IGR_PARAM_CAPTURE"

local HEARTBEAT_SEC = 1.0
local LEVEL_TIMEOUT_SEC = 45.0
local COMBO_RESET_SETTLE_SEC = 0.10
local COMBO_RESET_TIMEOUT_SEC = 2.0

local PARAM_MODE = 0
local PARAM_RUN = 1
local PARAM_SIGNAL = 2
local PARAM_LEVEL_DB = 7

local GMEM_DONE = 8
local GMEM_SEQ = 100
local GMEM_NONCE = 101
local GMEM_STEP = 102
local GMEM_FREQ = 103
local GMEM_IN_DB = 104
local GMEM_OUT_DB = 105
local GMEM_GAIN_DB = 106
local GMEM_THD_DB = 107
local GMEM_CREST_DB = 108
local GMEM_SIGNAL = 109

local function ext_set(key, value)
  reaper.SetExtState(EXT_SECTION, key, tostring(value or ""), false)
end

local function ext_get(key, default)
  local v = reaper.GetExtState(EXT_SECTION, key)
  if v == nil or v == "" then return default end
  return v
end

local function ext_get_number(key, default)
  local n = tonumber(ext_get(key, ""))
  if not n then return default end
  return n
end

local function json_escape(s)
  local out = tostring(s)
  out = out:gsub("\\", "\\\\")
  out = out:gsub('"', '\\"')
  out = out:gsub("\n", "\\n")
  out = out:gsub("\r", "\\r")
  out = out:gsub("\t", "\\t")
  return out
end

local function split_numbers_csv(s)
  local out = {}
  for token in tostring(s):gmatch("[^,;]+") do
    local n = tonumber((token:gsub("^%s+", ""):gsub("%s+$", "")))
    if n then out[#out + 1] = n end
  end
  return out
end

local function read_launch_config()
  local use_external = ext_get("use_external", "0") == "1"
  if use_external then
    return {
      track_mode = ext_get_number("track_mode", 1),
      track_num = ext_get_number("track_num", 1),
      dut_fx = ext_get_number("dut_fx", 1),
      signal_type = ext_get_number("signal_type", 0),
      levels_s = ext_get("levels", "-30;-24;-18"),
      param_spec_s = ext_get("param_specs", "1:0:1:5"),
      source = "external",
    }
  end

  local ok, vals = reaper.GetUserInputs(
    "Parameter Grid Capture",
    6,
    "Track mode (0=Master,1=Selected,2=ProjectTrack),Track #,DUT FX # (1-based),Signal (0=Sine,1=Pink),Levels dB (; list),Param specs",
    "1,1,1,0,-30;-24;-18,1:0:1:5;2:0:1:5"
  )
  if not ok then return nil end

  local track_mode, track_num, dut_fx, signal_s, levels_s, param_spec_s = vals:match(
    "^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),(.+)$"
  )
  if not track_mode then
    reaper.MB("Invalid input. Expected 6 comma-separated values.", "Parameter Grid Capture", 0)
    return nil
  end

  return {
    track_mode = tonumber(track_mode) or 1,
    track_num = tonumber(track_num) or 1,
    dut_fx = tonumber(dut_fx) or 1,
    signal_type = tonumber(signal_s) or 0,
    levels_s = levels_s,
    param_spec_s = param_spec_s,
    source = "prompt",
  }
end

local function is_analyzer_fx(track, fx_index)
  local ok, name = reaper.TrackFX_GetFXName(track, fx_index, "")
  return ok and tostring(name):find("IGR_AnalyzerLab", 1, true) ~= nil
end

local function analyzer_mode(track, fx_index)
  local mode_norm = reaper.TrackFX_GetParamNormalized(track, fx_index, PARAM_MODE)
  return (mode_norm >= 0.5) and 1 or 0
end

local function find_analyzer_instances_for_dut(dut_track, dut_fx_0based)
  local src = nil
  local prb = nil
  local fx_count = reaper.TrackFX_GetCount(dut_track)

  for fi = 0, fx_count - 1 do
    if is_analyzer_fx(dut_track, fi) then
      local mode = analyzer_mode(dut_track, fi)
      if fi < dut_fx_0based and mode == 0 then
        -- Use the Source instance closest to the DUT from the left.
        src = { track = dut_track, fx = fi }
      elseif fi > dut_fx_0based and mode == 1 and not prb then
        -- Use the first Probe instance after the DUT.
        prb = { track = dut_track, fx = fi }
      end
    end
  end

  return src, prb
end

local function parse_param_specs(spec)
  -- Format: "1:0:1:5;2:0.2:0.8:4"
  -- Means: param1 minNorm=0 maxNorm=1 steps=5, param2 minNorm=0.2 maxNorm=0.8 steps=4
  local parsed = {}
  for token in tostring(spec):gmatch("[^;]+") do
    local p, mn, mx, st = token:match("^%s*(%d+)%s*:%s*([%+%-]?[%d%.]+)%s*:%s*([%+%-]?[%d%.]+)%s*:%s*(%d+)%s*$")
    if p and mn and mx and st then
      local pnum = tonumber(p)
      local min_norm = tonumber(mn)
      local max_norm = tonumber(mx)
      local steps = tonumber(st)
      if pnum and min_norm and max_norm and steps and pnum >= 1 and steps >= 1 then
        if min_norm < 0 then min_norm = 0 end
        if min_norm > 1 then min_norm = 1 end
        if max_norm < 0 then max_norm = 0 end
        if max_norm > 1 then max_norm = 1 end
        parsed[#parsed + 1] = {
          param_1based = pnum,
          param_0based = pnum - 1,
          min_norm = min_norm,
          max_norm = max_norm,
          steps = steps,
          param_name = string.format("param_%d", pnum),
        }
      end
    end
  end
  return parsed
end

local function values_for_spec(ps)
  local vals = {}
  if ps.steps == 1 then
    vals[1] = ps.min_norm
    return vals
  end
  local span = ps.max_norm - ps.min_norm
  for i = 0, ps.steps - 1 do
    vals[#vals + 1] = ps.min_norm + span * (i / (ps.steps - 1))
  end
  return vals
end

local function enrich_param_specs_with_names(param_specs, dut_track, dut_fx_0based)
  for i = 1, #param_specs do
    local ps = param_specs[i]
    local ok, name = reaper.TrackFX_GetParamName(dut_track, dut_fx_0based, ps.param_0based, "")
    if ok and name and name ~= "" then
      ps.param_name = name
    else
      ps.param_name = string.format("param_%d", ps.param_1based)
    end
  end
end

local function build_cartesian_combinations(param_specs, dut_track, dut_fx_0based)
  if #param_specs == 0 then
    return { { params = {}, planned_params = {} } }
  end

  local spec_values = {}
  for i = 1, #param_specs do
    spec_values[i] = values_for_spec(param_specs[i])
  end

  local out = {}

  local function recurse(i, acc)
    if i > #param_specs then
      local combo = { params = {}, planned_params = {} }
      for k = 1, #acc do
        combo.params[k] = {
          param_1based = acc[k].param_1based,
          param_0based = acc[k].param_0based,
          param_name   = acc[k].param_name,
          norm = acc[k].norm,
        }
        -- Pre-read the mapped value by temporarily querying the FX
        local planned_val = 0.0
        if dut_track and dut_fx_0based then
          reaper.TrackFX_SetParamNormalized(dut_track, dut_fx_0based, acc[k].param_0based, acc[k].norm)
          planned_val = reaper.TrackFX_GetParam(dut_track, dut_fx_0based, acc[k].param_0based)
        end
        combo.planned_params[k] = {
          param_1based = acc[k].param_1based,
          param_0based = acc[k].param_0based,
          param_name   = acc[k].param_name,
          norm = acc[k].norm,
          value = planned_val,
        }
      end
      out[#out + 1] = combo
      return
    end

    local ps = param_specs[i]
    local vals = spec_values[i]
    for vi = 1, #vals do
      acc[i] = {
        param_1based = ps.param_1based,
        param_0based = ps.param_0based,
        param_name   = ps.param_name,
        norm = vals[vi],
      }
      recurse(i + 1, acc)
    end
  end

  recurse(1, {})
  return out
end

local function resolve_dut_track(track_mode, track_num_1based)
  if track_mode == 0 then
    return reaper.GetMasterTrack(0)
  end

  if track_mode == 2 then
    local tcount = reaper.CountTracks(0)
    if tcount <= 0 then return nil end
    if track_num_1based < 1 then track_num_1based = 1 end
    if track_num_1based > tcount then track_num_1based = tcount end
    return reaper.GetTrack(0, track_num_1based - 1)
  end

  local selected_count = reaper.CountSelectedTracks(0)
  if selected_count <= 0 then
    return nil
  end

  if track_num_1based < 1 then track_num_1based = 1 end
  if track_num_1based > selected_count then track_num_1based = selected_count end
  return reaper.GetSelectedTrack(0, track_num_1based - 1)
end

local function set_source_run(source, running)
  reaper.TrackFX_SetParamNormalized(source.track, source.fx, PARAM_RUN, running and 1.0 or 0.0)
end

local function set_source_signal(source, sig)
  reaper.TrackFX_SetParamNormalized(source.track, source.fx, PARAM_SIGNAL, (sig == 0) and 0.0 or 1.0)
end

local function set_source_level_db(source, db)
  reaper.TrackFX_SetParam(source.track, source.fx, PARAM_LEVEL_DB, db)
end

local state = nil

local function current_result_signature()
  local seq = math.floor(reaper.gmem_read(GMEM_SEQ) or 0)
  local nonce = math.floor(reaper.gmem_read(GMEM_NONCE) or 0)
  local step = math.floor(reaper.gmem_read(GMEM_STEP) or -1)
  return seq, nonce, step
end

local function append_current_result_row()
  local row = {
    combo_index = state.combo_idx,
    combo_summary = state.current_combo_summary,
    run_level_db = state.current_level_db,
    nonce = math.floor(reaper.gmem_read(GMEM_NONCE) or 0),
    step = math.floor(reaper.gmem_read(GMEM_STEP) or 0),
    freq = reaper.gmem_read(GMEM_FREQ) or 0.0,
    in_db = reaper.gmem_read(GMEM_IN_DB) or 0.0,
    out_db = reaper.gmem_read(GMEM_OUT_DB) or 0.0,
    gain_db = reaper.gmem_read(GMEM_GAIN_DB) or 0.0,
    thd_db = reaper.gmem_read(GMEM_THD_DB) or 0.0,
    crest_db = reaper.gmem_read(GMEM_CREST_DB) or 0.0,
    signal_type = math.floor(reaper.gmem_read(GMEM_SIGNAL) or 0),
    applied_params = (state.current_combo and state.current_combo.applied_params) or {},
  }
  state.rows[#state.rows + 1] = row
end

local function apply_combo_parameters(combo)
  local applied = {}
  for i = 1, #combo.params do
    local p = combo.params[i]
    reaper.TrackFX_SetParamNormalized(state.dut_track, state.dut_fx_0based, p.param_0based, p.norm)
    local val = reaper.TrackFX_GetParam(state.dut_track, state.dut_fx_0based, p.param_0based)
    applied[#applied + 1] = {
      param_1based = p.param_1based,
      param_0based = p.param_0based,
      param_name = p.param_name,
      norm = p.norm,
      value = val,
    }
  end
  combo.applied_params = applied
end

local function combo_to_summary(combo)
  local params = combo.applied_params
  if not params or #params == 0 then
    params = combo.planned_params or {}
  end
  if #params == 0 then
    return "default"
  end
  local parts = {}
  for i = 1, #params do
    local p = params[i]
    local label = (p.param_name and p.param_name ~= "") and p.param_name or string.format("param_%d", p.param_1based)
    parts[#parts + 1] = string.format("%s=%.4f(v=%.6f)", label, p.norm, p.value)
  end
  return table.concat(parts, "|")
end

local function write_output_csv()
  local proj_path = reaper.GetProjectPathEx(0, "")
  if not proj_path or proj_path == "" then
    proj_path = reaper.GetProjectPath("")
  end

  local ts = os.date("%Y%m%d_%H%M%S")
  local out_base = proj_path .. "\\IGR_ParamGridCapture_" .. ts
  local out_path = out_base .. ".csv"
  local f = io.open(out_path, "w")
  if not f then
    reaper.MB("Could not write CSV:\n" .. out_path, "Parameter Grid Capture", 0)
    return nil, nil, nil
  end

  local header = {
    "combo_index",
    "combo_total",
    "combo_summary",
    "run_level_db",
    "nonce",
    "step_index",
    "freq_hz",
    "input_db",
    "output_db",
    "gain_db",
    "thd_db",
    "crest_db",
    "signal_type",
  }

  for i = 1, state.max_param_count do
    local ps = state.param_specs[i]
    local col_base = (ps and ps.param_name and ps.param_name ~= "") and ps.param_name or string.format("param_%d", i)
    -- sanitize for CSV: replace commas/quotes with underscores
    col_base = col_base:gsub('[,"]', '_')
    header[#header + 1] = col_base .. "_index"
    header[#header + 1] = col_base .. "_norm"
    header[#header + 1] = col_base .. "_value"
  end

  f:write(table.concat(header, ",") .. "\n")

  for i = 1, #state.rows do
    local r = state.rows[i]
    local applied_params = r.applied_params or {}
    local cols = {
      tostring(r.combo_index),
      tostring(state.combo_total),
      r.combo_summary,
      string.format("%.6f", r.run_level_db),
      tostring(r.nonce),
      tostring(r.step),
      string.format("%.6f", r.freq),
      string.format("%.6f", r.in_db),
      string.format("%.6f", r.out_db),
      string.format("%.6f", r.gain_db),
      string.format("%.6f", r.thd_db),
      string.format("%.6f", r.crest_db),
      tostring(r.signal_type),
    }

    for pi = 1, state.max_param_count do
      local p = applied_params[pi]
      if p then
        cols[#cols + 1] = tostring(p.param_1based)
        cols[#cols + 1] = string.format("%.6f", p.norm)
        cols[#cols + 1] = string.format("%.9f", p.value)
      else
        cols[#cols + 1] = ""
        cols[#cols + 1] = ""
        cols[#cols + 1] = ""
      end
    end

    f:write(table.concat(cols, ",") .. "\n")
  end

  f:close()
  return out_base, out_path, ts
end

local function write_output_metadata_json(out_base, csv_path, ts)
  local json_path = out_base .. ".meta.json"
  local f = io.open(json_path, "w")
  if not f then
    return nil
  end

  f:write("{\n")
  f:write(string.format("  \"capture_id\": \"%s\",\n", json_escape(ts)))
  f:write(string.format("  \"created_at_local\": \"%s\",\n", json_escape(os.date("%Y-%m-%d %H:%M:%S"))))
  f:write(string.format("  \"csv_path\": \"%s\",\n", json_escape(csv_path)))
  f:write(string.format("  \"signal_type\": %d,\n", state.signal_type))
  f:write(string.format("  \"combo_total\": %d,\n", state.combo_total))
  f:write(string.format("  \"levels_count\": %d,\n", #state.levels))
  f:write(string.format("  \"estimated_passes\": %d,\n", state.combo_total * #state.levels))
  f:write(string.format("  \"row_count\": %d,\n", #state.rows))
  f:write("  \"levels_db\": [")
  for i = 1, #state.levels do
    if i > 1 then f:write(", ") end
    f:write(string.format("%.6f", state.levels[i]))
  end
  f:write("],\n")

  local ok_name, fx_name = reaper.TrackFX_GetFXName(state.dut_track, state.dut_fx_0based, "")
  local dut_name = ok_name and fx_name or "Unknown"
  f:write("  \"dut\": {\n")
  f:write(string.format("    \"fx_name\": \"%s\",\n", json_escape(dut_name)))
  f:write(string.format("    \"fx_index_1based\": %d\n", state.dut_fx_0based + 1))
  f:write("  },\n")

  f:write("  \"param_specs\": [\n")
  for i = 1, #state.param_specs do
    local p = state.param_specs[i]
    f:write("    {")
    f:write(string.format("\"param_index_1based\": %d, ", p.param_1based))
    f:write(string.format("\"param_name\": \"%s\", ", json_escape(p.param_name or "")))
    f:write(string.format("\"min_norm\": %.6f, ", p.min_norm))
    f:write(string.format("\"max_norm\": %.6f, ", p.max_norm))
    f:write(string.format("\"steps\": %d", p.steps))
    if i < #state.param_specs then
      f:write("},\n")
    else
      f:write("}\n")
    end
  end
  f:write("  ],\n")

  f:write("  \"combos\": [\n")
  for ci = 1, #state.combos do
    local combo = state.combos[ci]
    -- prefer actually-applied params; fall back to pre-planned values
    local params = combo.applied_params
    if not params or #params == 0 then
      params = combo.planned_params or {}
    end
    local was_executed = (combo.applied_params and #combo.applied_params > 0)
    f:write("    {\n")
    f:write(string.format("      \"combo_index\": %d,\n", ci))
    f:write(string.format("      \"executed\": %s,\n", was_executed and "true" or "false"))
    f:write(string.format("      \"summary\": \"%s\",\n", json_escape(combo_to_summary(combo))))
    f:write("      \"params\": [")
    for pi = 1, #params do
      local ap = params[pi]
      if pi > 1 then f:write(", ") end
      f:write("{")
      f:write(string.format("\"param_index_1based\": %d, ", ap.param_1based))
      f:write(string.format("\"param_name\": \"%s\", ", json_escape(ap.param_name or "")))
      f:write(string.format("\"norm\": %.6f, ", ap.norm))
      f:write(string.format("\"value\": %.9f", ap.value))
      f:write("}")
    end
    f:write("]\n")
    if ci < #state.combos then
      f:write("    },\n")
    else
      f:write("    }\n")
    end
  end
  f:write("  ]\n")
  f:write("}\n")

  f:close()
  return json_path
end

local function set_running_state(is_running, status_text)
  ext_set("running", is_running and "1" or "0")
  ext_set("status", status_text or "")
end

local function request_cancelled()
  return ext_get("cancel", "0") == "1"
end

local function finish_run(reason, write_outputs)
  if not state then return end

  if state.started_playback and reaper.GetPlayState() ~= 0 then
    reaper.OnStopButton()
  end

  set_source_run(state.source, false)
  reaper.gmem_write(GMEM_DONE, 1)

  local summary = reason or "Capture complete"
  local out_msg = ""

  if write_outputs then
    local out_base, csv_path, ts = write_output_csv()
    local json_path = nil
    if out_base and csv_path and ts then
      json_path = write_output_metadata_json(out_base, csv_path, ts)
      out_msg = "\nCSV:\n" .. csv_path
      if json_path then
        out_msg = out_msg .. "\n\nMetadata:\n" .. json_path
      end
      reaper.ShowConsoleMsg("Parameter grid capture finished.\n" .. summary .. "\n")
      reaper.ShowConsoleMsg("CSV written: " .. csv_path .. "\n")
      if json_path then
        reaper.ShowConsoleMsg("Metadata written: " .. json_path .. "\n")
      end
    end
  end

  set_running_state(false, summary)
  ext_set("progress", summary)
  ext_set("cancel", "0")
  state = nil

  reaper.MB(summary .. out_msg, "Parameter Grid Capture", 0)
end

local function start_next_level()
  state.level_idx = state.level_idx + 1
  if state.level_idx > #state.levels then
    return false
  end

  local level_db = state.levels[state.level_idx]
  set_source_level_db(state.source, level_db)
  set_source_signal(state.source, state.signal_type)
  set_source_run(state.source, false)

  reaper.gmem_write(GMEM_DONE, 0)

  state.current_level_db = level_db
  state.pending_start = true
  state.start_armed_at = reaper.time_precise()
  state.level_started_at = nil
  state.level_start_seq = state.last_seq
  state.level_start_nonce = state.last_result_nonce
  state.level_start_step = state.last_result_step
  state.done_observed_at = nil
  state.last_progress_at = state.start_armed_at

  ext_set("progress", string.format(
    "Arming combo %d/%d level %d/%d (%.1f dB, signal=%s)",
    state.combo_idx,
    state.combo_total,
    state.level_idx,
    #state.levels,
    state.current_level_db,
    (state.signal_type == 0) and "sine" or "pink"
  ))

  return true
end

local function begin_combo_reset()
  state.pending_combo_reset = true
  state.combo_reset_started_at = reaper.time_precise()
  state.combo_reset_stage = 0
  state.combo_reset_stage_at = state.combo_reset_started_at
  set_source_run(state.source, false)
  ext_set("progress", string.format(
    "Resetting analyzer before combo %d/%d",
    state.combo_idx,
    state.combo_total
  ))
end

local function start_next_combo()
  state.combo_idx = state.combo_idx + 1
  if state.combo_idx > #state.combos then
    finish_run("Capture complete", true)
    return
  end

  local combo = state.combos[state.combo_idx]
  apply_combo_parameters(combo)
  state.current_combo = combo
  state.current_combo_summary = combo_to_summary(combo)
  state.level_idx = 0

  begin_combo_reset()

  reaper.ShowConsoleMsg(string.format(
    "Prepared combo %d/%d: %s\n",
    state.combo_idx,
    state.combo_total,
    state.current_combo_summary
  ))
end

local function poll()
  if not state then return end

  local now = reaper.time_precise()

  if state.pending_combo_reset then
    local src_run_reset = math.floor(reaper.gmem_read(1) or 0)
    if state.combo_reset_stage == 0 then
      set_source_run(state.source, false)
      state.combo_reset_stage = 1
      state.combo_reset_stage_at = now
    elseif state.combo_reset_stage == 1 then
      if (now - state.combo_reset_stage_at) >= COMBO_RESET_SETTLE_SEC then
        state.pending_combo_reset = false
        reaper.gmem_write(GMEM_DONE, 0)
        start_next_level()
      end
    end

    if (now - state.combo_reset_started_at) > COMBO_RESET_TIMEOUT_SEC then
      finish_run(
        string.format(
          "Combo reset timeout at combo %d/%d. Source did not re-arm cleanly.",
          state.combo_idx,
          state.combo_total
        ),
        true
      )
      return
    end
  end

  if state.pending_start then
    local src_run = math.floor(reaper.gmem_read(1) or 0)
    if src_run == 0 then
      set_source_run(state.source, true)
      if reaper.GetPlayState() == 0 then
        reaper.OnPlayButton()
        state.started_playback = true
      end
      state.pending_start = false
      state.level_started_at = now
      state.last_progress_at = now
      ext_set("progress", string.format(
        "Running combo %d/%d level %d/%d (%.1f dB, signal=%s)",
        state.combo_idx,
        state.combo_total,
        state.level_idx,
        #state.levels,
        state.current_level_db,
        (state.signal_type == 0) and "sine" or "pink"
      ))
    end
  end

  if request_cancelled() then
    finish_run("Capture stopped by user", true)
    return
  end

  local seq, result_nonce, result_step = current_result_signature()
  local seq_advanced = seq > state.last_seq
  local signature_changed =
    (seq ~= state.last_seq) or
    (result_nonce ~= state.last_result_nonce) or
    (result_step ~= state.last_result_step)

  if seq_advanced then
    for _ = state.last_seq + 1, seq do
      append_current_result_row()
    end
    state.last_progress_at = now
  elseif signature_changed and result_step >= 0 then
    -- Accept a single fresh row even when the shared sequence counter resets,
    -- wraps, or is disturbed by another analyzer instance on the global bus.
    append_current_result_row()
    state.last_progress_at = now
  end

  if seq_advanced or (signature_changed and result_step >= 0) then
    state.last_seq = seq
    state.last_result_nonce = result_nonce
    state.last_result_step = result_step
  end

  local done = math.floor(reaper.gmem_read(GMEM_DONE) or 0)
  if done >= 1 and not state.pending_combo_reset then
    local got_probe_rows =
      (state.last_seq > (state.level_start_seq or -1)) or
      (state.last_result_nonce ~= (state.level_start_nonce or -1)) or
      (state.last_result_step ~= (state.level_start_step or -1))
    if not got_probe_rows then
      if not state.done_observed_at then
        state.done_observed_at = now
        reaper.defer(poll)
        return
      end

      if (now - state.done_observed_at) < 0.25 then
        reaper.defer(poll)
        return
      end

      finish_run(
        string.format(
          "Source completed combo %d/%d level %d/%d, but Probe produced no result rows. Place JS: IGR_AnalyzerLab in Source mode before the DUT and JS: IGR_AnalyzerLab in Probe mode after the DUT on the same track.",
          state.combo_idx,
          state.combo_total,
          state.level_idx,
          #state.levels
        ),
        true
      )
      return
    end

    state.done_observed_at = nil
    set_source_run(state.source, false)
    if not start_next_level() then
      start_next_combo()
      if not state then
        return
      end
    end
  end

  if (not state.pending_combo_reset) and (not state.pending_start) and state.level_started_at and (now - state.level_started_at) > LEVEL_TIMEOUT_SEC then
    finish_run(
      string.format(
        "Capture timed out on combo %d/%d level %d/%d after %.1fs. Check analyzer routing and Source/Probe instances.",
        state.combo_idx,
        state.combo_total,
        state.level_idx,
        #state.levels,
        now - state.level_started_at
      ),
      true
    )
    return
  end

  if (now - state.last_heartbeat_at) >= HEARTBEAT_SEC then
    state.last_heartbeat_at = now
    local src_run_hb = math.floor(reaper.gmem_read(1) or 0)
    local done_hb = math.floor(reaper.gmem_read(GMEM_DONE) or 0)
    local seq_hb = math.floor(reaper.gmem_read(GMEM_SEQ) or 0)
    local heartbeat = string.format(
      "[capture] combo %d/%d level %d/%d rows=%d signal=%s src_run=%d done=%d seq=%d",
      state.combo_idx,
      state.combo_total,
      state.level_idx,
      #state.levels,
      #state.rows,
      (state.signal_type == 0) and "sine" or "pink",
      src_run_hb,
      done_hb,
      seq_hb
    )
    ext_set("progress", heartbeat)
    reaper.ShowConsoleMsg(heartbeat .. "\n")
  end

  reaper.defer(poll)
end

local function main()
  reaper.gmem_attach(GMEM_BUS)

  if ext_get("running", "0") == "1" then
    reaper.MB(
      "A capture is already marked as running. Use the stop button in the configurator, then launch again.",
      "Parameter Grid Capture",
      0
    )
    return
  end

  local cfg = read_launch_config()
  if not cfg then return end

  local track_mode_n = tonumber(cfg.track_mode) or 1
  if track_mode_n ~= 0 and track_mode_n ~= 1 and track_mode_n ~= 2 then track_mode_n = 1 end
  local track_num_n = tonumber(cfg.track_num) or 1
  local dut_fx_n = tonumber(cfg.dut_fx) or 1
  local signal_type = tonumber(cfg.signal_type) or 0
  if signal_type < 0 or signal_type > 1 then signal_type = 0 end

  local levels = split_numbers_csv(cfg.levels_s)
  if #levels == 0 then
    reaper.MB("No valid levels provided.", "Parameter Grid Capture", 0)
    return
  end

  local dut_track = resolve_dut_track(track_mode_n, track_num_n)
  if not dut_track then
    reaper.MB("Could not resolve DUT track from selection.", "Parameter Grid Capture", 0)
    return
  end

  local fx_count = reaper.TrackFX_GetCount(dut_track)
  if fx_count <= 0 then
    reaper.MB("No FX found on DUT track.", "Parameter Grid Capture", 0)
    return
  end

  local dut_fx_0based = dut_fx_n - 1
  if dut_fx_0based < 0 or dut_fx_0based >= fx_count then
    reaper.MB("DUT FX index out of range.", "Parameter Grid Capture", 0)
    return
  end

  local src, prb = find_analyzer_instances_for_dut(dut_track, dut_fx_0based)
  if not src or not prb then
    reaper.MB(
      "Could not find the analyzer chain around the DUT.\n\nNeed on the DUT track:\n- One JS: IGR_AnalyzerLab in Source mode before the DUT\n- One JS: IGR_AnalyzerLab in Probe mode after the DUT",
      "Parameter Grid Capture",
      0
    )
    return
  end

  local param_specs = parse_param_specs(cfg.param_spec_s)
  enrich_param_specs_with_names(param_specs, dut_track, dut_fx_0based)
  local combos = build_cartesian_combinations(param_specs, dut_track, dut_fx_0based)
  local combo_total = #combos
  if combo_total <= 0 then
    reaper.MB("No valid parameter combinations generated.", "Parameter Grid Capture", 0)
    return
  end

  local estimated_runs = combo_total * #levels
  if estimated_runs > 600 then
    local choice = reaper.MB(
      string.format("Large run detected (%d combinations x %d levels = %d passes). Continue?", combo_total, #levels, estimated_runs),
      "Parameter Grid Capture",
      1
    )
    if choice ~= 1 then
      return
    end
  end

  set_running_state(true, "Starting capture")
  ext_set("cancel", "0")
  ext_set("launch_source", cfg.source or "unknown")
  reaper.gmem_write(GMEM_DONE, 1)

  state = {
    source = src,
    probe = prb,
    dut_track = dut_track,
    dut_fx_0based = dut_fx_0based,
    signal_type = signal_type,
    levels = levels,
    combos = combos,
    param_specs = param_specs,
    combo_total = combo_total,
    combo_idx = 0,
    level_idx = 0,
    current_level_db = levels[1],
    current_combo = combos[1],
    current_combo_summary = "",
    max_param_count = #param_specs,
    last_seq = math.floor(reaper.gmem_read(GMEM_SEQ) or 0),
    last_result_nonce = math.floor(reaper.gmem_read(GMEM_NONCE) or 0),
    last_result_step = math.floor(reaper.gmem_read(GMEM_STEP) or -1),
    level_started_at = reaper.time_precise(),
    last_progress_at = reaper.time_precise(),
    last_heartbeat_at = 0,
    started_playback = false,
    rows = {},
  }

  set_source_run(state.source, false)
  start_next_combo()
  poll()
end

main()