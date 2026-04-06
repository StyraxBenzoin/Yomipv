-- Subtitle prefetcher
-- Extracts and caches subtitle text ahead of playback position

local mp = require("mp")
local msg = require("mp.msg")

local Prefetcher = {
	_entries = {}, -- {start_s, end_s, text}
	_ready = false,
}

-- Convert SRT timestamp to seconds
local function parse_srt_time(ts)
	local h, m, s, ms = ts:match("(%d+):(%d+):(%d+)[,.](%d+)")
	if not h then return nil end
	return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

-- Strip ASS and HTML tags from raw subtitle text
local function strip_tags(text)
	text = text:gsub("{[^}]-}", "")
	text = text:gsub("<[^>]->" , "")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

local function parse_srt(raw)
	local entries = {}

	raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")

	for block in (raw .. "\n\n"):gmatch("(.-)\n\n") do
		local t_line = block:match("\n?%d+:%d+:%d+[,.]%d+ %-%-> %d+:%d+:%d+[,.]%d+")
		if t_line then
			local t_start_str, t_end_str = t_line:match("(%d+:%d+:%d+[,.]%d+) %-%-> (%d+:%d+:%d+[,.]%d+)")
			local t_start = parse_srt_time(t_start_str)
			local t_end   = parse_srt_time(t_end_str)

			local text_raw = block:match("\n?%d+:%d+:%d+[,.]%d+ %-%-> %d+:%d+:%d+[,.]%d+\n(.*)")
			local text = text_raw and strip_tags(text_raw:gsub("\n", " ")) or ""
			text = text:gsub("%s+$", "")

			if t_start and t_end and text ~= "" then
				table.insert(entries, { start_s = t_start, end_s = t_end, text = text })
			end
		end
	end

	msg.info(string.format("Prefetcher: Parsed %d subtitle entries", #entries))
	return entries
end

function Prefetcher.reset()
	Prefetcher._entries = {}
	Prefetcher._ready = false
end

function Prefetcher.load()
	Prefetcher.reset()

	local path = mp.get_property("path")
	if not path then
		msg.warn("Prefetcher: No file path available")
		return
	end

	-- Check for external files before extracting from container
	local sub_file = mp.get_property("current-tracks/sub/external-filename")
	if sub_file and sub_file ~= "" then
		msg.info("Prefetcher: Using external subtitle file: " .. sub_file)
		Prefetcher._extract_from_file(sub_file)
		return
	end

	-- Extract from video stream as fallback
	local track_id = mp.get_property_number("current-tracks/sub/ff-index")
	if not track_id then
		msg.info("Prefetcher: No active subtitle track found")
		return
	end

	msg.info(string.format("Prefetcher: Extracting internal track (ff-index %d) via ffmpeg", track_id))
	Prefetcher._extract_from_video(path, track_id)
end

-- Extract text from standalone subtitle files
function Prefetcher._extract_from_file(file_path)
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = {
			"ffmpeg",
			"-hide_banner",
			"-v", "quiet",
			"-i", file_path,
			"-map", "0:s:0",
			"-f", "srt",
			"pipe:1",
		},
	}, function(success, result, _err)
		if not success or result.status ~= 0 or not result.stdout or result.stdout == "" then
			-- Attempt direct read if process execution fails
			msg.info("Prefetcher: ffmpeg failed on external file, trying plain read")
			local f = io.open(file_path, "r")
			if f then
				local raw = f:read("*a")
				f:close()
				Prefetcher._entries = parse_srt(raw)
				Prefetcher._ready = #Prefetcher._entries > 0
			end
			return
		end

		Prefetcher._entries = parse_srt(result.stdout)
		Prefetcher._ready = #Prefetcher._entries > 0
	end)
end

-- Extract subtitles from video container using ffmpeg
function Prefetcher._extract_from_video(video_path, ff_index)
	local map_arg = string.format("0:s:%d", ff_index)

	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = {
			"ffmpeg",
			"-hide_banner",
			"-v", "quiet",
			"-i", video_path,
			"-map", map_arg,
			"-f", "srt",
			"pipe:1",
		},
	}, function(success, result, _err)
		if not success or result.status ~= 0 or not result.stdout or result.stdout == "" then
			msg.warn("Prefetcher: ffmpeg extraction failed for internal track")
			return
		end

		Prefetcher._entries = parse_srt(result.stdout)
		Prefetcher._ready = #Prefetcher._entries > 0
	end)
end

-- Retrieve upcoming subtitle text
function Prefetcher.get_next_lines(current_time, current_text, count)
	if not Prefetcher._ready then
		return {}
	end

	local results = {}
	local sub_delay = mp.get_property_number("sub-delay", 0)

	for _, entry in ipairs(Prefetcher._entries) do
		-- Prevent duplication of currently displayed text
		if (entry.start_s + sub_delay) > current_time and entry.text ~= current_text then
			table.insert(results, entry.text)
			if #results >= count then
				break
			end
		end
	end

	return results
end

return Prefetcher
