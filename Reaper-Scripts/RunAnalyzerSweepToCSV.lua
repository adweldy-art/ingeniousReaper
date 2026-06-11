-- @description Run IGR AnalyzerLab sweeps (multi-level) and export CSV
-- @version 0.1
-- @author ingeniousWizard
-- @about
--   Requires two JSFX instances:
--   1) Source instance: JS: IGR_AnalyzerLab with Mode=Source
--   2) Probe instance:  JS: IGR_AnalyzerLab with Mode=Probe (after DUT)
--
--   The script runs stepped-sine or pink-noise tests over multiple amplitudes,
--   collects probe metrics from gmem, and writes CSV in the project directory.

local FX_NAME = "JS: IGR_AnalyzerLab"
local GMEM_BUS = "IGR_ANALYZER_LAB"

local PARAM_MODE = 0
local PARAM_RUN = 1
local PARAM_SIGNAL = 2
local PARAM_LEVEL_DB = 7

local GMEM_RUN = 1
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

local function split_csv_numbers(s)
	local out = {}
	for token in tostring(s):gmatch("[^,]+") do
		local n = tonumber((token:gsub("^%s+", ""):gsub("%s+$", "")))
		if n then out[#out + 1] = n end
	end
	return out
end

local function find_analyzer_instances()
	local src = nil
	local prb = nil

	local tcount = reaper.CountTracks(0)
	for ti = -1, tcount - 1 do
		local track = (ti == -1) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, ti)
		if track then
			local fx_count = reaper.TrackFX_GetCount(track)
			for fi = 0, fx_count - 1 do
				local ok, name = reaper.TrackFX_GetFXName(track, fi, "")
				if ok and tostring(name):find("IGR_AnalyzerLab", 1, true) then
					local mode_norm = reaper.TrackFX_GetParamNormalized(track, fi, PARAM_MODE)
					local mode = (mode_norm >= 0.5) and 1 or 0
					if mode == 0 and not src then
						src = { track = track, fx = fi }
					elseif mode == 1 and not prb then
						prb = { track = track, fx = fi }
					end
				end
			end
		end
	end

	return src, prb
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

local function finish_run()
	if reaper.GetPlayState() ~= 0 then
		reaper.OnStopButton()
	end

	if state then
		set_source_run(state.source, false)

		local proj_path = reaper.GetProjectPathEx(0, "")
		if not proj_path or proj_path == "" then
			proj_path = reaper.GetProjectPath("")
		end

		local ts = os.date("%Y%m%d_%H%M%S")
		local out_path = proj_path .. "\\IGR_AnalyzerLab_" .. ts .. ".csv"
		local f = io.open(out_path, "w")
		if not f then
			reaper.MB("Could not write CSV:\n" .. out_path, "Analyzer Sweep", 0)
			return
		end

		f:write("run_index,run_level_db,nonce,step_index,freq_hz,input_db,output_db,gain_db,thd_db,crest_db,signal_type\n")
		for i = 1, #state.rows do
			local r = state.rows[i]
			f:write(string.format(
				"%d,%.3f,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
				r.run_idx,
				r.run_level_db,
				r.nonce,
				r.step,
				r.freq,
				r.in_db,
				r.out_db,
				r.gain_db,
				r.thd_db,
				r.crest_db,
				r.signal_type
			))
		end
		f:close()

		reaper.ShowConsoleMsg("")
		reaper.ShowConsoleMsg("Analyzer CSV written:\n" .. out_path .. "\n")
		reaper.MB("Analyzer run complete.\n\nCSV:\n" .. out_path, "Analyzer Sweep", 0)
	end
end

local function start_next_pass()
	state.run_idx = state.run_idx + 1
	if state.run_idx > #state.levels then
		finish_run()
		state = nil
		return
	end

	local level_db = state.levels[state.run_idx]
	set_source_level_db(state.source, level_db)
	set_source_signal(state.source, state.signal_type)
	set_source_run(state.source, false)

	-- reset done flag and arm run
	reaper.gmem_write(GMEM_DONE, 0)
	set_source_run(state.source, true)

	if reaper.GetPlayState() == 0 then
		reaper.OnPlayButton()
	end

	state.current_level_db = level_db
end

local function poll()
	if not state then return end

	local seq = math.floor(reaper.gmem_read(GMEM_SEQ) or 0)
	if seq > state.last_seq then
		for s = state.last_seq + 1, seq do
			local row = {
				run_idx = state.run_idx,
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
			}
			state.rows[#state.rows + 1] = row
		end
		state.last_seq = seq
	end

	local done = math.floor(reaper.gmem_read(GMEM_DONE) or 0)
	if done >= 1 then
		set_source_run(state.source, false)
		start_next_pass()
		if not state then
			return
		end
	end

	reaper.defer(poll)
end

local function main()
	local src, prb = find_analyzer_instances()
	if not src or not prb then
		reaper.MB(
			"Could not find both analyzer instances.\n\nNeed:\n- One JS: IGR_AnalyzerLab in Source mode\n- One JS: IGR_AnalyzerLab in Probe mode",
			"Analyzer Sweep",
			0
		)
		return
	end

	local ok, vals = reaper.GetUserInputs(
		"Analyzer Sweep To CSV",
		2,
		"Signal (0=SteppedSine,1=PinkNoise),Levels dB CSV",
		"0,-30,-24,-18,-12,-6"
	)
	if not ok then return end

	local sig_s, levels_s = vals:match("([^,]+),(.+)")
	local signal_type = tonumber(sig_s) or 0
	if signal_type < 0 or signal_type > 1 then signal_type = 0 end

	local levels = split_csv_numbers(levels_s or "")
	if #levels == 0 then
		reaper.MB("No valid levels provided.", "Analyzer Sweep", 0)
		return
	end

	reaper.gmem_attach(GMEM_BUS)

	state = {
		source = src,
		probe = prb,
		signal_type = signal_type,
		levels = levels,
		run_idx = 0,
		current_level_db = levels[1],
		last_seq = math.floor(reaper.gmem_read(GMEM_SEQ) or 0),
		rows = {},
	}

	start_next_pass()
	poll()
end

main()