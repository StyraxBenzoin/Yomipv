--[[ Secondary Subtitle Manager                                ]]
--[[ Tracking and auto-selection of secondary subtitle tracks. ]]

local mp = require("mp")
local msg = require("mp.msg")

local SecondarySid = {}

-- Initialize secondary track management
function SecondarySid.init(config)
	SecondarySid._config = config
	if not config.secondary_sid then
		return
	end

	mp.register_event("file-loaded", function()
		SecondarySid.select_secondary_track()
	end)

	if config.secondary_on_hover then
		SecondarySid.setup_hover_tracking()
	end
end

-- Internal state for hover tracking
local last_sid = "no"
local is_hovering = false

-- Initialize hover tracking
function SecondarySid.setup_hover_tracking()
	local function update_hover_state()
		local _, oh = mp.get_osd_size()
		if oh == 0 then
			return
		end

		local _, my = mp.get_mouse_pos()
		local hover_zone = oh * 0.2 -- Top 20% of screen
		local currently_hovering = my <= hover_zone

		if currently_hovering ~= is_hovering then
			is_hovering = currently_hovering
			if is_hovering then
				-- Show subtitles at the top
				mp.set_property_native("secondary-sub-visibility", true)
				mp.set_property_number("secondary-sub-pos", 10)
				msg.info("Hover: Showing secondary subtitles")
			else
				-- Hide subtitles but keep track active for capture
				mp.set_property_native("secondary-sub-visibility", false)
				msg.info("Hover: Hiding secondary subtitles")
			end
		end
	end

	-- Monitor manual track changes
	mp.observe_property("secondary-sid", "string", function(_, val)
		if val and val ~= "no" then
			last_sid = val
			-- Ensure visibility matches hover state
			if SecondarySid._config.secondary_on_hover then
				mp.set_property_native("secondary-sub-visibility", is_hovering)
				if is_hovering then
					mp.set_property_number("secondary-sub-pos", 10)
				end
			end
		end
	end)

	-- Check hover state periodically
	mp.add_periodic_timer(0.1, update_hover_state)
	update_hover_state() -- Initial check
end

-- Select secondary subtitle track
function SecondarySid.select_secondary_track()
	local tracks = mp.get_property_native("track-list")
	if not tracks then
		return
	end

	local current_sid = mp.get_property_number("sid") or 0
	local secondary_sid = mp.get_property("secondary-sid")

	-- Respect manual selection
	if secondary_sid and secondary_sid ~= "no" then
		msg.info("Secondary subtitle already set to: " .. secondary_sid)
		last_sid = secondary_sid
		if SecondarySid._config.secondary_on_hover then
			mp.set_property_native("secondary-sub-visibility", is_hovering)
			if is_hovering then
				mp.set_property_number("secondary-sub-pos", 10)
			end
		end
		return
	end

	local sub_lang_opt = SecondarySid._config.secondary_sub_lang
	if not sub_lang_opt or sub_lang_opt == "" then
		msg.info("Secondary subtitle auto-selection disabled (secondary_sub_lang empty)")
		mp.set_property("secondary-sid", "no")
		return
	end

	local requested_langs = {}
	for s in string.gmatch(sub_lang_opt, "([^,]+)") do
		table.insert(requested_langs, (s:lower():gsub("^%s+", ""):gsub("%s+$", "")))
	end

	for _, track in ipairs(tracks) do
		if track.type == "sub" and track.id ~= current_sid then
			local lang = (track.lang or ""):lower()
			local title = (track.title or ""):lower()
			local match = false

			for _, pattern in ipairs(requested_langs) do
				if lang == pattern or title:find(pattern, 1, true) then
					match = true
					break
				end
			end

			if match then
				msg.info("Auto-selecting secondary subtitle: " .. track.id .. " (" .. (track.lang or "unknown") .. ")")

				last_sid = tostring(track.id)
				mp.set_property("secondary-sid", last_sid)

				if SecondarySid._config.secondary_on_hover then
					mp.set_property_native("secondary-sub-visibility", is_hovering)
					if is_hovering then
						mp.set_property_number("secondary-sub-pos", 10)
					end
				else
					mp.set_property_native("secondary-sub-visibility", true)
				end
				return
			end
		end
	end

	msg.warn("No suitable secondary subtitle found matching: " .. sub_lang_opt)
	mp.set_property("secondary-sid", "no")
end

return SecondarySid
