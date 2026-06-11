-- @description Analyze selected tracks and set JSFX trim via gmem (RMS/Peak-aware)
-- @version 0.2
-- @author ingeniousWizard
-- @about
--   Select tracks, define a time selection, and run while the transport is stopped.
--   Analyzes RMS/Peak/Crest, classifies dynamics, computes target gain, assigns the
--   JSFX gmem slot from each track's project number, mutes the master, starts a
--   brief playback so the JSFX @block reads gmem, then stops, bakes the gain into
--   the JSFX Manual trim slider, restores master mute, and clears the gmem slot.

local FX_NAME          = "JS: IGR_StageTrim_gmem"
local GMEM_SLOT_BASE   = 64
local GMEM_SLOT_STRIDE = 4
local BAKE_WAIT_SEC    = 0.35  -- seconds of playback for JSFX @block to converge

local RMS_TARGET_DB        = -18.0
local PEAK_TARGET_LESS_DESIRED_DB = -12
local PEAK_TARGET_DYN_DESIRED_DB  = -6
local PEAK_TARGET_LESS_TOL_DB     = 2.0
local PEAK_TARGET_DYN_TOL_DB      = 1.5

local CREST_DYNAMIC_THRESHOLD_DB = 11.0
local CREST_WINDOW_SEC           = 0.1
local SILENCE_PEAK_DB            = -90.0

local ANALYSIS_BLOCK_SAMPLES = 2048
local EPS = 1e-12

-- deferred state lives at module scope so the defer callback can reference it
local _state = nil

-- ── helpers ────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function lin_to_db(v)
	return 20.0 * math.log(math.max(EPS, v), 10)
end

local function db_to_lin(db)
	return 10 ^ (db / 20.0)
end

local function percentile(values, p)
	if #values == 0 then return nil end
	local t = {}
	for i = 1, #values do t[i] = values[i] end
	table.sort(t)
	local pos = clamp(p, 0.0, 1.0) * (#t - 1) + 1
	local i0, i1 = math.floor(pos), math.ceil(pos)
	if i0 == i1 then return t[i0] end
	return t[i0] + (t[i1] - t[i0]) * (pos - i0)
end

local function get_project_samplerate()
	local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
	return (sr and sr > 0) and sr or 48000
end

-- ── slot: use track project number so assignment is stable and automatic ───

local function track_slot(track)
	local n = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
	return clamp(n, 1, 256)
end

-- ── JSFX management ────────────────────────────────────────────────────────

local function is_trim_fx_name(name)
	return tostring(name):find("IGR_StageTrim_gmem", 1, true) ~= nil
end

local function collect_trim_fx_indices(track)
	local indices = {}
	local fx_count = reaper.TrackFX_GetCount(track)
	for i = 0, fx_count - 1 do
		local ok, fx_name = reaper.TrackFX_GetFXName(track, i, "")
		if ok and is_trim_fx_name(fx_name) then
			indices[#indices + 1] = i
		end
	end
	return indices
end

local function ensure_stage_jsfx(track, slot)
	local trim_indices = collect_trim_fx_indices(track)

	if #trim_indices == 0 then
		local added = reaper.TrackFX_AddByName(track, FX_NAME, false, 1)
		if added < 0 then
			return nil, "Could not find/add JSFX: " .. FX_NAME
		end
		trim_indices = collect_trim_fx_indices(track)
		if #trim_indices == 0 then
			return nil, "Could not locate JSFX after adding: " .. FX_NAME
		end
	end

	-- Keep top-most trim instance, force it to slot 0, then delete any duplicates.
	local keep_idx = trim_indices[1]
	for i = 2, #trim_indices do
		if trim_indices[i] < keep_idx then
			keep_idx = trim_indices[i]
		end
	end

	if keep_idx ~= 0 then
		reaper.TrackFX_CopyToTrack(track, keep_idx, track, 0, false)
		-- Original shifts to +1 when copied to front.
		reaper.TrackFX_Delete(track, keep_idx + 1)
	end

	trim_indices = collect_trim_fx_indices(track)
	for i = #trim_indices, 1, -1 do
		local idx = trim_indices[i]
		if idx ~= 0 then
			reaper.TrackFX_Delete(track, idx)
		end
	end

	local fx_idx = 0

	-- Verify the first FX is our trim plugin.
	local ok_name, fx_name = reaper.TrackFX_GetFXName(track, 0, "")
	if not ok_name or not tostring(fx_name):find("IGR_StageTrim_gmem", 1, true) then
		return nil, "Could not place IGR_StageTrim_gmem in first FX slot."
	end

	-- slider1 (idx 0): Slot – auto-set from track number
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 0, (slot - 1) / 255.0)
	-- slider2 (idx 1): gmem Mode → Read gmem
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 1, 0.0)
	-- slider4 (idx 3): Source → Auto (reads gmem)
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 3, 0.0)
	return fx_idx, nil
end

local function bake_jsfx(track, gain_db)
	local ok_name, fx_name = reaper.TrackFX_GetFXName(track, 0, "")
	if not ok_name or not is_trim_fx_name(fx_name) then
		return
	end
	local fx_idx = 0
	-- slider3 (idx 2): Trim dB – bake computed gain
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 2, clamp((gain_db + 24.0) / 48.0, 0.0, 1.0))
	-- slider4 (idx 3): Source → Manual – stop reading gmem
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 3, 1.0)
	-- slider2 (idx 1): gmem Mode → Bypass
	reaper.TrackFX_SetParamNormalized(track, fx_idx, 1, 1.0)
end

-- ── audio analysis ─────────────────────────────────────────────────────────

local function analyze_track_range(track, t0, t1, sample_rate)
	local channels = math.max(1, math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 2))
	local accessor  = reaper.CreateTrackAudioAccessor(track)
	if not accessor then
		return nil, "Could not create track audio accessor."
	end

	local buf        = reaper.new_array(ANALYSIS_BLOCK_SAMPLES * channels)
	local total      = 0
	local sum_sq     = 0.0
	local peak       = 0.0
	local crest_wins = {}
	local win_len    = math.max(1, math.floor(sample_rate * CREST_WINDOW_SEC + 0.5))
	local win_n      = 0
	local win_sq     = 0.0
	local win_pk     = 0.0

	local t = t0
	while t < t1 do
		local want = math.min(ANALYSIS_BLOCK_SAMPLES, math.max(1, math.floor((t1 - t) * sample_rate)))
		buf.clear()
		if reaper.GetAudioAccessorSamples(accessor, sample_rate, channels, t, want, buf) ~= 1 then
			break
		end

		for s = 0, want - 1 do
			local sq, spk = 0.0, 0.0
			for ch = 0, channels - 1 do
				local v  = buf[(s * channels + ch) + 1]
				sq = sq + v * v
				local av = math.abs(v)
				if av > spk then spk = av end
			end
			sq     = sq / channels
			sum_sq = sum_sq + sq
			total  = total + 1
			if spk > peak then peak = spk end

			win_sq = win_sq + sq
			win_n  = win_n + 1
			if spk > win_pk then win_pk = spk end
			if win_n >= win_len then
				crest_wins[#crest_wins + 1] = lin_to_db(win_pk) - lin_to_db(math.sqrt(win_sq / win_n))
				win_n, win_sq, win_pk = 0, 0.0, 0.0
			end
		end
		t = t + (want / sample_rate)
	end

	if win_n > 0 then
		crest_wins[#crest_wins + 1] = lin_to_db(win_pk) - lin_to_db(math.sqrt(win_sq / win_n))
	end

	reaper.DestroyAudioAccessor(accessor)

	if total < 64 then
		return nil, "Not enough samples in time selection on this track."
	end

	if peak < db_to_lin(SILENCE_PEAK_DB) then
		return nil, string.format("No audible audio in time selection (peak below %.0f dBFS).", SILENCE_PEAK_DB)
	end

	local rms_db  = lin_to_db(math.sqrt(sum_sq / total))
	local peak_db = lin_to_db(peak)
	local crest   = peak_db - rms_db
	return {
		rms_db    = rms_db,
		peak_db   = peak_db,
		crest_db  = crest,
		crest_p50 = percentile(crest_wins, 0.5) or crest,
		crest_p90 = percentile(crest_wins, 0.9) or crest,
	}, nil
end

-- ── gain staging logic ─────────────────────────────────────────────────────

local function classify_and_gain(m)
	local dynamic = (m.crest_p50 >= CREST_DYNAMIC_THRESHOLD_DB)
	             or (m.crest_p90 >= CREST_DYNAMIC_THRESHOLD_DB + 2.0)
	local peak_desired = dynamic and PEAK_TARGET_DYN_DESIRED_DB or PEAK_TARGET_LESS_DESIRED_DB
	local peak_tol = dynamic and PEAK_TARGET_DYN_TOL_DB or PEAK_TARGET_LESS_TOL_DB
	local pk_min = peak_desired - peak_tol
	local pk_max = peak_desired + peak_tol
	local gain   = clamp(
		clamp(RMS_TARGET_DB - m.rms_db, pk_min - m.peak_db, pk_max - m.peak_db),
		-24.0, 24.0)
	return dynamic, gain, peak_desired, pk_min, pk_max
end

-- ── deferred bake / cleanup ────────────────────────────────────────────────

local function deferred_bake()
	local s = _state
	if not s then return end

	if reaper.time_precise() - s.play_start < BAKE_WAIT_SEC then
		reaper.defer(deferred_bake)
		return
	end

	-- stop the brief playback and restore cursor
	reaper.OnStopButton()
	reaper.SetEditCurPos2(0, s.orig_cursor, false, false)

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)

	for i, track in ipairs(s.tracks) do
		-- bake gain into JSFX and switch to Manual (stops reading gmem)
		bake_jsfx(track, s.gains[i])

		-- clear gmem slot; safe now that JSFX is in Manual mode
		local base = GMEM_SLOT_BASE + (s.slots[i] - 1) * GMEM_SLOT_STRIDE
		reaper.gmem_write(base + 0, 0.0)
		reaper.gmem_write(base + 1, 0.0)
		reaper.gmem_write(base + 2, 0.0)
		reaper.gmem_write(base + 3, 0.0)

	end

	if s.master_track then
		reaper.SetMediaTrackInfo_Value(s.master_track, "B_MUTE", s.orig_master_mute)
	end

	for i = 1, #s.all_tracks do
		reaper.SetMediaTrackInfo_Value(s.all_tracks[i], "B_MUTE", s.all_track_mutes[i])
	end

	reaper.PreventUIRefresh(-1)
	reaper.Undo_EndBlock("Auto gain stage – bake trim to JSFX", -1)
	reaper.TrackList_AdjustWindows(false)
	reaper.UpdateArrange()

	reaper.ShowConsoleMsg("")
	reaper.ShowConsoleMsg(s.summary .. "\n")
	reaper.MB(s.summary, "Auto Gain Stage", 0)

	_state = nil
end

-- ── main ───────────────────────────────────────────────────────────────────

local function main()
	if reaper.GetPlayState() ~= 0 then
		reaper.MB("Stop the transport before running Auto Gain Stage.", "Auto Gain Stage", 0)
		return
	end

	local tracks = {}
	for i = 0, reaper.CountSelectedTracks(0) - 1 do
		tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i)
	end
	if #tracks == 0 then
		reaper.MB("Select at least one track.", "Auto Gain Stage", 0)
		return
	end

	local t0, t1 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
	if not t0 or not t1 or t1 <= t0 then
		reaper.MB("Create a non-empty time selection first.", "Auto Gain Stage", 0)
		return
	end

	local sr    = get_project_samplerate()
	local nonce = math.max(1, math.floor(reaper.time_precise() * 1000000) % 2147483647)

	-- ── analyse, assign slots, write gmem ────────────────────────────────
	local state = {
		tracks           = {},
		slots            = {},
		gains            = {},
		master_track     = nil,
		orig_master_mute = 0,
		all_tracks       = {},
		all_track_mutes  = {},
		summary          = "",
		play_start       = 0.0,
		orig_cursor      = reaper.GetCursorPosition(),
	}

	local lines     = {}
	local processed = 0

	for i = 1, #tracks do
		local track = tracks[i]
		local _, name = reaper.GetTrackName(track, "")
		if not name or name == "" then name = string.format("Track %d", i) end

		local slot = track_slot(track)
		if slot > 256 then
			lines[#lines + 1] = string.format(
				"%s: SKIP (track number %d exceeds slot limit 256)", name, slot)
			goto continue
		end

		local _, fx_err = ensure_stage_jsfx(track, slot)
		if fx_err then
			lines[#lines + 1] = string.format("%s: ERROR (%s)", name, fx_err)
			goto continue
		end

		local metrics, err = analyze_track_range(track, t0, t1, sr)
		if err then
			lines[#lines + 1] = string.format("%s: SKIP (%s)", name, err)
			goto continue
		end

		local is_dyn, gain_db, peak_desired, pk_min, pk_max = classify_and_gain(metrics)

		-- write gmem: payload first, nonce last to minimise audio-thread race
		local base = GMEM_SLOT_BASE + (slot - 1) * GMEM_SLOT_STRIDE
		reaper.gmem_write(base + 0, gain_db)
		reaper.gmem_write(base + 2, metrics.rms_db)
		reaper.gmem_write(base + 3, metrics.peak_db)
		reaper.gmem_write(base + 1, nonce)  -- nonce written last

		state.tracks[#state.tracks + 1] = track
		state.slots[#state.slots + 1]   = slot
		state.gains[#state.gains + 1]   = gain_db

		processed = processed + 1
		lines[#lines + 1] = string.format(
			"%s (slot %d): RMS %.1f dBFS, Peak %.1f dBFS, Crest %.1f dB, %s -> Gain %+.1f dB (peak desired %.1f, range %.1f..%.1f)",
			name, slot,
			metrics.rms_db, metrics.peak_db, metrics.crest_p50,
			is_dyn and "dynamic" or "less-dynamic",
			gain_db, peak_desired, pk_min, pk_max)

		::continue::
	end

	if processed == 0 then
		reaper.MB(
			"No tracks could be processed.\n\n" .. table.concat(lines, "\n"),
			"Auto Gain Stage", 0)
		return
	end

	state.summary = string.format(
		"Processed %d/%d selected tracks.\n\n%s",
		processed, #tracks, table.concat(lines, "\n"))

	-- ── mute master then brief play so JSFX @block reads gmem values ─────
	state.master_track = reaper.GetMasterTrack(0)
	if state.master_track then
		state.orig_master_mute = reaper.GetMediaTrackInfo_Value(state.master_track, "B_MUTE")
		reaper.SetMediaTrackInfo_Value(state.master_track, "B_MUTE", 1)
	end

	-- Extra safety: mute all tracks so hardware-output routed tracks are silent too.
	local total_tracks = reaper.CountTracks(0)
	for i = 0, total_tracks - 1 do
		local tr = reaper.GetTrack(0, i)
		state.all_tracks[#state.all_tracks + 1] = tr
		state.all_track_mutes[#state.all_track_mutes + 1] = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE")
		reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
	end

	reaper.SetEditCurPos2(0, t0, false, false)
	reaper.OnPlayButton()

	state.play_start = reaper.time_precise()
	_state = state
	reaper.defer(deferred_bake)
end

main()
