-- @description Import files to same-named tracks at project start
-- @version 0.1.2
-- @author ingeniousWizard
-- @about
--   Prompts for a folder, matches files to existing track names using the filename stem
--   (ignoring an optional trailing _<number> suffix), and imports matched files at 0.0.
--   If matched tracks already contain items, offers Replace All or Cancel.

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_name(s)
	return trim((s or ""):lower())
end

local function file_stem(filename)
	local stem = filename:match("^(.*)%.[^%.]+$") or filename
	stem = stem:gsub("_[0-9]+$", "")
	return trim(stem)
end

local function is_supported_media_file(filename)
	local ext = filename:match("%.([^%.]+)$")
	if not ext then
		return false
	end

	ext = ext:lower()
	local supported = {
		wav = true,
		wave = true,
		aif = true,
		aiff = true,
		flac = true,
		mp3 = true,
		ogg = true,
		opus = true,
		m4a = true,
		aac = true,
		wma = true,
		caf = true,
		rex = true,
		rx2 = true,
		mid = true,
		midi = true,
		mov = true,
		mp4 = true,
		m4v = true,
		avi = true,
		mkv = true,
	}

	return supported[ext] == true
end

local function path_join(folder, filename)
	local last_char = folder:sub(-1)
	if last_char == "\\" or last_char == "/" then
		return folder .. filename
	end
	local sep = package.config:sub(1, 1)
	return folder .. sep .. filename
end

local function get_tracks_by_name()
	local map = {}
	local count = reaper.CountTracks(0)

	for i = 0, count - 1 do
		local track = reaper.GetTrack(0, i)
		local _, name = reaper.GetTrackName(track)
		local key = normalize_name(name)
		if key ~= "" and not map[key] then
			map[key] = track
		end
	end

	return map, count
end

local function choose_folder()
	if reaper.JS_Dialog_BrowseForFolder then
		local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Folder to Import", "")
		if ok == 1 and folder and folder ~= "" then
			return folder
		end
		return nil
	end

	local ok, input = reaper.GetUserInputs("Import Folder", 1, "Folder path:", "")
	if not ok then
		return nil
	end

	input = trim(input or "")
	if input == "" then
		return nil
	end

	local sep = package.config:sub(1, 1)
	if sep == "\\" then
		input = input:gsub("/", "\\")
	end

	if reaper.EnumerateFiles(input, 0) == nil and reaper.EnumerateSubdirectories(input, 0) == nil then
		reaper.MB("That folder path is not valid or is empty.", "Import Files", 0)
		return nil
	end

	return input
end

local function collect_files(folder)
	local files = {}
	local idx = 0

	while true do
		local file = reaper.EnumerateFiles(folder, idx)
		if not file then
			break
		end

		if is_supported_media_file(file) then
			files[#files + 1] = file
		end

		idx = idx + 1
	end

	table.sort(files, function(a, b)
		return a:lower() < b:lower()
	end)

	return files
end

local function map_files_to_tracks(files, tracks_by_name)
	local chosen = {}
	local duplicates = {}
	local unmatched = {}

	for _, file in ipairs(files) do
		local base_name = file_stem(file)
		local key = normalize_name(base_name)
		local track = tracks_by_name[key]

		if not track then
			unmatched[#unmatched + 1] = file
		elseif chosen[key] then
			duplicates[#duplicates + 1] = file
		else
			chosen[key] = {
				file = file,
				track = track,
				key = key,
			}
		end
	end

	local mappings = {}
	for _, data in pairs(chosen) do
		mappings[#mappings + 1] = data
	end

	table.sort(mappings, function(a, b)
		return a.file:lower() < b.file:lower()
	end)

	return mappings, unmatched, duplicates
end

local function count_non_empty_matched_tracks(mappings)
	local count = 0
	for _, m in ipairs(mappings) do
		if reaper.CountTrackMediaItems(m.track) > 0 then
			count = count + 1
		end
	end
	return count
end

local function clear_track_items(track)
	local item_count = reaper.CountTrackMediaItems(track)
	for i = item_count - 1, 0, -1 do
		local item = reaper.GetTrackMediaItem(track, i)
		reaper.DeleteTrackMediaItem(track, item)
	end
end

local function save_selected_tracks()
	local selected = {}
	local count = reaper.CountSelectedTracks(0)
	for i = 0, count - 1 do
		selected[#selected + 1] = reaper.GetSelectedTrack(0, i)
	end
	return selected
end

local function restore_selected_tracks(saved)
	reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
	for _, tr in ipairs(saved) do
		reaper.SetTrackSelected(tr, true)
	end
end

local function import_to_track_at_start(full_path, track)
	local source = reaper.PCM_Source_CreateFromFile(full_path)
	if not source then
		return false
	end

	local source_len = reaper.GetMediaSourceLength(source)

	local item = reaper.AddMediaItemToTrack(track)
	if not item then
		return false
	end

	local take = reaper.AddTakeToMediaItem(item)
	if not take then
		reaper.DeleteTrackMediaItem(track, item)
		return false
	end

	reaper.SetMediaItemTake_Source(take, source)
	reaper.SetMediaItemPosition(item, 0, false)

	if source_len and source_len > 0 then
		reaper.SetMediaItemInfo_Value(item, "D_LENGTH", source_len)
	end

	-- Commit item changes so REAPER can generate and display peaks for audio files.
	reaper.UpdateItemInProject(item)
	reaper.SetMediaItemInfo_Value(item, "B_PEAKS_FILERANGE", 1)

	return true
end

local function build_summary(imported, failed_files, unmatched, duplicates, affected_tracks)
	local lines = {}
	lines[#lines + 1] = "Import complete."
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Imported: " .. tostring(imported)
	lines[#lines + 1] = "Failed imports: " .. tostring(#failed_files)
	lines[#lines + 1] = "Unmatched ignored: " .. tostring(#unmatched)
	lines[#lines + 1] = "Duplicate-mapped skipped: " .. tostring(#duplicates)
	lines[#lines + 1] = "Tracks affected: " .. tostring(affected_tracks)

	if #failed_files > 0 then
		local max_list = math.min(8, #failed_files)
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Failed files (first " .. tostring(max_list) .. "):"
		for i = 1, max_list do
			lines[#lines + 1] = "- " .. failed_files[i]
		end

		if imported == 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Hint: On macOS, verify REAPER has permission to access this folder in"
			lines[#lines + 1] = "System Settings > Privacy & Security > Files and Folders."
		end
	end

	return table.concat(lines, "\n")
end

local function main()
	local tracks_by_name, track_count = get_tracks_by_name()
	if track_count == 0 then
		reaper.MB("No tracks found in the current project.", "Import Files", 0)
		return
	end

	local folder = choose_folder()
	if not folder then
		return
	end

	local files = collect_files(folder)
	if #files == 0 then
		reaper.MB("No supported media files were found in the selected folder.", "Import Files", 0)
		return
	end

	local mappings, unmatched, duplicates = map_files_to_tracks(files, tracks_by_name)
	if #mappings == 0 then
		reaper.MB("No files matched existing track names. Nothing imported.", "Import Files", 0)
		return
	end

	local non_empty_count = count_non_empty_matched_tracks(mappings)
	if non_empty_count > 0 then
		local msg = "" ..
			tostring(non_empty_count) .. " matched track(s) already contain items.\n\n" ..
			"Choose Yes to Replace All items on matched tracks,\n" ..
			"or No to cancel."
		local response = reaper.MB(msg, "Import Files", 4)
		if response ~= 6 then
			return
		end
	end

	local saved_selection = save_selected_tracks()
	local saved_cursor = reaper.GetCursorPosition()

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)

	for _, m in ipairs(mappings) do
		clear_track_items(m.track)
	end

	local imported = 0
	local failed_files = {}
	for _, m in ipairs(mappings) do
		local full_path = path_join(folder, m.file)
		if import_to_track_at_start(full_path, m.track) then
			imported = imported + 1
		else
			failed_files[#failed_files + 1] = m.file
		end
	end

	restore_selected_tracks(saved_selection)
	reaper.SetEditCurPos(saved_cursor, false, false)

	reaper.PreventUIRefresh(-1)
	reaper.Undo_EndBlock("Import files to same-named tracks at start", -1)
	reaper.UpdateArrange()
	reaper.Main_OnCommand(40047, 0) -- Build missing peaks

	reaper.MB(build_summary(imported, failed_files, unmatched, duplicates, #mappings), "Import Files", 0)
end

main()
