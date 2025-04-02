-- ~/.config/nvim/lua/your_plugin_name/llm.lua (or similar)
local M = {}
local Job = require("plenary.job")
local api = vim.api
local fn = vim.fn

local group = api.nvim_create_augroup("DING_LLM_AutoGroup", { clear = true })
local active_job = nil

-- Helper to safely get environment variable
local function get_api_key(name)
	if not name then
		vim.notify("API key name not configured", vim.log.levels.WARN)
		return nil
	end
	local key = os.getenv(name)
	if not key then
		vim.notify("API key environment variable not found: " .. name, vim.log.levels.WARN)
	end
	return key
end

-- Get text from buffer start to cursor
function M.get_lines_until_cursor()
	local current_buffer = api.nvim_get_current_buf()
	local current_window = api.nvim_get_current_win()
	local cursor_position = api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1] -- 1-based row

	-- Get lines from start (0) up to (but not including) cursor row
	local lines = api.nvim_buf_get_lines(current_buffer, 0, row - 1, true)
	-- Get the part of the cursor line up to the cursor column
	local cursor_line_content = api.nvim_buf_get_lines(current_buffer, row - 1, row, true)[1] or ""
	local col = cursor_position[2] -- 0-based column
	table.insert(lines, string.sub(cursor_line_content, 1, col))

	return table.concat(lines, "\n")
end

-- Get text from visual selection
-- Returns { text = "selected text", start_pos = {row, col}, end_pos = {row, col} } or nil
-- Positions are 0-indexed for API calls
function M.get_visual_selection_info()
	local mode = fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		return nil -- Not in visual mode
	end

	-- '< and '> marks store start and end of last visual selection
	local start_pos_vim = fn.getpos("'<")
	local end_pos_vim = fn.getpos("'.") -- Use '.' for precise end in char mode

	-- Convert vim pos [bufnum, lnum, col, off] to 0-indexed {row, col}
	-- Note: fn.getpos 'col' is 1-based byte index. API uses 0-based byte index.
	local srow, scol = start_pos_vim[2] - 1, start_pos_vim[3] - 1
	local erow, ecol = end_pos_vim[2] - 1, end_pos_vim[3] - 1

	local text_lines

	-- Ensure start is before end for API calls
	if srow > erow or (srow == erow and scol > ecol) then
		srow, erow = erow, srow
		scol, ecol = ecol, scol
	end

	-- Adjust end column for nvim_buf_get_text (exclusive)
	-- For linewise ('V') and blockwise ('\22'), we get full lines or columns later.
	-- For charwise ('v'), getpos('.') col points *at* the char, nvim_buf_get_text needs col *after* char.
	-- However, empirical testing often shows using the direct col value works as expected
	-- due to how selections vs cursor positions are reported. Let's stick to the direct mapping
	-- and adjust if needed based on testing different selections.
	-- local text_opts = {} might be needed for UTF8 handling if issues arise

	if mode == "V" then -- Linewise
		text_lines = api.nvim_buf_get_lines(0, srow, erow + 1, true) -- erow+1 because end is exclusive
		-- For linewise, selection end is start of the line usually, adjust col if needed
		ecol = fn.col("$") - 1 -- End of the line
	elseif mode == "\22" then -- Blockwise
		text_lines = {}
		local min_scol, max_ecol = scol, ecol -- Use the actual selection columns
		if start_pos_vim[3] > end_pos_vim[3] then -- Check original vim pos for block col swap
			min_scol, max_ecol = ecol, scol
		end
		for i = srow, erow do
			-- Ensure we don't request negative columns
			local line_scol = math.max(0, min_scol)
			-- Get text returns a list, take first element
			local line_text = api.nvim_buf_get_text(0, i, line_scol, i, max_ecol, {})[1] or ""
			table.insert(text_lines, line_text)
		end
		scol = min_scol -- Use the actual start column for positioning
		ecol = max_ecol -- Use the actual end column for positioning
	else -- Charwise ('v')
		-- nvim_buf_get_text end_col is exclusive.
		text_lines = api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
	end

	return {
		text = table.concat(text_lines, "\n"),
		start_pos = { srow, scol }, -- 0-indexed row, col
		end_pos = { erow, ecol }, -- 0-indexed row, col for end of selection
	}
end

-- Prepare context (prompt) based on visual selection or cursor position
-- Returns { prompt = "...", replace_range = {start_pos, end_pos} or nil }
local function get_context(opts)
	local context = {}
	local selection_info = M.get_visual_selection_info()

	if selection_info then
		context.prompt = selection_info.text
		if opts.replace then
			context.replace_range = { selection_info.start_pos, selection_info.end_pos }
			-- Delete the selection BEFORE starting the job
			-- Use API for robustness if possible, fallback to normal command
			vim.cmd('normal! gv"_d') -- Delete visual selection to black hole register
			-- Set cursor to the start of deleted range (API uses 1-based row)
			api.nvim_win_set_cursor(0, { selection_info.start_pos[1] + 1, selection_info.start_pos[2] })
		else
			-- Escape visual mode if not replacing
			api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
		end
	else
		-- No visual selection, get lines until cursor
		context.prompt = M.get_lines_until_cursor()
		-- No replacement range if not visual
		context.replace_range = nil
		-- Cursor is already where we want to insert
	end

	return context
end

-- Writes streamed text into the buffer at the current cursor position
function M.write_string_at_cursor(str)
	-- Ensure execution in the main Neovim loop
	vim.schedule(function()
		if not str or str == "" then
			return
		end

		local current_window = api.nvim_get_current_win()
		local cursor_pos = api.nvim_win_get_cursor(current_window) -- {row, col} 1-based row, 0-based col
		local buffer_handle = api.nvim_get_current_buf()

		-- Split incoming potentially multi-line string
		local lines = vim.split(str, "\n", { plain = true }) -- plain=true treats \n literally

		-- Use undojoin to group this insertion with previous ones from the same stream
		vim.cmd("undojoin")

		-- Insert the text character-wise, after the cursor, following cursor
		-- NOTE: nvim_buf_set_text is often more robust for programmatic insertion
		local start_row, start_col = cursor_pos[1] - 1, cursor_pos[2] -- Convert to 0-indexed row/col
		local end_row, end_col = start_row, start_col -- Placeholder, will be adjusted by insertion

		-- Calculate end position after insertion
		local num_lines = #lines
		if num_lines == 1 then
			end_row = start_row
			end_col = start_col + #lines[1]
		else
			end_row = start_row + num_lines - 1
			end_col = #lines[num_lines] -- Col position on the new last line
		end

		-- Insert using nvim_buf_set_text (handles existing text shifting)
		api.nvim_buf_set_text(buffer_handle, start_row, start_col, start_row, start_col, lines)

		-- Set cursor position to the end of the inserted text
		api.nvim_win_set_cursor(current_window, { end_row + 1, end_col }) -- API needs 1-based row

		-- Trigger InsertLeave momentarily to potentially help with syntax highlighting or LSP updates
		-- vim.cmd('silent! normal! gi')
		-- vim.cmd('stopinsert')
		-- This can be disruptive, use with caution or make optional
	end)
end

-----------------------------------------------------------------------
-- Provider Specific Functions: Curl Args & Data Handlers
-----------------------------------------------------------------------

-- Anthropic
function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url or "https://api.anthropic.com/v1/messages"
	local api_key = get_api_key(opts.api_key_name or "ANTHROPIC_API_KEY")
	if not api_key then
		return nil
	end -- Don't proceed without key

	local data = {
		system = system_prompt or "You are a helpful assistant.", -- More neutral default
		messages = { { role = "user", content = prompt } },
		model = opts.model or "claude-3-opus-20240229",
		stream = true,
		max_tokens = opts.max_tokens or 4096,
		-- temperature = opts.temperature, -- Add if needed
	}
	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"anthropic-version: 2023-06-01",
		"-H",
		"x-api-key: " .. api_key,
		"-d",
		vim.json.encode(data),
	}
	table.insert(args, url)
	return args
end

function M.handle_anthropic_spec_data(line, event_state) -- Now receives event_state if needed
	-- Anthropic uses SSE format: event: type\ndata: {json}\n\n
	-- We only care about lines starting with 'data: '
	if line:match("^data:") then
		local data_json = line:sub(7) -- Get substring after "data: "
		if data_json == "[DONE]" then
			return
		end -- OpenAI specific, but good practice

		local ok, decoded = pcall(vim.json.decode, data_json)
		if ok and decoded then
			-- Check based on Anthropic's streaming structure
			if decoded.type == "content_block_delta" and decoded.delta and decoded.delta.type == "text_delta" then
				M.write_string_at_cursor(decoded.delta.text)
			elseif decoded.type == "message_delta" and decoded.delta and decoded.delta.stop_reason then
				-- Stream finished
				-- print("Anthropic stream finished. Reason: " .. decoded.delta.stop_reason)
			elseif decoded.type == "error" then
				vim.notify(
					"Anthropic API Error: " .. (decoded.error and decoded.error.message or vim.inspect(decoded)),
					vim.log.levels.ERROR
				)
			end
		else
			vim.notify("Failed to decode Anthropic JSON: " .. data_json, vim.log.levels.WARN)
		end
	end
	-- We could also check `event_state` here if needed for more complex SSE handling
end

-- Ollama
function M.make_ollama_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url or "http://localhost:11434/api/generate"
	local data = {
		model = opts.model or "llama3",
		prompt = prompt,
		system = system_prompt, -- Ollama supports system prompt
		stream = true, -- Explicitly request streaming
		-- options = { temperature = opts.temperature, num_predict = opts.max_tokens } -- Add if needed
	}
	local args = {
		"-N", -- No buffering
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
		url,
	}
	return args
end

function M.handle_ollama_spec_data(line, _) -- event_state not used
	-- Ollama streams newline-delimited JSON objects
	local ok, decoded = pcall(vim.json.decode, line)
	if ok and decoded then
		if decoded.response then
			M.write_string_at_cursor(decoded.response)
		end
		if decoded.error then
			vim.notify("Ollama API Error: " .. decoded.error, vim.log.levels.ERROR)
		end
		if decoded.done and decoded.done == true then
			-- Stream finished
			-- print("Ollama stream finished.")
		end
	else
		-- Ignore lines that aren't valid JSON (e.g., potentially empty lines)
		-- Only warn if pcall failed but line wasn't empty
		if not ok and line ~= "" then
			vim.notify("Failed to decode Ollama JSON: " .. line, vim.log.levels.WARN)
		end
	end
end

-- OpenAI
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url or "https://api.openai.com/v1/chat/completions"
	local api_key = get_api_key(opts.api_key_name or "OPENAI_API_KEY")
	if not api_key then
		return nil
	end -- Don't proceed without key

	local messages = {}
	if system_prompt then
		table.insert(messages, { role = "system", content = system_prompt })
	end
	table.insert(messages, { role = "user", content = prompt })

	local data = {
		messages = messages,
		model = opts.model or "gpt-4o",
		temperature = opts.temperature or 0.7,
		stream = true,
		-- max_tokens = opts.max_tokens, -- Add if needed
	}
	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. api_key,
		"-d",
		vim.json.encode(data),
	}
	table.insert(args, url)
	return args
end

function M.handle_openai_spec_data(line, _) -- event_state not used
	-- OpenAI uses SSE format, usually just care about 'data: ' lines
	if line:match("^data:") then
		local data_json = line:sub(7) -- Get substring after "data: "
		if data_json == "[DONE]" then
			-- Stream finished
			-- print("OpenAI stream finished.")
			return
		end

		local ok, decoded = pcall(vim.json.decode, data_json)
		if ok and decoded then
			if decoded.choices and decoded.choices[1] and decoded.choices[1].delta then
				local content = decoded.choices[1].delta.content
				if content then
					M.write_string_at_cursor(content)
				end
				-- Could also check choices[1].finish_reason here
			end
			if decoded.error then
				vim.notify(
					"OpenAI API Error: " .. (decoded.error.message or vim.inspect(decoded.error)),
					vim.log.levels.ERROR
				)
			end
		else
			vim.notify("Failed to decode OpenAI JSON: " .. data_json, vim.log.levels.WARN)
		end
	end
end

-----------------------------------------------------------------------
-- Generic LLM Invocation
-----------------------------------------------------------------------

-- Stop the currently active LLM job, if any
function M.cancel_llm_job()
	if active_job then
		active_job:shutdown() -- Send SIGTERM then SIGKILL
		print("LLM streaming cancelled.")
		active_job = nil
		-- Clean up the escape mapping immediately
		pcall(api.nvim_del_keymap, "n", "<Esc>")
		pcall(api.nvim_del_keymap, "i", "<Esc>") -- Also consider if needed in insert mode
	else
		print("No active LLM job to cancel.")
	end
end

-- Generic function to invoke an LLM and stream response
-- opts: Table containing configuration like model, url, api_key_name, replace, etc.
-- make_curl_args_fn: Function(opts, prompt, system_prompt) -> curl_args table or nil
-- handle_data_fn: Function(line, event_state) -> handles single line of stdout
function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
	opts = opts or {}

	-- Stop any previous job first
	M.cancel_llm_job()

	local context = get_context(opts)
	if not context or not context.prompt or context.prompt == "" then
		vim.notify("No prompt generated (no selection or text before cursor?)", vim.log.levels.WARN)
		return
	end

	local prompt = context.prompt
	local system_prompt = opts.system_prompt -- Allow backend default if nil

	local args = make_curl_args_fn(opts, prompt, system_prompt)
	if not args then
		vim.notify("Failed to prepare LLM request (missing API key or bad config?)", vim.log.levels.ERROR)
		return
	end

	-- Plenary Job setup
	active_job = Job:new({
		command = "curl",
		args = args,
		stderr_buffered = false,
		on_stdout = vim.schedule_wrap(function(_, line)
			-- Pass raw line directly. Anthropic handler uses event_state, others ignore it.
			-- NOTE: This simple approach assumes only Anthropic needs event state.
			-- If more complex SSE is needed, might need a different callback structure.
			-- For now, passing nil is fine as non-Anthropic handlers ignore the 2nd arg.
			handle_data_fn(line, nil) -- Pass nil for event_state
		end),
		on_stderr = vim.schedule_wrap(function(_, line)
			-- !! Ensure this block is NOT empty in your code !!
			if line and line ~= "" then
				vim.notify("LLM Job stderr: " .. line, vim.log.levels.WARN)
			end
		end),
		on_exit = vim.schedule_wrap(function(_, code)
			-- ... (rest of on_exit logic) ...
		end),
	})

	active_job:start()
	print("LLM Job started...")

	-- Setup cancellation via Escape key
	-- Use a command to trigger the cancel function cleanly
	-- Setup cancellation command and keymaps (using the autogroup name implicitly)
	vim.cmd('command! -bang DingLLMCancel lua require("dingllm.nvim").cancel_llm_job()') -- Added -bang to allow overriding if needed
	api.nvim_set_keymap(
		"n",
		"<Esc>",
		":DingLLMCancel<CR>",
		{ noremap = true, silent = true, desc = "Cancel LLM Stream" }
	)
	api.nvim_set_keymap(
		"i",
		"<Esc>",
		"<Esc>:DingLLMCancel<CR>",
		{ noremap = true, silent = true, desc = "Cancel LLM Stream" }
	)

	return active_job
end

-----------------------------------------------------------------------
-- Public API Functions (Examples)
-----------------------------------------------------------------------

-- Example: Function to trigger Ollama completion
function M.complete_with_ollama(opts)
	opts = opts or {}
	opts.provider = "ollama" -- Add provider info if needed elsewhere
	M.invoke_llm_and_stream_into_editor(opts, M.make_ollama_spec_curl_args, M.handle_ollama_spec_data)
end

-- Example: Function to trigger OpenAI completion
function M.complete_with_openai(opts)
	opts = opts or {}
	opts.provider = "openai"
	M.invoke_llm_and_stream_into_editor(opts, M.make_openai_spec_curl_args, M.handle_openai_spec_data)
end

-- Example: Function to trigger Anthropic completion
function M.complete_with_anthropic(opts)
	opts = opts or {}
	opts.provider = "anthropic"
	M.invoke_llm_and_stream_into_editor(opts, M.make_anthropic_spec_curl_args, M.handle_anthropic_spec_data)
end

return M
