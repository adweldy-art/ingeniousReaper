-- =============================================================================
-- Peak Analysis & WAV Copy  —  live debug GUI
-- =============================================================================
-- Workflow:
--   1. Validate time selection and project path
--   2. Split items at time selection boundaries on all leaf tracks
--   3. Collect the resulting item that sits inside the selection on each track
--   4. For each candidate track scan PCM samples via audio accessor:
--        - measure peak dBFS in a single pass
--        - simultaneously write raw 24-bit WAV to <project>/bounced/<trackname>.wav
--        - if peak <= SILENCE_THRESHOLD_DB the track is empty — discard the
--          partially written file and exclude the track from everything
--   5. Write peak_analysis.csv for tracks that passed the silence gate
--
-- No render engine used. Source files are 48kHz 24-bit WAV, 1x rate, no FX.
-- Samples are copied byte-for-byte from the take audio accessor.
-- =============================================================================

local TARGET_DB            = -12.0   -- desired peak for "set trim to" column
local SILENCE_THRESHOLD_DB = -70.0   -- below this = empty channel, excluded
local SAMPLE_RATE          = 48000
local NUM_CHANNELS         = 1       -- mono
local BIT_DEPTH            = 24
local BYTES_PER_SAMPLE     = 3       -- 24-bit = 3 bytes

-- =============================================================================
-- GFX / GUI
-- =============================================================================

local WIN_W, WIN_H = 660, 480
gfx.init("Peak Analysis & WAV Copy — Debug", WIN_W, WIN_H, 0, 160, 160)
gfx.setfont(1, "Courier New", 14)
gfx.setfont(2, "Courier New", 16, "b")

local log       = {}
local status    = "Starting..."
local is_done   = false
local had_error = false
local log_file  = nil

local function log_line(s)
  table.insert(log, tostring(s))
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
  if log_file then
    log_file:write(tostring(s) .. "\n")
    log_file:flush()
  end
end

local function open_log_file(path)
  log_file = io.open(path, "w")
end

local function close_log_file()
  if log_file then
    log_file:close()
    log_file = nil
  end
end

local function set_status(s)
  status = s
  log_line("[STATUS] " .. s)
end

local function draw_gui()
  gfx.clear = 0x1a1a2e

  gfx.r, gfx.g, gfx.b, gfx.a = 0.12, 0.12, 0.28, 1
  gfx.rect(0, 0, WIN_W, 36)
  gfx.setfont(2)
  gfx.r, gfx.g, gfx.b = 0.9, 0.85, 1.0
  gfx.x, gfx.y = 10, 9
  gfx.drawstr("Peak Analysis & WAV Copy — Debug Log")

  local bc = had_error and {0.6,0.1,0.1} or (is_done and {0.1,0.5,0.2} or {0.1,0.3,0.55})
  gfx.r, gfx.g, gfx.b = bc[1], bc[2], bc[3]
  gfx.rect(0, WIN_H - 30, WIN_W, 30)
  gfx.setfont(1)
  gfx.r, gfx.g, gfx.b = 1, 1, 1
  gfx.x, gfx.y = 10, WIN_H - 22
  gfx.drawstr(">> " .. status)

  local line_h    = 16
  local log_top   = 44
  local log_bot   = WIN_H - 36
  local max_lines = math.floor((log_bot - log_top) / line_h)
  local start_i   = math.max(1, #log - max_lines + 1)

  for i = start_i, #log do
    local line = log[i]
    if     line:sub(1,8) == "[STATUS]" then gfx.r,gfx.g,gfx.b = 0.4, 0.85, 1.0
    elseif line:sub(1,7) == "[ERROR]"  then gfx.r,gfx.g,gfx.b = 1.0, 0.4,  0.4
    elseif line:sub(1,6) == "[WARN]"   then gfx.r,gfx.g,gfx.b = 1.0, 0.85, 0.3
    elseif line:sub(1,4) == "[OK]"     then gfx.r,gfx.g,gfx.b = 0.4, 1.0,  0.55
    elseif line:sub(1,6) == "[SKIP]"   then gfx.r,gfx.g,gfx.b = 0.6, 0.6,  0.6
    else                                    gfx.r,gfx.g,gfx.b = 0.78,0.82, 0.78
    end
    gfx.x = 10
    gfx.y = log_top + (i - start_i) * line_h
    gfx.drawstr(line)
  end

  gfx.update()
end

-- =============================================================================
-- State machine
-- =============================================================================

local STATE = {
  INIT           = 1,
  VALIDATE       = 2,
  SPLIT_ITEMS    = 3,
  COLLECT_TRACKS = 4,
  PROCESS_TRACKS = 5,   -- peak scan + WAV write, one track per tick
  WRITE_CSV      = 6,
  DONE           = 7,
  ERROR          = 8,
}

local state       = STATE.INIT
local proj        = 0
local sel_start, sel_end
local proj_path
local bounced_dir
local qualifying  = {}   -- {track, item, name}  — after split, one item per track
local results     = {}   -- {name, peak_db, trim_delta}  — only tracks with signal
local process_idx = 0

-- =============================================================================
-- Helpers
-- =============================================================================

local function round2(n)
  return math.floor(n * 100 + 0.5) / 100
end

local function lin_to_db(lin)
  if lin <= 0 then return -math.huge end
  return 20.0 * math.log(lin) / math.log(10)
end

local function safe_filename(name)
  return name:gsub('[\\/:*?"<>|]', "_"):gsub("%s+", "_")
end

local function abort(msg_str)
  log_line("[ERROR] " .. msg_str)
  set_status("ABORTED — see error above")
  had_error = true
  is_done   = true
  state     = STATE.ERROR
end

-- =============================================================================
-- WAV file writer
-- Writes a 24-bit mono WAV header then streams 24-bit little-endian samples.
-- The accessor returns 64-bit floats in [-1, 1]; we convert to 24-bit int.
-- =============================================================================

-- Build a WAV header for 24-bit mono PCM
-- data_bytes = total number of PCM data bytes (num_samples * 3)
local function make_wav_header(num_samples, srate)
  local data_bytes  = num_samples * BYTES_PER_SAMPLE * NUM_CHANNELS
  local block_align = BYTES_PER_SAMPLE * NUM_CHANNELS
  local byte_rate   = srate * block_align

  local function le16(n)
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
  end
  local function le32(n)
    return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
  end

  return "RIFF"
      .. le32(36 + data_bytes)   -- ChunkSize
      .. "WAVE"
      .. "fmt "
      .. le32(16)                -- Subchunk1Size (PCM)
      .. le16(1)                 -- AudioFormat = PCM
      .. le16(NUM_CHANNELS)
      .. le32(srate)
      .. le32(byte_rate)
      .. le16(block_align)
      .. le16(BIT_DEPTH)
      .. "data"
      .. le32(data_bytes)
end

-- Convert a float sample [-1,1] to a 3-byte little-endian 24-bit signed int string
-- Pre-compute the scale factor once
local SCALE_24 = 2^23 - 1   -- 8388607

local function float_to_24bit_le(v)
  -- Guard against non-numbers, NaN, and Inf
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
    return string.char(0, 0, 0)
  end
  -- clamp
  if v >  1.0 then v =  1.0 end
  if v < -1.0 then v = -1.0 end
  local i = math.floor(v * SCALE_24 + 0.5)
  -- two's complement for negative values in 24-bit range
  if i < 0 then i = i + 0x1000000 end
  return string.char(i & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF)
end

-- =============================================================================
-- Step: INIT
-- =============================================================================

local function step_init()
  set_status("Initialising...")
  log_line("[OK] Script started")
  state = STATE.VALIDATE
end

-- =============================================================================
-- Step: VALIDATE
-- =============================================================================

local function step_validate()
  set_status("Validating project & time selection...")

  sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  log_line(string.format("     Time selection: %.4f -> %.4f  (%.3f sec)",
           sel_start, sel_end, sel_end - sel_start))

  if sel_end <= sel_start then
    abort("No time selection found. Set a time selection and re-run.")
    return
  end
  log_line("[OK] Time selection valid")

  proj_path = reaper.GetProjectPath("")
  log_line("     Project path: " .. (proj_path ~= "" and proj_path or "(empty)"))
  if proj_path == "" then
    abort("Project must be saved to disk before running this script.")
    return
  end
  log_line("[OK] Project path valid")

  bounced_dir = proj_path .. "/bounced"
  reaper.RecursiveCreateDirectory(bounced_dir, 0)
  log_line("     Output folder: " .. bounced_dir)

  -- Open debug log file in project folder
  open_log_file(proj_path .. "/peak_analysis_debug.log")
  log_line("[OK] Debug log opened")

  state = STATE.SPLIT_ITEMS
end

-- =============================================================================
-- Step: SPLIT_ITEMS
-- Splits all items on leaf tracks at both the time selection start and end.
-- Uses action 40061 (Item: Split items at time selection) which operates on
-- all items that overlap the time selection regardless of track selection.
-- After this, the region inside the selection is a clean discrete item.
-- =============================================================================

local function step_split_items()
  set_status("Splitting items at time selection boundaries...")

  -- Deselect all tracks first so the split action is not scope-limited
  reaper.Main_OnCommand(40297, 0)   -- unselect all tracks
  reaper.Main_OnCommand(40289, 0)   -- unselect all items

  -- Action 40061: "Item: Split items at time selection"
  -- Splits every item that crosses sel_start or sel_end.
  reaper.Main_OnCommand(40061, 0)

  log_line("[OK] Items split at time selection boundaries")
  state = STATE.COLLECT_TRACKS
end

-- =============================================================================
-- Step: COLLECT_TRACKS
-- After the split, find the single item that sits inside the time selection
-- on each leaf track. Each qualifying track must have exactly one such item
-- and it must have a non-MIDI audio source.
-- =============================================================================

local function step_collect_tracks()
  set_status("Collecting candidate tracks...")

  local num_tracks = reaper.CountTracks(proj)
  log_line(string.format("     Total tracks in project: %d", num_tracks))
  if num_tracks == 0 then
    abort("No tracks found in project.")
    return
  end

  for ti = 0, num_tracks - 1 do
    local track        = reaper.GetTrack(proj, ti)
    local _, tname     = reaper.GetTrackName(track)
    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")

    if folder_depth == 1 then
      log_line(string.format("     [SKIP] %-28s (folder/bus)", tname))
    else
      local num_items      = reaper.CountTrackMediaItems(track)
      local audio_in_sel   = {}

      for ii = 0, num_items - 1 do
        local item     = reaper.GetTrackMediaItem(track, ii)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_len

        -- After the split, items that sit wholly inside the selection
        -- (with a small epsilon for floating point) are what we want.
        local epsilon = 0.0001
        local inside  = item_pos >= (sel_start - epsilon)
                     and item_end <= (sel_end   + epsilon)

        if inside then
          local take = reaper.GetActiveTake(item)
          if take and not reaper.TakeIsMIDI(take) then
            local src = reaper.GetMediaItemTake_Source(take)
            if src then
              table.insert(audio_in_sel, item)
            end
          end
        end
      end

      if #audio_in_sel == 0 then
        log_line(string.format("     [SKIP] %-28s (no audio items inside selection after split)", tname))
      elseif #audio_in_sel > 1 then
        -- Should not happen after a clean split, but guard anyway
        abort(string.format('Track "%s" has %d audio items inside the selection after split. Expected 1.',
              tname, #audio_in_sel))
        return
      else
        log_line(string.format("     [CAND] %-28s (1 audio item — will scan)", tname))
        table.insert(qualifying, {
          track = track,
          item  = audio_in_sel[1],
          name  = tname,
        })
      end
    end
  end

  log_line(string.format("[OK] %d candidate track(s) found", #qualifying))
  if #qualifying == 0 then
    abort("No candidate tracks found within the time selection after split.")
    return
  end

  process_idx = 1
  state = STATE.PROCESS_TRACKS
end

-- =============================================================================
-- Step: PROCESS_TRACKS  (one track per defer tick)
--
-- For each candidate track:
--   1. Open audio accessor on the take (pre-fader, pre-FX raw PCM)
--   2. Open output WAV file
--   3. Stream samples in chunks:
--        - accumulate max_lin for peak measurement
--        - convert float -> 24-bit LE and write to file
--   4. Once done:
--        - if peak <= SILENCE_THRESHOLD_DB: close & delete the file, skip track
--        - otherwise: finalise WAV header with correct data size, add to results
--
-- We write the WAV header at the start with a placeholder data size, then
-- seek back and rewrite it at the end. Lua's io library supports seek.
-- =============================================================================

local function step_process_one()
  if process_idx > #qualifying then
    log_line(string.format("[OK] Processing complete. %d track(s) have signal.", #results))
    if #results == 0 then
      abort("No tracks had signal above the silence threshold. All items appear empty.")
      return
    end
    state = STATE.WRITE_CSV
    return
  end

  local entry    = qualifying[process_idx]
  local item     = entry.item
  local tname    = entry.name
  local fname    = safe_filename(tname)
  local out_path = bounced_dir .. "/" .. fname .. ".wav"

  set_status(string.format("Scanning & copying: %s (%d/%d)...",
             tname, process_idx, #qualifying))

  -- Item bounds (already split, so these match the time selection)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len

  -- Clamp to time selection just in case of floating point edge
  local proj_start = math.max(sel_start, item_pos)
  local proj_end   = math.min(sel_end,   item_end)
  local win_len    = proj_end - proj_start

  log_line(string.format("     %-28s  window: %.4f -> %.4f  (%.4f sec)",
           tname, proj_start, proj_end, win_len))

  if win_len <= 0 then
    log_line(string.format("[SKIP] %-28s  zero-length window", tname))
    process_idx = process_idx + 1
    return
  end

  local take = reaper.GetActiveTake(item)
  local src  = reaper.GetMediaItemTake_Source(take)

  log_line(string.format("     DIAG: take=%s  src=%s", tostring(take), tostring(src)))
  if not take then
    log_line("     DIAG: No active take on item!")
  end

  -- Additional diagnostics for item/take positions
  local take_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local take_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  log_line(string.format("     item: pos=%.4f len=%.4f  (end=%.4f)",
           take_pos, take_len, take_pos + take_len))
  log_line(string.format("     time selection: sel_start=%.4f sel_end=%.4f", sel_start, sel_end))

  -- Source format diagnostics
  local src_srate = reaper.GetMediaSourceSampleRate(src)
  local src_channels = reaper.GetMediaSourceNumChannels(src)
  -- GetMediaSourceBitDepth added in REAPER 6.7; wrap for older versions
  local ok_bd, src_bitdepth = pcall(reaper.GetMediaSourceBitDepth, src)
  if not ok_bd then src_bitdepth = nil end
  log_line(string.format("     source: %d Hz, %d ch, %d bit",
           src_srate or 0, src_channels or 0, src_bitdepth or 0))

  -- Use source sample rate for GetMediaItemTake_Samples
  local srate = src_srate
  if not srate or srate <= 0 then
    srate = SAMPLE_RATE
    log_line(string.format("     srate not detected — defaulting to %d", SAMPLE_RATE))
  else
    log_line(string.format("     using source srate: %d Hz", srate))
  end

  log_line(string.format("     DIAG: GetMediaItemTake_Samples range: %.6f -> %.6f (win_len=%.6f)",
           proj_start, proj_end, proj_end - proj_start))

  local total_samples = math.floor(win_len * srate)
  log_line(string.format("     total samples to copy: %d  (win_len=%.6f)", total_samples, win_len))

  -- Open output file (overwrite)
  local fh, ferr = io.open(out_path, "wb")
  if not fh then
    log_line(string.format("[WARN] %-28s  cannot open output file: %s — skipping", tname, tostring(ferr)))
    process_idx = process_idx + 1
    return
  end

  -- Write WAV header with correct sample count up front
  fh:write(make_wav_header(total_samples, srate))

  -- Read samples directly from the source WAV file on disk
  -- This avoids the AudioAccessor/new_array type mismatch that returns denormals
  local source_file = reaper.GetMediaSourceFileName(src, "")
  log_line(string.format("     source file: %s", source_file))

  -- Parse WAV header to find data offset and format info
  local src_fh, src_err = io.open(source_file, "rb")
  if not src_fh then
    log_line(string.format("[WARN] %-28s  cannot open source file: %s — skipping", tname, tostring(src_err)))
    fh:close()
    process_idx = process_idx + 1
    return
  end

  -- Read RIFF header
  local riff = src_fh:read(4)
  src_fh:read(4) -- file size
  local wave = src_fh:read(4)
  if riff ~= "RIFF" or wave ~= "WAVE" then
    log_line(string.format("[WARN] %-28s  not a valid WAV file — skipping", tname))
    src_fh:close()
    fh:close()
    process_idx = process_idx + 1
    return
  end

  -- Find fmt and data chunks
  local data_offset = 0
  local data_size = 0
  local src_bit_depth = 24
  local src_channels = 1

  while true do
    local chunk_id = src_fh:read(4)
    if not chunk_id then break end
    local chunk_size_str = src_fh:read(4)
    if not chunk_size_str then break end
    local chunk_size = string.unpack("<I4", chunk_size_str)

    if chunk_id == "fmt " then
      local fmt_data = src_fh:read(chunk_size)
      if fmt_data and #fmt_data >= 16 then
        local audio_fmt = string.unpack("<I2", fmt_data, 1)
        src_channels = string.unpack("<I2", fmt_data, 3)
        -- sample rate at offset 5 (4 bytes)
        -- bit depth at offset 14 (2 bytes)
        src_bit_depth = string.unpack("<I2", fmt_data, 15)
        log_line(string.format("     WAV format: fmt=%d ch=%d bit=%d", audio_fmt, src_channels, src_bit_depth))
      end
    elseif chunk_id == "data" then
      data_offset = src_fh:seek()
      data_size = chunk_size
      break
    else
      -- Skip unknown chunk
      src_fh:seek("cur", chunk_size)
    end
  end

  if data_offset == 0 then
    log_line(string.format("[WARN] %-28s  no data chunk found in WAV — skipping", tname))
    src_fh:close()
    fh:close()
    process_idx = process_idx + 1
    return
  end

  log_line(string.format("     WAV data: offset=%d size=%d bytes", data_offset, data_size))

  -- Calculate byte positions for the time selection
  -- The source file IS the project audio, so project time maps directly to source time
  local src_bytes_per_sample = src_bit_depth / 8
  local src_block_align = src_bytes_per_sample * src_channels

  -- Convert project time directly to source sample position
  local src_sel_start = proj_start * srate
  local src_sel_end = proj_end * srate
  local src_start_byte = data_offset + math.floor(src_sel_start) * src_block_align
  local src_end_byte = data_offset + math.floor(src_sel_end) * src_block_align
  local bytes_to_read = src_end_byte - src_start_byte
  local samples_to_read = math.floor(bytes_to_read / src_block_align)

  -- Clamp to file bounds
  if src_start_byte < data_offset then
    src_start_byte = data_offset
    samples_to_read = math.floor((src_end_byte - src_start_byte) / src_block_align)
  end
  if src_end_byte > data_offset + data_size then
    src_end_byte = data_offset + data_size
    samples_to_read = math.floor((src_end_byte - src_start_byte) / src_block_align)
  end

  log_line(string.format("     src_sel_start=%.2f src_sel_end=%.2f", src_sel_start, src_sel_end))
  log_line(string.format("     byte range: %d -> %d (%d bytes, %d samples, file_size=%d)",
           src_start_byte, src_end_byte, bytes_to_read, samples_to_read, data_size))

  if samples_to_read <= 0 then
    log_line(string.format("[WARN] %-28s  no samples in selection range — skipping", tname))
    src_fh:close()
    fh:close()
    process_idx = process_idx + 1
    return
  end

  -- Update WAV header with actual sample count
  fh:close()
  fh = io.open(out_path, "wb")
  fh:write(make_wav_header(samples_to_read, srate))

  -- Seek to start position and read samples
  src_fh:seek("set", src_start_byte)

  -- Read samples: normalize to float, track peak, build output in one pass
  local max_lin = 0.0
  local pcm_chunk = {}
  local CHUNK_BYTES = 4096 * src_block_align
  local samples_read = 0
  local first_samples = {}
  local mid_sample = 0

  while samples_read < samples_to_read do
    local bytes_left = src_end_byte - src_fh:seek()
    if bytes_left <= 0 then break end
    local bytes_to_read_now = math.min(CHUNK_BYTES, bytes_left)
    local raw = src_fh:read(bytes_to_read_now)
    if not raw then break end

    local num_samples_in_chunk = math.floor(#raw / src_block_align)
    for s = 0, num_samples_in_chunk - 1 do
      local byte_idx = s * src_block_align + 1
      local sample_val = 0

      if src_bit_depth == 24 then
        local b1 = raw:byte(byte_idx)
        local b2 = raw:byte(byte_idx + 1)
        local b3 = raw:byte(byte_idx + 2)
        sample_val = b1 + b2 * 256 + b3 * 65536
        if sample_val >= 0x800000 then
          sample_val = sample_val - 0x1000000
        end
        sample_val = sample_val / 8388607.0
      elseif src_bit_depth == 16 then
        local b1 = raw:byte(byte_idx)
        local b2 = raw:byte(byte_idx + 1)
        sample_val = b1 + b2 * 256
        if sample_val >= 0x8000 then
          sample_val = sample_val - 0x10000
        end
        sample_val = sample_val / 32767.0
      end

      local av = sample_val < 0 and -sample_val or sample_val
      if av > max_lin then max_lin = av end
      samples_read = samples_read + 1
      if samples_read <= 5 then first_samples[samples_read] = sample_val end
      if samples_read == 351294 then mid_sample = sample_val end
      pcm_chunk[samples_read] = float_to_24bit_le(sample_val)
    end
  end

  src_fh:close()

  log_line(string.format("     DIAG first 5: %.6f %.6f %.6f %.6f %.6f",
           first_samples[1] or 0, first_samples[2] or 0, first_samples[3] or 0,
           first_samples[4] or 0, first_samples[5] or 0))
  log_line(string.format("     DIAG mid sample[351294]: %.6f", mid_sample))
  log_line(string.format("     samples read: %d  max_linear: %.8f", samples_read, max_lin))

  fh:write(table.concat(pcm_chunk))
  fh:close()

  log_line(string.format("     samples processed: %d  |  max linear: %.8f", samples_read, max_lin))

  local peak_db = lin_to_db(max_lin)
  log_line(string.format("     peak: %.4f dBFS  (threshold: %.0f dBFS)",
           peak_db, SILENCE_THRESHOLD_DB))

  -- Silence gate — delete the output file and skip this track
  if peak_db <= SILENCE_THRESHOLD_DB then
    log_line(string.format("[SKIP] %-28s  below threshold — empty channel, file deleted", tname))
    os.remove(out_path)
    process_idx = process_idx + 1
    return
  end

  -- Track has real signal
  local trim_delta = TARGET_DB - peak_db
  log_line(string.format("[OK]  %-28s  peak=%.2f dBFS  trim=%+.2f dB  -> %s.wav",
           tname, round2(peak_db), round2(trim_delta), fname))

  table.insert(results, {
    name       = tname,
    peak_db    = round2(peak_db),
    trim_delta = round2(trim_delta),
  })

  process_idx = process_idx + 1
end

-- =============================================================================
-- Step: WRITE_CSV
-- =============================================================================

local function step_write_csv()
  set_status("Writing CSV...")

  local csv_path = proj_path .. "/peak_analysis.csv"
  local fh, err  = io.open(csv_path, "w")
  if not fh then
    abort("Could not write CSV: " .. tostring(err))
    return
  end

  fh:write("Track Name,Peak dBFS,Set Trim To\n")
  for _, r in ipairs(results) do
    local safe_name = r.name:find(",") and ('"' .. r.name .. '"') or r.name
    local trim_str  = (r.trim_delta >= 0 and "+" or "") .. string.format("%.2f", r.trim_delta)
    fh:write(string.format('%s,%.2f,%s\n', safe_name, r.peak_db, trim_str))
  end
  fh:close()

  log_line(string.format("[OK] CSV written -> %s  (%d track(s))", csv_path, #results))

  set_status(string.format("Complete! %d track(s) with signal. %d skipped (empty).",
             #results, #qualifying - #results))

  -- Write summary to debug log
  log_line("")
  log_line("========================================")
  log_line(string.format("RESULTS: %d track(s) with signal, %d skipped",
             #results, #qualifying - #results))
  log_line("========================================")
  for _, r in ipairs(results) do
    log_line(string.format("  %-30s  peak=%+.2f dBFS  trim=%+.2f dB",
             r.name, r.peak_db, r.trim_delta))
  end
  log_line("")
  log_line("Debug log saved to: " .. proj_path .. "/peak_analysis_debug.log")
  close_log_file()

  is_done = true
  state   = STATE.DONE
end

-- =============================================================================
-- Main deferred loop
-- =============================================================================

local function main_loop()
  if gfx.getchar() == -1 then
    return
  end

  if     state == STATE.INIT           then step_init()
  elseif state == STATE.VALIDATE       then step_validate()
  elseif state == STATE.SPLIT_ITEMS    then step_split_items()
  elseif state == STATE.COLLECT_TRACKS then step_collect_tracks()
  elseif state == STATE.PROCESS_TRACKS then step_process_one()
  elseif state == STATE.WRITE_CSV      then step_write_csv()
  end

  draw_gui()
  reaper.defer(main_loop)
end

reaper.defer(main_loop)
