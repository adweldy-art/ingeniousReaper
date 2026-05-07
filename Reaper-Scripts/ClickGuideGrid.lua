-- Guide WAV matcher for Reaper
-- Detects callout islands in one continuous guide item, matches each island to
-- a source WAV by envelope similarity, and places markers at island start.

local THRESHOLD_DB = -40
local WINDOW_SIZE_MS = 50
local MIN_ISLAND_MS = 220
local MERGE_GAP_MS = 120
local ANALYSIS_RATE = 4000
local MATCH_THRESHOLD = 0.62
local PLACE_UNMATCHED_MARKERS = true
local SOURCE_FOLDER = "D:/English Guides/Song Sections"

local function msg(m)
    reaper.ShowConsoleMsg(tostring(m) .. "\n")
end

local function db2lin(db)
    return 10 ^ (db / 20)
end

local function path_join(folder, filename)
    local last_char = folder:sub(-1)
    if last_char == "\\" or last_char == "/" then
        return folder .. filename
    end
    local sep = package.config:sub(1, 1)
    return folder .. sep .. filename
end

local function collect_wav_files(folder)
    local files = {}
    local i = 0
    while true do
        local file = reaper.EnumerateFiles(folder, i)
        if not file then
            break
        end
        if file:lower():match("%.wav$") then
            files[#files + 1] = file
        end
        i = i + 1
    end
    table.sort(files)
    return files
end

local function get_envelope_from_accessor(accessor, start_time, duration, analysis_rate, channels)
    local window_sec = WINDOW_SIZE_MS / 1000
    local samples_per_window = math.max(16, math.floor(analysis_rate * window_sec))
    local num_windows = math.floor(duration / window_sec)
    local envelope = {}
    local times = {}
    local buffer = reaper.new_array(samples_per_window * channels)

    for i = 0, num_windows - 1 do
        local t = start_time + (i * window_sec)
        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(accessor, analysis_rate, channels, t, samples_per_window, buffer)
        if ok ~= 1 then
            break
        end

        local sum_sq = 0.0
        local count = 0
        for s = 0, samples_per_window - 1 do
            local mono = 0.0
            for ch = 0, channels - 1 do
                local idx = (s * channels + ch) + 1
                mono = mono + buffer[idx]
            end
            mono = mono / channels
            sum_sq = sum_sq + (mono * mono)
            count = count + 1
        end

        if count > 0 then
            envelope[#envelope + 1] = math.sqrt(sum_sq / count)
            times[#times + 1] = t
        end
    end

    return envelope, times
end

local function detect_islands(envelope, times)
    local threshold_lin = db2lin(THRESHOLD_DB)
    local window_sec = WINDOW_SIZE_MS / 1000
    local merge_gap_windows = math.max(0, math.floor((MERGE_GAP_MS / 1000) / window_sec + 0.5))
    local min_windows = math.max(1, math.floor((MIN_ISLAND_MS / 1000) / window_sec + 0.5))

    local raw = {}
    local in_island = false
    local start_i = 1

    for i = 1, #envelope do
        if envelope[i] >= threshold_lin then
            if not in_island then
                in_island = true
                start_i = i
            end
        elseif in_island then
            in_island = false
            raw[#raw + 1] = { start_idx = start_i, end_idx = i - 1 }
        end
    end

    if in_island then
        raw[#raw + 1] = { start_idx = start_i, end_idx = #envelope }
    end

    if #raw == 0 then
        return {}
    end

    local merged = { raw[1] }
    for i = 2, #raw do
        local prev = merged[#merged]
        local cur = raw[i]
        local gap = cur.start_idx - prev.end_idx - 1
        if gap <= merge_gap_windows then
            prev.end_idx = cur.end_idx
        else
            merged[#merged + 1] = cur
        end
    end

    local islands = {}
    for _, seg in ipairs(merged) do
        local n = seg.end_idx - seg.start_idx + 1
        if n >= min_windows then
            local slice = {}
            for i = seg.start_idx, seg.end_idx do
                slice[#slice + 1] = envelope[i]
            end

            islands[#islands + 1] = {
                start_idx = seg.start_idx,
                end_idx = seg.end_idx,
                start_time = times[seg.start_idx],
                end_time = times[seg.end_idx] + window_sec,
                env = slice,
            }
        end
    end

    return islands
end

local function norm_dot(a, b, offset)
    local dot = 0.0
    local na = 0.0
    local nb = 0.0

    for i = 1, #a do
        local av = a[i]
        local bv = b[i + offset]
        dot = dot + (av * bv)
        na = na + (av * av)
        nb = nb + (bv * bv)
    end

    if na <= 1e-12 or nb <= 1e-12 then
        return -1
    end

    return dot / math.sqrt(na * nb)
end

local function best_match_score(env_a, env_b)
    if #env_a == 0 or #env_b == 0 then
        return -1
    end

    local short = env_a
    local long = env_b
    if #env_a > #env_b then
        short = env_b
        long = env_a
    end

    local best = -1
    for offset = 0, #long - #short do
        local s = norm_dot(short, long, offset)
        if s > best then
            best = s
        end
    end

    return best
end

local function build_source_envelope(temp_track, full_path)
    local src = reaper.PCM_Source_CreateFromFile(full_path)
    if not src then
        return nil, "load failed"
    end

    local src_len = reaper.GetMediaSourceLength(src)
    if not src_len or src_len <= 0 then
        return nil, "empty source"
    end

    local src_channels = math.max(1, reaper.GetMediaSourceNumChannels(src) or 1)

    local item = reaper.AddMediaItemToTrack(temp_track)
    if not item then
        return nil, "temp item failed"
    end

    local take = reaper.AddTakeToMediaItem(item)
    if not take then
        reaper.DeleteTrackMediaItem(temp_track, item)
        return nil, "temp take failed"
    end

    reaper.SetMediaItemTake_Source(take, src)
    reaper.SetMediaItemPosition(item, 0, false)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", src_len)
    reaper.UpdateItemInProject(item)

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then
        reaper.DeleteTrackMediaItem(temp_track, item)
        return nil, "source accessor failed"
    end

    local env = select(1, get_envelope_from_accessor(accessor, 0, src_len, ANALYSIS_RATE, src_channels))

    reaper.DestroyAudioAccessor(accessor)
    reaper.DeleteTrackMediaItem(temp_track, item)

    if #env == 0 then
        return nil, "no envelope"
    end

    return env, nil
end

local function main()
    reaper.ClearConsole()

    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        msg("Select one guide audio item first.")
        return
    end

    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then
        msg("Selected item must have an audio take.")
        return
    end

    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if not item_len or item_len <= 0 then
        msg("Selected item has no audio length.")
        return
    end

    local files = collect_wav_files(SOURCE_FOLDER)
    if #files == 0 then
        msg("No WAV files found in source folder: " .. SOURCE_FOLDER)
        return
    end

    local src = reaper.GetMediaItemTake_Source(take)
    if not src then
        msg("Could not access selected take source.")
        return
    end

    local channels = math.max(1, reaper.GetMediaSourceNumChannels(src) or 1)

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then
        msg("Could not create audio accessor for selected take.")
        return
    end

    msg("Analyzing guide item...")
    local guide_env, guide_times = get_envelope_from_accessor(accessor, item_pos, item_len, ANALYSIS_RATE, channels)
    reaper.DestroyAudioAccessor(accessor)

    if #guide_env == 0 then
        msg("Guide envelope extraction failed.")
        return
    end

    local islands = detect_islands(guide_env, guide_times)
    if #islands == 0 then
        msg("No islands above threshold.")
        return
    end

    msg("Guide islands found: " .. tostring(#islands))
    msg("Source WAV files found: " .. tostring(#files))

    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()

    local temp_track_idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(temp_track_idx, true)
    local temp_track = reaper.GetTrack(0, temp_track_idx)

    local source_env_cache = {}
    local source_failures = {}

    for i = 1, #files do
        local file = files[i]
        local full_path = path_join(SOURCE_FOLDER, file)
        local env, err = build_source_envelope(temp_track, full_path)
        if env then
            source_env_cache[file] = env
        else
            source_failures[#source_failures + 1] = file .. " (" .. tostring(err) .. ")"
        end
    end

    local matched = 0
    local unmatched = 0

    for i = 1, #islands do
        local island = islands[i]
        local best_file = nil
        local best_score = -1

        for _, file in ipairs(files) do
            local src_env = source_env_cache[file]
            if src_env then
                local score = best_match_score(island.env, src_env)
                if score > best_score then
                    best_score = score
                    best_file = file
                end
            end
        end

        local marker_time = island.start_time
        if best_file and best_score >= MATCH_THRESHOLD then
            reaper.AddProjectMarker2(0, false, marker_time, 0, best_file, -1, 0)
            matched = matched + 1
        elseif PLACE_UNMATCHED_MARKERS then
            local label = "UNMATCHED"
            if best_file and best_score > -1 then
                label = string.format("UNMATCHED (%s %.2f)", best_file, best_score)
            end
            reaper.AddProjectMarker2(0, false, marker_time, 0, label, -1, 0)
            unmatched = unmatched + 1
        end
    end

    if temp_track then
        reaper.DeleteTrack(temp_track)
    end

    reaper.Undo_EndBlock("Guide callout WAV match markers (POC)", -1)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()

    msg("Done.")
    msg("Matched islands: " .. tostring(matched))
    msg("Unmatched islands: " .. tostring(unmatched))
    msg("Source read failures: " .. tostring(#source_failures))
    if #source_failures > 0 then
        local max_list = math.min(8, #source_failures)
        msg("First " .. tostring(max_list) .. " source failures:")
        for i = 1, max_list do
            msg("  - " .. source_failures[i])
        end
    end
end

main()