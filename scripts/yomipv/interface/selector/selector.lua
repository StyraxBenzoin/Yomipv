--[[ Interactive word selector ]]

local mp = require("mp")
local Renderer = require("interface.selector.renderer")
local Interaction = require("interface.selector.interaction")

local Selector = {
	tokens = {},
	index = 1,
	callback = nil,
	active = false,
	should_resume = false,
	token_boxes = {},
	input_timer = nil,
	last_mouse_x = -1,
	last_mouse_y = -1,
	style = {},
	ui_hidden_by_us = false,
	registered_keys = {},
	selection_len = 1,
	sub_visibility_before = "yes",
	lookup_locked = false,
	locked_index = nil,
	locked_mora_index = nil,
}

local function utf8_iter(s, i)
	if not s then
		return nil
	end
	i = i or 1
	if i > #s then
		return nil
	end
	local c = string.byte(s, i)
	local code
	local next_i
	if c < 128 then
		code = c
		next_i = i + 1
	elseif c >= 194 and c <= 223 then
		local c2 = string.byte(s, (i + 1)) or 0
		code = ((c - 192) * 64) + (c2 - 128)
		next_i = i + 2
	elseif c >= 224 and c <= 239 then
		local c2 = string.byte(s, (i + 1)) or 0
		local c3 = string.byte(s, (i + 2)) or 0
		code = ((c - 224) * 4096) + ((c2 - 128) * 64) + (c3 - 128)
		next_i = i + 3
	elseif c >= 240 and c <= 244 then
		local c2 = string.byte(s, (i + 1)) or 0
		local c3 = string.byte(s, (i + 2)) or 0
		local c4 = string.byte(s, (i + 3)) or 0
		code = ((c - 240) * 262144) + ((c2 - 128) * 4096) + ((c3 - 128) * 64) + (c4 - 128)
		next_i = i + 4
	else
		code = c
		next_i = i + 1
	end
	return next_i, code
end

function Selector.utf8_codes(str)
	return utf8_iter, str, 1
end

function Selector.get_mora_byte_pos(text, mora_index)
	if not mora_index or mora_index <= 1 then
		return 1
	end
	local i = 1
	local char_count = 0
	for next_i, _ in Selector.utf8_codes(text) do
		char_count = char_count + 1
		if char_count == mora_index then
			return i
		end
		i = next_i
	end
	return i
end

function Selector.get_char_count(text)
	local count = 0
	for _ in Selector.utf8_codes(text) do
		count = count + 1
	end
	return count
end

function Selector:get_selection_state()
	local token = self.tokens[self.index]
	if not token then
		return nil
	end

	local text = ""
	local offset = token.offset
	local headwords = token.headwords
	local reading = token.reading or (token.headwords and token.headwords[1] and token.headwords[1].reading)

	if self.selection_len == 1 then
		text = token.text
		if self.mora_index and self.mora_index > 1 then
			local byte_pos = Selector.get_mora_byte_pos(text, self.mora_index)
			local skipped_text = text:sub(1, byte_pos - 1)
			text = text:sub(byte_pos)
			offset = offset + skipped_text:len()
		end
	else
		for i = 0, self.selection_len - 1 do
			local t = self.tokens[self.index + i]
			if t then
				text = text .. t.text
			end
		end
	end

	return {
		text = text,
		offset = offset,
		headwords = headwords,
		reading = reading,
	}
end

local function render_cb()
	Selector:render()
end

function Selector:render()
	Renderer.render(self)
end

function Selector:update_style(style)
	self.style = style or {}
	self:render()
end

function Selector:clear()
	self.active = false
	if self.input_timer then
		self.input_timer:kill()
		self.input_timer = nil
	end
	mp.unobserve_property(render_cb)
	if self.lookup_timer then
		self.lookup_timer:kill()
		self.lookup_timer = nil
	end
	mp.set_osd_ass(0, 0, "")
	mp.set_property("sub-visibility", self.sub_visibility_before)
	self.lookup_locked = false
	self.locked_index = nil
	self.locked_mora_index = nil

	Interaction.unbind(self)

	if self.ui_hidden_by_us then
		mp.commandv("script-message-to", "uosc", "disable-elements", "yomipv", "")
		self.ui_hidden_by_us = false
	end
	if self.should_resume then
		mp.set_property_native("pause", false)
		self.should_resume = false
	end

	if self.style.on_hide then
		self.style.on_hide()
	end
end

function Selector:confirm()
	local state = self:get_selection_state()
	if not state then
		return
	end

	local token = {
		text = state.text,
		headwords = state.headwords,
		offset = state.offset,
		is_term = true,
	}

	local cb = self.callback
	self:clear()
	cb(token)
end

function Selector:cancel()
	self:clear()
	if self.callback then
		self.callback(nil)
	end
end

function Selector:prepend_tokens(new_tokens, offset_shift)
	for i = #new_tokens, 1, -1 do
		table.insert(self.tokens, 1, new_tokens[i])
	end
	self.index = self.index + #new_tokens

	if offset_shift then
		for i = #new_tokens + 1, #self.tokens do
			if self.tokens[i].offset then
				self.tokens[i].offset = self.tokens[i].offset + offset_shift
			end
		end
	end
	self:render()
end

function Selector:append_tokens(new_tokens)
	for _, token in ipairs(new_tokens) do
		table.insert(self.tokens, token)
	end
	self:render()
end

function Selector:start(tokens, callback, style)
	if self.active then
		return
	end
	self.active = true
	self.tokens = tokens
	self.style = style or {}
	self.index = 1
	self.selection_len = 1
	self.lookup_timer = nil
	self.pending_initial_hover_lookup = true
	self.lookup_locked = false
	self.locked_index = nil
	self.locked_mora_index = nil
	for i, token in ipairs(tokens) do
		if token.is_term then
			self.index = i
			break
		end
	end
	self.callback = callback

	self.sub_visibility_before = mp.get_property("sub-visibility", "yes")
	mp.set_property("sub-visibility", "no")

	if style.should_pause ~= false then
		if not mp.get_property_native("pause") then
			mp.set_property_native("pause", true)
			self.should_resume = true
		else
			self.should_resume = style.should_resume == true
		end
	else
		self.should_resume = style.should_resume == true
	end

	if style.hide_ui then
		mp.commandv(
			"script-message-to",
			"uosc",
			"disable-elements",
			"yomipv",
			"timeline,controls,volume,top_bar,idle_indicator,audio_indicator,buffering_indicator,pause_indicator"
		)
		self.ui_hidden_by_us = true
	end

	Interaction.bind(self)

	mp.observe_property("osd-width", "native", render_cb)
	mp.observe_property("osd-height", "native", render_cb)

	self:render()
	self.input_timer = mp.add_periodic_timer(0.04, function()
		Interaction.check_hover(self)
	end)

	Interaction.trigger_initial_lookup(self)
end

return Selector
