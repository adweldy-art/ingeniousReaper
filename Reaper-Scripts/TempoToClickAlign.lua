-- @description Align existing tempo map to Click track transients
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Reads the current project tempo map and the track named Click, checks
--   click transients against the active beat grid for each tempo region,
--   then rewrites the tempo markers to better fit the click track while
--   preserving each existing downbeat anchor.

local ANALYSIS_RATE = 4000
local TARGET_ENV_HZ = 500
local MIN_ONSET_GAP_SEC = 0.035
local TRANSIENT_REFINE_WIN_SEC = 0.008
local ALIGNMENT_TOLERANCE_SEC = 0.015
local PULSE_MATCH_REL_TOLERANCE = 0.20
local MIN_REGION_ONSETS = 4
local MIN_SPLIT_ONSETS = 8
local MIN_SPLIT_IMPROVEMENT_SEC = 0.004
local MAX_INTERNAL_MARKERS_PER_REGION = 1

local function median(values)
	if #values == 0 then
		return nil
	end

	local copy = {}
	for i = 1, #values do
		copy[i] = values[i]
	end
	table.sort(copy)

	local mid = math.floor(#copy / 2)
	if #copy % 2 == 1 then
		return copy[mid + 1]
	end

	return (copy[mid] + copy[mid + 1]) * 0.5
end

local function format_timecode(sec)
	local s = math.max(0, sec or 0)
	local h = math.floor(s / 3600)
	local m = math.floor((s - h * 3600) / 60)
	local rs = s - h * 3600 - m * 60
	return string.format("%02d:%02d:%06.3f", h, m, rs)
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

		local i = 0
		while i < want do
			local sample_sum = 0.0
			local n = 0
			local jmax = math.min(want - 1, i + hop - 1)

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

			i = i + hop
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
		if v >= threshold and v >= env[i - 1] and v >= env[i + 1] and v >= env[i - 2] and v >= env[i + 2] then
			local t = times[i]
			if (t - last_onset) >= MIN_ONSET_GAP_SEC then
				onsets[#onsets + 1] = t
				last_onset = t
			end
		end
	end

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

	if #onsets < 2 then
		return nil, "Too few click onsets detected in item."
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

local function find_track_named(target_name)
	for i = 0, reaper.CountTracks(0) - 1 do
		local track = reaper.GetTrack(0, i)
		if track then
			local _, name = reaper.GetTrackName(track)
			if name and name:lower() == target_name:lower() then
				return track
			end
		end
	end
	return nil
end

local function collect_click_onsets(track)
	local onsets = {}
	local analyzed_items = 0
	local failures = {}

	for i = 0, reaper.CountTrackMediaItems(track) - 1 do
		local item = reaper.GetTrackMediaItem(track, i)
		local take = item and reaper.GetActiveTake(item)
		if take and not reaper.TakeIsMIDI(take) then
			local analysis, analysis_err = analyze_take_envelope(take, item)
			if analysis then
				local item_onsets, onset_err = detect_onsets(analysis)
				if item_onsets then
					item_onsets = refine_onset_times(take, item, item_onsets)
					for j = 1, #item_onsets do
						onsets[#onsets + 1] = item_onsets[j]
					end
					analyzed_items = analyzed_items + 1
				else
					failures[#failures + 1] = string.format("Item %d: %s", i + 1, onset_err or "onset detection failed")
				end
			else
				failures[#failures + 1] = string.format("Item %d: %s", i + 1, analysis_err or "analysis failed")
			end
		end
	end

	table.sort(onsets)
	local deduped = {}
	for i = 1, #onsets do
		local t = onsets[i]
		if #deduped == 0 or math.abs(t - deduped[#deduped]) > (MIN_ONSET_GAP_SEC * 0.5) then
			deduped[#deduped + 1] = t
		end
	end

	return deduped, analyzed_items, failures
end

local function read_tempo_markers()
	local count = reaper.CountTempoTimeSigMarkers(0)
	if count <= 0 then
		return nil, "Project has no tempo markers."
	end

	local markers = {}
	for i = 0, count - 1 do
		local ok, timepos, measurepos, beatpos, bpm, ts_num, ts_den, lineartempo = reaper.GetTempoTimeSigMarker(0, i)
		if ok then
			markers[#markers + 1] = {
				index = i,
				timepos = timepos,
				measurepos = measurepos,
				beatpos = beatpos,
				bpm = bpm,
				ts_num = ts_num,
				ts_den = ts_den,
				lineartempo = lineartempo and true or false,
			}
		end
	end

	if #markers == 0 then
		return nil, "Could not read any tempo markers from the project."
	end

	table.sort(markers, function(a, b)
		return a.timepos < b.timepos
	end)

	return markers, nil
end

local function get_project_end_time(last_onset_time, last_marker_time)
	local project_end = 0
	if reaper.GetProjectLength then
		project_end = reaper.GetProjectLength(0) or 0
	end
	project_end = math.max(project_end, last_onset_time or 0, (last_marker_time or 0) + 1.0)
	return project_end
end

local function build_regions(markers, project_end)
	local regions = {}
	for i = 1, #markers do
		local start_time = markers[i].timepos
		local end_time = (i < #markers) and markers[i + 1].timepos or project_end
		if end_time > start_time then
			regions[#regions + 1] = {
				start_time = start_time,
				end_time = end_time,
				original_bpm = markers[i].bpm,
				output_bpm = markers[i].bpm,
				ts_num = markers[i].ts_num,
				ts_den = markers[i].ts_den,
				lineartempo = markers[i].lineartempo,
				internal_markers = {},
			}
		end
	end
	return regions
end

local function collect_onsets_in_range(onsets, start_time, end_time)
	local out = {}
	for i = 1, #onsets do
		local t = onsets[i]
		if t >= start_time and t < end_time then
			out[#out + 1] = t
		elseif t >= end_time then
			break
		end
	end
	return out
end

local function build_pulse_candidates(region)
	local quarter_duration = 60.0 / region.original_bpm
	local candidates = {
		{ name = "half", ppq = 0.5, duration = quarter_duration * 2.0 },
		{ name = "quarter", ppq = 1.0, duration = quarter_duration },
		{ name = "eighth", ppq = 2.0, duration = quarter_duration * 0.5 },
		{ name = "sixteenth", ppq = 4.0, duration = quarter_duration * 0.25 },
	}

	if region.ts_den == 8 and region.ts_num % 3 == 0 then
		candidates[#candidates + 1] = {
			name = "dotted-quarter",
			ppq = 2.0 / 3.0,
			duration = quarter_duration * 1.5,
		}
	end

	return candidates
end

local function infer_pulse_for_region(region, region_onsets)
	local intervals = {}
	for i = 1, #region_onsets - 1 do
		local dt = region_onsets[i + 1] - region_onsets[i]
		if dt > 0.01 and dt < 2.0 then
			intervals[#intervals + 1] = dt
		end
	end

	local observed = median(intervals)
	local candidates = build_pulse_candidates(region)
	local best = candidates[2]
	local best_rel = math.huge

	if observed then
		for i = 1, #candidates do
			local candidate = candidates[i]
			local rel = math.abs(observed - candidate.duration) / math.max(candidate.duration, 1e-9)
			if rel < best_rel then
				best = candidate
				best_rel = rel
			end
		end
	else
		best_rel = 0
	end

	return {
		name = best.name,
		ppq = best.ppq,
		duration = best.duration,
		observed_duration = observed,
		rel_error = best_rel,
		confident = best_rel <= PULSE_MATCH_REL_TOLERANCE,
	}
end

local function build_alignment_points(onsets, anchor_time, pulse_duration, anchor_pulse_index)
	local points = {}
	local pulse_map = {}
	for i = 1, #onsets do
		local onset_time = onsets[i]
		local pulse_index = math.floor(((onset_time - anchor_time) / pulse_duration) + 0.5)
		pulse_index = pulse_index + (anchor_pulse_index or 0)
		if pulse_index >= (anchor_pulse_index or 0) then
			local expected_time = anchor_time + ((pulse_index - (anchor_pulse_index or 0)) * pulse_duration)
			local deviation = onset_time - expected_time
			local existing = pulse_map[pulse_index]
			if not existing or math.abs(deviation) < math.abs(existing.deviation) then
				pulse_map[pulse_index] = {
					onset_time = onset_time,
					pulse_index = pulse_index,
					expected_time = expected_time,
					deviation = deviation,
				}
			end
		end
	end

	for _, point in pairs(pulse_map) do
		points[#points + 1] = point
	end
	table.sort(points, function(a, b)
		return a.pulse_index < b.pulse_index
	end)
	return points
end

local function summarize_alignment(points)
	local abs_errors = {}
	local aligned = 0
	local max_abs = 0

	for i = 1, #points do
		local abs_dev = math.abs(points[i].deviation)
		abs_errors[#abs_errors + 1] = abs_dev
		if abs_dev <= ALIGNMENT_TOLERANCE_SEC then
			aligned = aligned + 1
		end
		if abs_dev > max_abs then
			max_abs = abs_dev
		end
	end

	return {
		total = #points,
		aligned = aligned,
		median_abs = median(abs_errors) or 0,
		max_abs = max_abs,
	}
end

local function fit_pulse_duration(points, anchor_time, anchor_pulse_index)
	local sum_num = 0
	local sum_den = 0
	for i = 1, #points do
		local rel_pulses = points[i].pulse_index - anchor_pulse_index
		if rel_pulses > 0 then
			local rel_time = points[i].onset_time - anchor_time
			sum_num = sum_num + (rel_pulses * rel_time)
			sum_den = sum_den + (rel_pulses * rel_pulses)
		end
	end

	if sum_den <= 0 then
		return nil
	end

	return sum_num / sum_den
end

local function evaluate_alignment(onsets, anchor_time, pulse_duration, anchor_pulse_index)
	local points = build_alignment_points(onsets, anchor_time, pulse_duration, anchor_pulse_index)
	return points, summarize_alignment(points)
end

local function fit_split_region(region, region_onsets, base_pulse_duration, pulse_info)
	if #region_onsets < MIN_SPLIT_ONSETS or MAX_INTERNAL_MARKERS_PER_REGION <= 0 then
		return nil
	end

	local base_points, base_report = evaluate_alignment(region_onsets, region.start_time, base_pulse_duration, 0)
	if base_report.total < MIN_SPLIT_ONSETS or base_report.median_abs <= ALIGNMENT_TOLERANCE_SEC then
		return nil
	end

	local best = nil
	for split_idx = 4, #base_points - 4 do
		local anchor_point = base_points[split_idx + 1]
		if anchor_point and anchor_point.pulse_index > 0 then
			local left_onsets = {}
			local right_onsets = {}
			for i = 1, split_idx do
				left_onsets[#left_onsets + 1] = base_points[i].onset_time
			end
			for i = split_idx + 1, #base_points do
				right_onsets[#right_onsets + 1] = base_points[i].onset_time
			end

			local left_points = build_alignment_points(left_onsets, region.start_time, base_pulse_duration, 0)
			local left_duration = fit_pulse_duration(left_points, region.start_time, 0)
			local right_points = build_alignment_points(right_onsets, anchor_point.onset_time, base_pulse_duration, anchor_point.pulse_index)
			local right_duration = fit_pulse_duration(right_points, anchor_point.onset_time, anchor_point.pulse_index)

			if left_duration and right_duration then
				local _, left_report = evaluate_alignment(left_onsets, region.start_time, left_duration, 0)
				local _, right_report = evaluate_alignment(right_onsets, anchor_point.onset_time, right_duration, anchor_point.pulse_index)
				local combined_median = ((left_report.median_abs * left_report.total) + (right_report.median_abs * right_report.total)) /
					math.max(left_report.total + right_report.total, 1)
				local combined_aligned = left_report.aligned + right_report.aligned
				local combined_total = left_report.total + right_report.total
				local combined_max = math.max(left_report.max_abs, right_report.max_abs)
				local improvement = base_report.median_abs - combined_median

				if improvement >= MIN_SPLIT_IMPROVEMENT_SEC then
					if not best or improvement > best.improvement then
						best = {
							improvement = improvement,
							base_duration = left_duration,
							marker_time = anchor_point.onset_time,
							marker_duration = right_duration,
							marker_pulse_index = anchor_point.pulse_index,
							combined_median = combined_median,
							combined_aligned = combined_aligned,
							combined_total = combined_total,
							combined_max = combined_max,
						}
					end
				end
			end
		end
	end

	if not best then
		return nil
	end

	return {
		base_bpm = 60.0 / (best.base_duration * pulse_info.ppq),
		marker = {
			timepos = best.marker_time,
			bpm = 60.0 / (best.marker_duration * pulse_info.ppq),
			pulse_index = best.marker_pulse_index,
		},
		combined_report = {
			total = best.combined_total,
			aligned = best.combined_aligned,
			median_abs = best.combined_median,
			max_abs = best.combined_max,
		},
	}
end

local function improve_region(region, region_onsets)
	local pulse_info = infer_pulse_for_region(region, region_onsets)
	local current_points, current_report = evaluate_alignment(region_onsets, region.start_time, pulse_info.duration, 0)
	local corrected_duration = fit_pulse_duration(current_points, region.start_time, 0)
	local corrected_bpm = region.original_bpm
	local best_report = current_report
	local best_duration = pulse_info.duration
	local best_points = current_points

	if corrected_duration and corrected_duration > 0 then
		local fitted_bpm = 60.0 / (corrected_duration * pulse_info.ppq)
		if fitted_bpm > 1 and fitted_bpm < 480 then
			local fitted_points, fitted_report = evaluate_alignment(region_onsets, region.start_time, corrected_duration, 0)
			if fitted_report.median_abs < current_report.median_abs then
				corrected_bpm = fitted_bpm
				best_report = fitted_report
				best_duration = corrected_duration
				best_points = fitted_points
			end
		end
	end

	local split = fit_split_region(region, region_onsets, best_duration, pulse_info)
	local internal_markers = {}
	if split and split.base_bpm > 1 and split.base_bpm < 480 then
		corrected_bpm = split.base_bpm
		internal_markers[#internal_markers + 1] = split.marker
		best_report = split.combined_report
	end

	return {
		pulse = pulse_info,
		before = current_report,
		after = best_report,
		output_bpm = corrected_bpm,
		internal_markers = internal_markers,
		matched_points = best_points,
	}
end

local function clear_tempo_map()
	local count = reaper.CountTempoTimeSigMarkers(0)
	for i = count - 1, 0, -1 do
		reaper.DeleteTempoTimeSigMarker(0, i)
	end
end

local function write_rebuilt_tempo_map(regions)
	local written = 0
	local inserted_internal = 0

	for i = 1, #regions do
		local region = regions[i]
		reaper.SetTempoTimeSigMarker(0, -1, region.start_time, -1, -1, region.output_bpm, region.ts_num, region.ts_den, false)
		written = written + 1

		table.sort(region.internal_markers, function(a, b)
			return a.timepos < b.timepos
		end)

		for j = 1, #region.internal_markers do
			local marker = region.internal_markers[j]
			if marker.timepos > region.start_time and marker.timepos < region.end_time then
				reaper.SetTempoTimeSigMarker(0, -1, marker.timepos, -1, -1, marker.bpm, 0, 0, false)
				written = written + 1
				inserted_internal = inserted_internal + 1
			end
		end
	end

	return written, inserted_internal
end

local function build_summary(regions, analyzed_items, failures, written, inserted_internal)
	local total_checked = 0
	local total_aligned_before = 0
	local total_aligned_after = 0
	local summary = {
		"Tempo-to-click alignment complete.",
		"",
		"Analyzed Click items: " .. tostring(analyzed_items),
		"Tempo regions checked: " .. tostring(#regions),
		"Tempo markers written: " .. tostring(written),
		"Internal correction markers inserted: " .. tostring(inserted_internal),
		"",
	}

	for i = 1, #regions do
		local region = regions[i]
		local result = region.result
		if result then
			total_checked = total_checked + result.before.total
			total_aligned_before = total_aligned_before + result.before.aligned
			total_aligned_after = total_aligned_after + result.after.aligned
			summary[#summary + 1] = string.format(
				"Seg %d %s -> %s | pulse %s | BPM %.3f -> %.3f | median dev %.3f ms -> %.3f ms",
				i,
				format_timecode(region.start_time),
				format_timecode(region.end_time),
				result.pulse.name,
				region.original_bpm,
				region.output_bpm,
				result.before.median_abs * 1000.0,
				result.after.median_abs * 1000.0
			)
		end
	end

	summary[#summary + 1] = ""
	summary[#summary + 1] = "Matched transients: " .. tostring(total_checked)
	summary[#summary + 1] = "Aligned before: " .. tostring(total_aligned_before)
	summary[#summary + 1] = "Aligned after: " .. tostring(total_aligned_after)

	if #failures > 0 then
		summary[#summary + 1] = ""
		summary[#summary + 1] = "Skipped Click items:"
		for i = 1, math.min(#failures, 5) do
			summary[#summary + 1] = "  " .. failures[i]
		end
		if #failures > 5 then
			summary[#summary + 1] = "  ... and " .. tostring(#failures - 5) .. " more"
		end
	end

	return table.concat(summary, "\n")
end

local function main()
	local click_track = find_track_named("Click")
	if not click_track then
		reaper.MB("Could not find a track named Click.", "Tempo To Click Align", 0)
		return
	end

	local onsets, analyzed_items, failures = collect_click_onsets(click_track)
	if #onsets < MIN_REGION_ONSETS then
		reaper.MB("Not enough click transients detected on the Click track.", "Tempo To Click Align", 0)
		return
	end

	local markers, marker_err = read_tempo_markers()
	if marker_err then
		reaper.MB(marker_err, "Tempo To Click Align", 0)
		return
	end

	local project_end = get_project_end_time(onsets[#onsets], markers[#markers].timepos)
	local regions = build_regions(markers, project_end)
	if #regions == 0 then
		reaper.MB("Could not build tempo regions from current tempo markers.", "Tempo To Click Align", 0)
		return
	end

	local useful_regions = 0
	for i = 1, #regions do
		local region = regions[i]
		local region_onsets = collect_onsets_in_range(onsets, region.start_time, region.end_time)
		if #region_onsets >= MIN_REGION_ONSETS then
			region.result = improve_region(region, region_onsets)
			region.output_bpm = region.result.output_bpm
			region.internal_markers = region.result.internal_markers
			useful_regions = useful_regions + 1
		else
			region.result = {
				pulse = {
					name = "insufficient-transients",
				},
				before = { total = 0, aligned = 0, median_abs = 0 },
				after = { total = 0, aligned = 0, median_abs = 0 },
			}
		end
	end

	if useful_regions == 0 then
		reaper.MB("Detected click transients did not overlap any tempo regions strongly enough to realign.", "Tempo To Click Align", 0)
		return
	end

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)

	clear_tempo_map()
	local written, inserted_internal = write_rebuilt_tempo_map(regions)

	reaper.PreventUIRefresh(-1)
	reaper.UpdateTimeline()
	reaper.UpdateArrange()
	reaper.Undo_EndBlock("Align tempo map to Click track", -1)

	reaper.MB(build_summary(regions, analyzed_items, failures, written, inserted_internal), "Tempo To Click Align", 0)
end

main()
