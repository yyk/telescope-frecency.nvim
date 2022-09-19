local sqlwrap = require("telescope._extensions.frecency.sql_wrapper")
local util = require("telescope._extensions.frecency.util")

local DB_REMOVE_SAFETY_THRESHOLD = 10

local default_ignore_patterns = {
	"*.git/*",
	"*/tmp/*",
}

local sql_wrapper = nil
local ignore_patterns = {}

local function import_oldfiles()
	local oldfiles = vim.api.nvim_get_vvar("oldfiles")
	for _, filepath in pairs(oldfiles) do
		sql_wrapper:update(filepath)
	end
	print(("Telescope-Frecency: Imported %d entries from oldfiles."):format(#oldfiles))
end

local function file_is_ignored(filepath)
	local is_ignored = false
	for _, pattern in pairs(ignore_patterns) do
		if util.filename_match(filepath, pattern) then
			is_ignored = true
			goto continue
		end
	end

	::continue::
	return is_ignored
end

local function validate_db(safe_mode)
	if not sql_wrapper then
		return {}
	end

	local queries = sql_wrapper.queries
	local files = sql_wrapper:do_transaction(queries.file_get_entries, {})
	local pending_remove = {}
	for _, entry in pairs(files) do
		if
			not util.fs_stat(entry.path).exists -- file no longer exists
			or file_is_ignored(entry.path)
		then -- cleanup entries that match the _current_ ignore list
			table.insert(pending_remove, entry)
		end
	end

	local confirmed = false
	if not safe_mode then
		confirmed = true
	elseif #pending_remove > DB_REMOVE_SAFETY_THRESHOLD then
		-- don't allow removal of >N values from DB without confirmation
		local user_response = vim.fn.confirm(
			"Telescope-Frecency: remove " .. #pending_remove .. " entries from SQLite3 database?",
			"&Yes\n&No",
			2
		)
		if user_response == 1 then
			confirmed = true
		else
			vim.defer_fn(function()
				print("TelescopeFrecency: validation aborted.")
			end, 50)
		end
	else
		confirmed = true
	end

	if #pending_remove > 0 then
		if confirmed == true then
			for _, entry in pairs(pending_remove) do
				-- remove entries from file and timestamp tables
				sql_wrapper:do_transaction(queries.file_delete_entry, { where = { id = entry.id } })
			end
			print(("Telescope-Frecency: removed %d missing entries."):format(#pending_remove))
		else
			print("Telescope-Frecency: validation aborted.")
		end
	end
end

-- TODO: make init params a keyed table
local function init(db_root, config_ignore_patterns, safe_mode, auto_validate)
	if sql_wrapper then
		return
	end
	sql_wrapper = sqlwrap:new()
	local first_run = sql_wrapper:bootstrap(db_root)
	ignore_patterns = config_ignore_patterns or default_ignore_patterns

	if auto_validate then
		validate_db(safe_mode)
	end

	if first_run then
		-- TODO: this needs to be scheduled for after shada load
		vim.defer_fn(import_oldfiles, 100)
	end

	-- setup autocommands
	vim.api.nvim_command("augroup TelescopeFrecency")
	vim.api.nvim_command("autocmd!")
	vim.api.nvim_command(
		"autocmd BufEnter,BufWinEnter,BufWritePost * lua require'telescope._extensions.frecency.db_client'.autocmd_handler(vim.fn.expand('<amatch>'))"
	)
	vim.api.nvim_command("augroup END")
end

local function get_file_scores()
	if not sql_wrapper then
		return {}
	end

	local queries = sql_wrapper.queries
	local files = sql_wrapper:do_transaction(queries.recency_score, {})

	local scores = {}
	if vim.tbl_isempty(files) then
		return scores
	end

	for _, file_entry in ipairs(files) do
		table.insert(scores, {
			filename = file_entry.path,
			score = file_entry.seconds,
		})
	end

	return scores
end

local function autocmd_handler(filepath)
	if not sql_wrapper or util.string_isempty(filepath) then
		return
	end

	-- check if file is registered as loaded
	-- if not vim.b.telescope_frecency_registered then
	-- allow [noname] files to go unregistered until BufWritePost
	if not util.fs_stat(filepath).exists then
		return
	end
	if file_is_ignored(filepath) then
		return
	end

	-- vim.b.telescope_frecency_registered = 1
	sql_wrapper:update(filepath)
	-- vim.notify("Telescope-Frecency: updated " .. filepath)
	-- end
end

return {
	init = init,
	get_file_scores = get_file_scores,
	autocmd_handler = autocmd_handler,
	validate = validate_db,
}
