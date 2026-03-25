--[[ Subtitle event monitor                                          ]]
--[[ Observes player properties to coordinate subtitle capture flow. ]]

local mp = require("mp")
local msg = require("mp.msg")

local Observer = {
	monitor = nil,
	active = false,
}

-- Initialize subtitle observer state
function Observer.init(monitor, yomitan, config)
	Observer.monitor = monitor
	Observer.yomitan = yomitan
	Observer.config = config
end

-- Shared handler for subtitle changes
function Observer.handle_subtitle_change(_name, _value)
	-- Deferred capture to allow secondary subtitles to sync
	if Observer.capture_timer then
		Observer.capture_timer:kill()
	end

	Observer.capture_timer = mp.add_timeout(0.2, function()
		local current_text = mp.get_property("sub-text", "")
		if not current_text or current_text == "" then
			return
		end

		local sub_start = mp.get_property_number("sub-start", 0)
		local sub_end = mp.get_property_number("sub-end", 0)
		local secondary_sid = mp.get_property("secondary-sub-text", "")
		local secondary_sub_start = mp.get_property_number("secondary-sub-start", 0)
		local secondary_sub_end = mp.get_property_number("secondary-sub-end", 0)

		local sub_data = {
			primary_sid = current_text,
			secondary_sid = secondary_sid,
			start = sub_start,
			["end"] = sub_end,
			secondary_start = secondary_sub_start,
			secondary_end = secondary_sub_end,
		}

		Observer.monitor.add_to_history(sub_data)

		if Observer.monitor.is_appending() then
			Observer.monitor.append_recorded(sub_data)
		end

		-- Pre-tokenize in the background
		if Observer.config and Observer.config.pre_tokenize and Observer.yomitan then
			local StringOps = require("lib.string_ops")
			local cleaned = StringOps.clean_subtitle(current_text)
			if cleaned and cleaned ~= "" then
				Observer.yomitan:tokenize(cleaned, function()
					msg.info("Background tokenization complete for current subtitle")
				end)
			end
		end
	end)
end

-- Start observing subtitle property changes
function Observer.start()
	if Observer.active then
		return
	end

	msg.info("Starting subtitle observer")

	mp.observe_property("sub-text", "string", Observer.handle_subtitle_change)
	mp.observe_property("secondary-sub-text", "string", Observer.handle_subtitle_change)

	Observer.active = true
end

-- Stop observing subtitle property changes
function Observer.stop()
	if not Observer.active then
		return
	end

	mp.unobserve_property(Observer.handle_subtitle_change)
	Observer.active = false
	msg.info("Stopped subtitle observer")
end

return Observer
