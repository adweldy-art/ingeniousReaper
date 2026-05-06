-- @description Build tempo map from recorded click track (interactive segmented workflow)
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Select one recorded click audio item and run this script.
--   The script auto-detects click onsets, proposes click-rate change segments,
--   asks for pulse note value and time signature per segment, then writes a
--   new tempo map. It also applies item/track no-stretch timebase safeguards.

local ANALYSIS_RATE = 4000
local TARGET_ENV_HZ = 500
local MIN_ONSET_GAP_SEC = 0.035
local CHANGE_RATIO_HARD = 1.6
local CHANGE_RATIO_SOFT = 0.12
local MIN_SEGMENT_ONSETS = 6
local WINDOW_IOI = 4
local TRANSIENT_REFINE_WIN_SEC = 0.008

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv(s)
	local out = {}
	for part in tostring(s):gmatch("[^,]*") do
		out[#out + 1] = trim(part)
	end
	return out
end

local function parse_int(s)
	local n = tonumber(trim(s or ""))
	if not n then
		return nil
	end
	return math.floor(n + 0.5)
end

local function median(values)
	if #values == 0 then
		return nil
	end

	local t = {}
	for i = 1, #values do
		t[i] = values[i]
	end
	table.sort(t)

	local mid = math.floor(#t / 2)
	if #t % 2 == 1 then
		return t[mid + 1]
	end

	return (t[mid] + t[mid + 1]) * 0.5
end

local function pulse_to_pulses_per_quarter(token)
	local t = trim((token or ""):lower())

	if t == "" then
		return nil
	end

	if t == "q" or t == "quarter" or t == "1/4" then
		return 1
	end

	if t == "e" or t == "8" or t == "eighth" or t == "1/8" then
		return 2
	end

	if t == "s" or t == "16" or t == "sixteenth" or t == "1/16" then
		return 4
	end

	if t == "h" or t == "half" or t == "1/2" then
		return 0.5
	end

	if t == "d8" or t == "dotted8" or t == "dotted eighth" then
		return 1.5
	end

	local numeric = tonumber(t)
	if numeric and numeric > 0 then
		return numeric
	end

	if t:match("^custom:%s*[%d%.]+$") then
		local v = tonumber(t:match("^custom:%s*([%d%.]+)$"))
		if v and v > 0 then
			return v
		end
	end

	return nil
end

local function format_timecode(sec)
	local s = math.max(0, sec or 0)
	local h = math.floor(s / 3600)
	local m = math.floor((s - h * 3600) / 60)
	local rs = s - h * 3600 - m * 60
	return string.format("%02d:%02d:%06.3f", h, m, rs)
end

local function get_selected_audio_take()
	local item = reaper.GetSelectedMediaItem(0, 0)
	if not item then
		return nil, nil, "Select exactly one recorded click media item first."
	end

	if reaper.CountSelectedMediaItems(0) ~= 1 then
		return nil, nil, "Select exactly one media item."
	end

	local take = reaper.GetActiveTake(item)
	if not take then
		return nil, nil, "The selected item has no active take."
	end

	if reaper.TakeIsMIDI(take) then
		return nil, nil, "The selected take is MIDI. Select an audio click recording."
	end

	local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	if not item_len or item_len <= 0 then
		return nil, nil, "Selected item length is zero."
	end

	return item, take, nil
end

local function analyze_take_envelope(take, item)
	local src = reaper.GetMediaItemTake_Source(take)
	if not src then
		return nil, "Could not access selected take source."
	end

	local channels = reaper.GetMediaSourceNumChannels(src)
	channels = math.max(1, channels or 1)

	local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	local item_end = item_pos + item_len

	local accessor = reaper.CreateTakeAudioAccessor(take)
	if not accessor then
		return nil, "Could not create audio accessor for selected take."
	end

	local hop = math.max(1, math.floor(ANALYSIS_RATE / TARGET_ENV_HZ))
	local block_samples = 2048
	local buf = reaper.new_array(block_samples * channels)

	local env = {}
	local times = {}
	local t = item_pos

	while t < item_end do
		local remain = item_end - t
		local want = math.min(block_samples, math.max(1, math.floor(remain * ANALYSIS_RATE)))

		if want <= 0 then
			break
		end

		buf.clear()
		local ok = reaper.GetAudioAccessorSamples(accessor, ANALYSIS_RATE, channels, t, want, buf)
		if ok ~= 1 then
			break
		end

		local step = hop
		local i = 0
		while i < want do
			local sample_sum = 0.0
			local n = 0
			local jmax = math.min(want - 1, i + step - 1)

			for j = i, jmax do
				local mono = 0.0
				for ch = 0, channels - 1 do
					local idx = (j * channels + ch) + 1
					mono = mono + math.abs(buf[idx])
				end
				mono = mono / channels
				sample_sum = sample_sum + mono
				n = n + 1
			end

			if n > 0 then
				env[#env + 1] = sample_sum / n
				times[#times + 1] = t + (i / ANALYSIS_RATE)
			end

			i = i + step
		end

		t = t + (want / ANALYSIS_RATE)
	end

	reaper.DestroyAudioAccessor(accessor)

	if #env < 32 then
		return nil, "Not enough audio data for onset analysis."
	end

	return {
		env = env,
		times = times,
		item_pos = item_pos,
		item_end = item_end,
	}, nil
end

local function detect_onsets(analysis)
	local env = analysis.env
	local times = analysis.times

	local max_v = 0
	local sum = 0
	for i = 1, #env do
		local v = env[i]
		if v > max_v then
			max_v = v
		end
		sum = sum + v
	end

	if max_v < 1e-8 then
		return nil, "Audio appears silent; no click onsets found."
	end

	local mean = sum / #env
	local var = 0
	for i = 1, #env do
		local d = env[i] - mean
		var = var + (d * d)
	end
	var = var / #env
	local std = math.sqrt(var)

	local threshold = math.max(mean + 2.8 * std, max_v * 0.15)
	local lead_threshold = threshold * 0.70

	local onsets = {}
	local last_onset = -1e9

	for i = 3, #env - 2 do
		local v = env[i]
		if v >= threshold then
			if v >= env[i - 1] and v >= env[i + 1] and v >= env[i - 2] and v >= env[i + 2] then
				local t = times[i]
				if (t - last_onset) >= MIN_ONSET_GAP_SEC then
					onsets[#onsets + 1] = t
					last_onset = t
				end
			end
		end
	end

	-- Ensure the first downbeat can align to the first audible click by searching
	-- for an earlier strong peak near item start.
	local lead_end = analysis.item_pos + math.min(0.7, analysis.item_end - analysis.item_pos)
	local lead_candidate = nil
	for i = 3, #env - 2 do
		local t = times[i]
		if t > lead_end then
			break
		end
		local v = env[i]
		if v >= lead_threshold and v >= env[i - 1] and v >= env[i + 1] then
			lead_candidate = t
			break
		end
	end

	if lead_candidate and #onsets > 0 and lead_candidate < (onsets[1] - (MIN_ONSET_GAP_SEC * 0.5)) then
		table.insert(onsets, 1, lead_candidate)
	end

	if #onsets < 8 then
		return nil, "Too few click onsets detected. Try trimming to a cleaner click track item."
	end

	return onsets, nil
end

local function refine_onset_times(take, item, onsets)
	if #onsets == 0 then
		return onsets
	end

	local src = reaper.GetMediaItemTake_Source(take)
	if not src then
		return onsets
	end

	local channels = reaper.GetMediaSourceNumChannels(src)
	channels = math.max(1, channels or 1)

	local sr = reaper.GetMediaSourceSampleRate(src)
	if not sr or sr < 1000 then
		sr = 48000
	end

	local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	local item_end = item_pos + item_len

	local accessor = reaper.CreateTakeAudioAccessor(take)
	if not accessor then
		return onsets
	end

	local refined = {}
	local last_t = -1e9

	for i = 1, #onsets do
		local center = onsets[i]
		local w0 = math.max(item_pos, center - TRANSIENT_REFINE_WIN_SEC)
		local w1 = math.min(item_end, center + TRANSIENT_REFINE_WIN_SEC)
		local want = math.floor((w1 - w0) * sr)

		if want < 8 then
			refined[#refined + 1] = center
		else
			local buf = reaper.new_array(want * channels)
			buf.clear()
			local ok = reaper.GetAudioAccessorSamples(accessor, sr, channels, w0, want, buf)
			if ok == 1 then
				local best_idx = 1
				local best_val = -1
				for s = 0, want - 1 do
					local mono = 0.0
					for ch = 0, channels - 1 do
						local idx = (s * channels + ch) + 1
						mono = mono + math.abs(buf[idx])
					end
					mono = mono / channels
					if mono > best_val then
						best_val = mono
						best_idx = s
					end
				end

				local t = w0 + (best_idx / sr)
				if t <= last_t then
					t = center
				end
				refined[#refined + 1] = t
				last_t = t
			else
				refined[#refined + 1] = center
			end
		end
	end

	reaper.DestroyAudioAccessor(accessor)
	return refined
end

local function build_iois(onsets)
	local iois = {}
	for i = 1, #onsets - 1 do
		local dt = onsets[i + 1] - onsets[i]
		if dt > 0.01 and dt < 2.0 then
			iois[#iois + 1] = {
				dt = dt,
				i = i,
			}
		end
	end
	return iois
end

local function detect_boundaries(iois, onsets)
	local boundaries = {}
	local last_boundary_onset = 1

	if #iois >= (WINDOW_IOI * 2 + 1) then
		for k = WINDOW_IOI + 1, #iois - WINDOW_IOI do
			local left = {}
			local right = {}

			for i = k - WINDOW_IOI, k - 1 do
				left[#left + 1] = iois[i].dt
			end
			for i = k, k + WINDOW_IOI - 1 do
				right[#right + 1] = iois[i].dt
			end

			local left_med = median(left)
			local right_med = median(right)
			if left_med and right_med then
				local ratio = right_med / left_med
				local rel = math.abs(right_med - left_med) / math.max(left_med, 1e-9)
				local hard = (ratio >= CHANGE_RATIO_HARD or ratio <= (1.0 / CHANGE_RATIO_HARD))
				local soft = rel >= CHANGE_RATIO_SOFT

				if hard or soft then
					local onset_idx = iois[k].i + 1
					if (onset_idx - last_boundary_onset) >= MIN_SEGMENT_ONSETS then
						boundaries[#boundaries + 1] = onset_idx
						last_boundary_onset = onset_idx
					end
				end
			end
		end
	end

	for k = 2, #iois do
		local prev = iois[k - 1].dt
		local curr = iois[k].dt
		local ratio = curr / prev
		local rel = math.abs(curr - prev) / math.max(prev, 1e-9)

		local hard = (ratio >= (CHANGE_RATIO_HARD * 1.15) or ratio <= (1.0 / (CHANGE_RATIO_HARD * 1.15)))
		local soft = rel >= (CHANGE_RATIO_SOFT * 1.6)

		if hard or soft then
			local onset_idx = iois[k].i + 1
			if (onset_idx - last_boundary_onset) >= (MIN_SEGMENT_ONSETS + 2) then
				boundaries[#boundaries + 1] = onset_idx
				last_boundary_onset = onset_idx
			end
		end
	end

	if #boundaries == 0 then
		return { 1, #onsets }
	end

	local points = { 1 }
	for i = 1, #boundaries do
		points[#points + 1] = boundaries[i]
	end
	points[#points + 1] = #onsets

	table.sort(points)
	local dedup = {}
	for i = 1, #points do
		if i == 1 or points[i] ~= points[i - 1] then
			dedup[#dedup + 1] = points[i]
		end
	end

	return dedup
end

local function build_segments(onsets, boundaries, item_end)
	local segments = {}

	for i = 1, #boundaries - 1 do
		local s_idx = boundaries[i]
		local e_idx = boundaries[i + 1]
		if e_idx - s_idx >= 2 then
			local dts = {}
			for j = s_idx, e_idx - 1 do
				local dt = onsets[j + 1] - onsets[j]
				if dt > 0.01 and dt < 2.0 then
					dts[#dts + 1] = dt
				end
			end

			if #dts >= 2 then
				local med_dt = median(dts)
				local pulse_rate = 60.0 / med_dt
				segments[#segments + 1] = {
					start_time = onsets[s_idx],
					end_time = (i == (#boundaries - 1)) and item_end or onsets[e_idx],
					start_idx = s_idx,
					end_idx = e_idx,
					pulse_rate = pulse_rate,
					median_ioi = med_dt,
				}
			end
		end
	end

	if #segments == 0 then
		local dts = {}
		for i = 1, #onsets - 1 do
			local dt = onsets[i + 1] - onsets[i]
			if dt > 0.01 and dt < 2.0 then
				dts[#dts + 1] = dt
			end
		end

		if #dts >= 2 then
			local med_dt = median(dts)
			segments[1] = {
				start_time = onsets[1],
				end_time = item_end,
				start_idx = 1,
				end_idx = #onsets,
				pulse_rate = 60.0 / med_dt,
				median_ioi = med_dt,
			}
		end
	end

	return segments
end

local function find_guide_track()
	for i = 0, reaper.CountTracks(0) - 1 do
		local track = reaper.GetTrack(0, i)
		if track then
			local _, name = reaper.GetTrackName(track)
			if name:lower() == "guide" then
				return track
			end
		end
	end
	return nil
end

local function play_segment_preview(seg_start_time, selected_item)
	-- Stop any current playback
	reaper.Main_OnCommand(1016, 0)
	
	-- Find guide track
	local guide_track = find_guide_track()
	
	-- Store mute state of guide track to restore later
	local guide_was_muted = nil
	if guide_track then
		guide_was_muted = reaper.GetMediaTrackInfo_Value(guide_track, "B_MUTE")
		-- Unmute guide track so it plays
		reaper.SetMediaTrackInfo_Value(guide_track, "B_MUTE", 0)
	end
	
	-- Set cursor to segment start and play (click track stays unmuted to hear it too)
	reaper.SetEditCurPos(seg_start_time, true, true)
	reaper.Main_OnCommand(1007, 0)
	
	-- Return state info so we can restore later
	return {
		guide_track = guide_track,
		guide_was_muted = guide_was_muted,
	}
end

local function restore_playback_state(state)
	if not state then
		return
	end
	
	-- Stop playback
	reaper.Main_OnCommand(1016, 0)
	
	-- Restore mute state of guide track
	if state.guide_track and state.guide_was_muted ~= nil then
		reaper.SetMediaTrackInfo_Value(state.guide_track, "B_MUTE", state.guide_was_muted)
	end
end

local function ask_segment_settings(segments, selected_item)
	local out = {}
	local last_pulse = "q"
	local last_num = 4
	local last_den = 4

	for i = 1, #segments do
		local seg = segments[i]
		reaper.SetEditCurPos(seg.start_time, true, false)

		local info = "Segment " .. tostring(i) .. " of " .. tostring(#segments) .. "\n" ..
			"Range: " .. format_timecode(seg.start_time) .. " -> " .. format_timecode(seg.end_time) .. "\n" ..
			string.format("Detected pulse rate: %.3f clicks/min\n", seg.pulse_rate) ..
			"\nEnter pulse + meter. Examples: q, e, s, 1/8, 1/16, custom:3"

		local playback_state = play_segment_preview(seg.start_time, selected_item)
		reaper.MB(info .. "\n\n(Playing segment start + guide track)", "Click Tempo Mapper", 0)
		restore_playback_state(playback_state)

		local defaults = table.concat({
			last_pulse,
			tostring(last_num),
			tostring(last_den),
			"",
		}, ",")

		local ok, csv = reaper.GetUserInputs(
			"Segment " .. tostring(i),
			4,
			"Pulse (q/e/s/custom),TimeSig Num,TimeSig Den,BPM override optional",
			defaults
		)

		if not ok then
			return nil, "Cancelled by user."
		end

		local parts = split_csv(csv)
		local pulse_text = parts[1] or ""
		local ts_num = parse_int(parts[2])
		local ts_den = parse_int(parts[3])
		local bpm_override = tonumber(parts[4] or "")

		local ppq = pulse_to_pulses_per_quarter(pulse_text)
		if not ppq then
			return nil, "Invalid pulse value in segment " .. tostring(i) .. "."
		end

		if not ts_num or ts_num < 1 or ts_num > 64 then
			return nil, "Invalid time signature numerator in segment " .. tostring(i) .. "."
		end

		local valid_den = {
			[1] = true,
			[2] = true,
			[4] = true,
			[8] = true,
			[16] = true,
			[32] = true,
		}
		if not ts_den or not valid_den[ts_den] then
			return nil, "Invalid time signature denominator in segment " .. tostring(i) .. "."
		end

		local bpm = bpm_override
		if not bpm then
			bpm = seg.pulse_rate / ppq
		end

		if not bpm or bpm <= 1 or bpm > 480 then
			return nil, "Computed BPM is out of range in segment " .. tostring(i) .. "."
		end

		out[#out + 1] = {
			start_time = seg.start_time,
			end_time = seg.end_time,
			bpm = bpm,
			ts_num = ts_num,
			ts_den = ts_den,
			pulse = pulse_text,
		}

		last_pulse = pulse_text
		last_num = ts_num
		last_den = ts_den
	end

	return out, nil
end

local function clear_tempo_map()
	local count = reaper.CountTempoTimeSigMarkers(0)
	for i = count - 1, 0, -1 do
		reaper.DeleteTempoTimeSigMarker(0, i)
	end
end

local function write_tempo_markers(labeled_segments)
	local written = 0
	local meter_written = 0
	local prev_num = nil
	local prev_den = nil

	for i = 1, #labeled_segments do
		local seg = labeled_segments[i]

		-- Always pass the real time signature so REAPER treats every segment
		-- boundary as beat 1 of a new measure (downbeat anchor).
		-- Passing ts_num=0 would skip the measure reset even if time is correct.
		local ts_num = seg.ts_num
		local ts_den = seg.ts_den

		if i == 1 or seg.ts_num ~= prev_num or seg.ts_den ~= prev_den then
			meter_written = meter_written + 1
		end

		reaper.SetTempoTimeSigMarker(0, -1, seg.start_time, -1, -1, seg.bpm, ts_num, ts_den, false)
		written = written + 1
		prev_num = seg.ts_num
		prev_den = seg.ts_den
	end

	return written, meter_written
end

local function validate_transient_alignment(onsets, labeled_segments)
	local issues = {}
	local total_checked = 0
	local total_aligned = 0
	local alignment_tolerance_sec = 0.015

	for seg_idx = 1, #labeled_segments do
		local seg = labeled_segments[seg_idx]
		local seg_onsets = {}

		-- Extract onsets that fall within this segment
		for ons_idx = 1, #onsets do
			local ons_time = onsets[ons_idx]
			if ons_time >= seg.start_time and ons_time < seg.end_time then
				seg_onsets[#seg_onsets + 1] = ons_time
			end
		end

		if #seg_onsets < 2 then
			goto continue_seg
		end

		-- Calculate expected beat duration in seconds from BPM
		-- Each beat is a quarter note; at BPM, quarter duration = 60 / BPM
		local beat_duration_sec = 60.0 / seg.bpm

		-- Check each onset against the beat grid
		local aligned_count = 0
		for i = 1, #seg_onsets do
			local onset_time = seg_onsets[i]
			-- Time offset from segment start
			local offset_in_seg = onset_time - seg.start_time
			-- Which beat number should this be close to?
			local beat_number = offset_in_seg / beat_duration_sec
			-- Nearest beat
			local nearest_beat = math.floor(beat_number + 0.5)
			local expected_time = seg.start_time + (nearest_beat * beat_duration_sec)
			-- How far off is this onset from the nearest expected beat?
			local deviation = math.abs(onset_time - expected_time)

			if deviation <= alignment_tolerance_sec then
				aligned_count = aligned_count + 1
			else
				if #issues < 5 then
					local msg = string.format(
						"Seg %d: transient at %s deviates %.3f sec",
						seg_idx,
						format_timecode(onset_time),
						deviation
					)
					issues[#issues + 1] = msg
				end
		end
	end

		total_checked = total_checked + #seg_onsets
		total_aligned = total_aligned + aligned_count

		::continue_seg::
	end

	return {
		total_checked = total_checked,
		total_aligned = total_aligned,
		issues_count = #issues,
		issues = issues,
	}
end

local function apply_no_stretch_whole_project()
	local tracks = reaper.CountTracks(0)
	local changed_items = 0
	local changed_tracks = 0

	for t = 0, tracks - 1 do
		local tr = reaper.GetTrack(0, t)
		if tr then
			reaper.SetMediaTrackInfo_Value(tr, "C_BEATATTACHMODE", 0)
			changed_tracks = changed_tracks + 1

			local item_count = reaper.CountTrackMediaItems(tr)
			for i = 0, item_count - 1 do
				local item = reaper.GetTrackMediaItem(tr, i)
				reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 0)
				reaper.SetMediaItemInfo_Value(item, "C_AUTOSTRETCH", 0)
				changed_items = changed_items + 1
			end
		end
	end

	return changed_tracks, changed_items
end

local function main()
	local item, take, err = get_selected_audio_take()
	if err then
		reaper.MB(err, "Click Tempo Mapper", 0)
		return
	end

	local analysis, analysis_err = analyze_take_envelope(take, item)
	if analysis_err then
		reaper.MB(analysis_err, "Click Tempo Mapper", 0)
		return
	end

	local onsets, onset_err = detect_onsets(analysis)
	if onset_err then
		reaper.MB(onset_err, "Click Tempo Mapper", 0)
		return
	end
	onsets = refine_onset_times(take, item, onsets)

	local iois = build_iois(onsets)
	if #iois < 4 then
		reaper.MB("Not enough stable click intervals detected.", "Click Tempo Mapper", 0)
		return
	end

	local boundaries = detect_boundaries(iois, onsets)
	local segments = build_segments(onsets, boundaries, analysis.item_end)
	if #segments == 0 then
		reaper.MB("Could not build tempo segments from detected clicks.", "Click Tempo Mapper", 0)
		return
	end

	local labeled, prompt_err = ask_segment_settings(segments, item)
	if prompt_err then
		reaper.MB(prompt_err, "Click Tempo Mapper", 0)
		return
	end

	local existing_markers = reaper.CountTempoTimeSigMarkers(0)

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)

	clear_tempo_map()
	local markers_written, meter_written = write_tempo_markers(labeled)
	local changed_tracks, changed_items = apply_no_stretch_whole_project()
	local alignment_report = validate_transient_alignment(onsets, labeled)

	reaper.PreventUIRefresh(-1)
	reaper.UpdateTimeline()
	reaper.UpdateArrange()
	reaper.Undo_EndBlock("Build tempo map from recorded click track", -1)

	local summary = {
		"Tempo mapping complete.",
		"",
		"Detected onsets: " .. tostring(#onsets),
		"Detected segments: " .. tostring(#segments),
		"Replaced existing tempo markers: " .. tostring(existing_markers),
		"Tempo markers written: " .. tostring(markers_written),
		"Meter markers written: " .. tostring(meter_written),
		"Tracks set to time-based/no-stretch: " .. tostring(changed_tracks),
		"Items set to time-based/no-stretch: " .. tostring(changed_items),
		"",
		"Transient alignment:",
		"  Total transients checked: " .. tostring(alignment_report.total_checked),
		"  Well-aligned: " .. tostring(alignment_report.total_aligned),
	}

	if alignment_report.issues_count > 0 then
		summary[#summary + 1] = "  Misaligned: " .. tostring(alignment_report.issues_count)
		for i = 1, #alignment_report.issues do
			summary[#summary + 1] = "    " .. alignment_report.issues[i]
		end
	end

	reaper.MB(table.concat(summary, "\n"), "Click Tempo Mapper", 0)
end

main()
