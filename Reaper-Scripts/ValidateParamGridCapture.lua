-- @description Validate IGR parameter-grid capture outputs (CSV + metadata JSON)
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Validates exported capture datasets for completeness and basic integrity.

local REQUIRED_COLUMNS = {
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

local function split_csv_line(line)
  local out = {}
  local cur = {}
  local i = 1
  local in_quotes = false

  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      if in_quotes and i < #line and line:sub(i + 1, i + 1) == '"' then
        cur[#cur + 1] = '"'
        i = i + 1
      else
        in_quotes = not in_quotes
      end
    elseif ch == "," and not in_quotes then
      out[#out + 1] = table.concat(cur)
      cur = {}
    else
      cur[#cur + 1] = ch
    end
    i = i + 1
  end

  out[#out + 1] = table.concat(cur)
  return out
end

local function trim(s)
  return tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function parse_header_map(header_cols)
  local map = {}
  for i = 1, #header_cols do
    map[trim(header_cols[i])] = i
  end
  return map
end

local function parse_json_number(content, key)
  local pattern = '"' .. key .. '"%s*:%s*([%+%-]?[%d%.]+)'
  local v = content:match(pattern)
  return tonumber(v)
end

local function parse_json_string(content, key)
  local pattern = '"' .. key .. '"%s*:%s*"([^"]*)"'
  return content:match(pattern)
end

local function validate_dataset(csv_path, meta_path)
  local findings = {}
  local warnings = {}

  local csv_file = io.open(csv_path, "r")
  if not csv_file then
    return false, { "Could not open CSV: " .. csv_path }, {}
  end

  local header_line = csv_file:read("*l")
  if not header_line then
    csv_file:close()
    return false, { "CSV is empty: " .. csv_path }, {}
  end

  local header_cols = split_csv_line(header_line)
  local header_map = parse_header_map(header_cols)

  for i = 1, #REQUIRED_COLUMNS do
    local col = REQUIRED_COLUMNS[i]
    if not header_map[col] then
      findings[#findings + 1] = "Missing required column: " .. col
    end
  end

  local combo_total_idx = header_map.combo_total
  local combo_index_idx = header_map.combo_index
  local run_level_idx = header_map.run_level_db
  local freq_idx = header_map.freq_hz
  local gain_idx = header_map.gain_db

  local row_count = 0
  local parse_errors = 0
  local combos_seen = {}
  local levels_seen = {}
  local combo_total_value = nil

  for line in csv_file:lines() do
    if trim(line) ~= "" then
      row_count = row_count + 1
      local cols = split_csv_line(line)

      if combo_total_idx then
        local ct = tonumber(cols[combo_total_idx])
        if not ct then
          parse_errors = parse_errors + 1
        elseif not combo_total_value then
          combo_total_value = ct
        elseif combo_total_value ~= ct then
          findings[#findings + 1] = "Inconsistent combo_total values in CSV"
        end
      end

      if combo_index_idx then
        local ci = tonumber(cols[combo_index_idx])
        if not ci then
          parse_errors = parse_errors + 1
        else
          combos_seen[ci] = true
        end
      end

      if run_level_idx then
        local lvl = tonumber(cols[run_level_idx])
        if not lvl then
          parse_errors = parse_errors + 1
        else
          levels_seen[string.format("%.6f", lvl)] = true
        end
      end

      if freq_idx and not tonumber(cols[freq_idx]) then
        parse_errors = parse_errors + 1
      end

      if gain_idx and not tonumber(cols[gain_idx]) then
        parse_errors = parse_errors + 1
      end
    end
  end

  csv_file:close()

  if row_count == 0 then
    findings[#findings + 1] = "CSV has header but no data rows"
  end

  if parse_errors > 0 then
    warnings[#warnings + 1] = "Numeric parse issues found: " .. tostring(parse_errors)
  end

  local combo_seen_count = 0
  for _ in pairs(combos_seen) do
    combo_seen_count = combo_seen_count + 1
  end

  local levels_seen_count = 0
  for _ in pairs(levels_seen) do
    levels_seen_count = levels_seen_count + 1
  end

  if combo_total_value and combo_seen_count < combo_total_value then
    warnings[#warnings + 1] = string.format(
      "Observed %d combos but combo_total says %d",
      combo_seen_count,
      combo_total_value
    )
  end

  local meta_status = "missing"
  if meta_path and meta_path ~= "" then
    local meta_content = read_all(meta_path)
    if meta_content then
      meta_status = "found"
      local meta_row_count = parse_json_number(meta_content, "row_count")
      local meta_combo_total = parse_json_number(meta_content, "combo_total")
      local meta_levels_count = parse_json_number(meta_content, "levels_count")
      local capture_id = parse_json_string(meta_content, "capture_id") or "unknown"

      if meta_row_count and meta_row_count ~= row_count then
        warnings[#warnings + 1] = string.format("Meta row_count (%d) != CSV rows (%d)", meta_row_count, row_count)
      end
      if meta_combo_total and combo_total_value and meta_combo_total ~= combo_total_value then
        warnings[#warnings + 1] = string.format("Meta combo_total (%d) != CSV combo_total (%d)", meta_combo_total, combo_total_value)
      end
      if meta_levels_count and meta_levels_count ~= levels_seen_count then
        warnings[#warnings + 1] = string.format("Meta levels_count (%d) != observed levels (%d)", meta_levels_count, levels_seen_count)
      end

      warnings[#warnings + 1] = "Capture ID: " .. capture_id
    else
      meta_status = "unreadable"
      warnings[#warnings + 1] = "Metadata file path provided but could not read"
    end
  end

  local ok = (#findings == 0)
  local summary = {
    "Validation summary",
    "CSV: " .. csv_path,
    "Rows: " .. tostring(row_count),
    "Combos observed: " .. tostring(combo_seen_count),
    "Levels observed: " .. tostring(levels_seen_count),
    "Metadata: " .. meta_status,
  }

  if combo_total_value then
    summary[#summary + 1] = "combo_total: " .. tostring(combo_total_value)
  end

  return ok, findings, warnings, summary
end

local function main()
  local ok_csv, csv_path = reaper.GetUserFileNameForRead("", "Select capture CSV", ".csv")
  if not ok_csv then return end

  local default_meta = csv_path:gsub("%.csv$", ".meta.json")
  local meta_exists = io.open(default_meta, "r") ~= nil
  if meta_exists then
    local f = io.open(default_meta, "r")
    if f then f:close() end
  end

  local use_meta = false
  if meta_exists then
    local choice = reaper.MB("Found metadata sidecar. Include it in validation?", "Validate Capture", 4)
    use_meta = (choice == 6)
  end

  local meta_path = ""
  if use_meta then
    meta_path = default_meta
  else
    local choice = reaper.MB("Select a metadata JSON manually?", "Validate Capture", 4)
    if choice == 6 then
      local ok_meta, picked = reaper.GetUserFileNameForRead("", "Select metadata JSON", ".json")
      if ok_meta then
        meta_path = picked
      end
    end
  end

  local passed, findings, warnings, summary = validate_dataset(csv_path, meta_path)

  reaper.ShowConsoleMsg("")
  for i = 1, #summary do
    reaper.ShowConsoleMsg(summary[i] .. "\n")
  end
  reaper.ShowConsoleMsg("\n")

  if #findings > 0 then
    reaper.ShowConsoleMsg("Findings:\n")
    for i = 1, #findings do
      reaper.ShowConsoleMsg("- " .. findings[i] .. "\n")
    end
    reaper.ShowConsoleMsg("\n")
  end

  if #warnings > 0 then
    reaper.ShowConsoleMsg("Warnings:\n")
    for i = 1, #warnings do
      reaper.ShowConsoleMsg("- " .. warnings[i] .. "\n")
    end
    reaper.ShowConsoleMsg("\n")
  end

  local msg = "Validation complete.\n\n"
  msg = msg .. "Rows: " .. tostring(summary[3]:match("%d+") or "?") .. "\n"
  msg = msg .. "Combos observed: " .. tostring(summary[4]:match("%d+") or "?") .. "\n"
  msg = msg .. "Levels observed: " .. tostring(summary[5]:match("%d+") or "?") .. "\n\n"

  if passed then
    msg = msg .. "Result: PASS"
    if #warnings > 0 then
      msg = msg .. " (with warnings)"
    end
    reaper.MB(msg, "Validate Capture", 0)
  else
    msg = msg .. "Result: FAIL\nSee ReaScript console for findings."
    reaper.MB(msg, "Validate Capture", 0)
  end
end

main()
