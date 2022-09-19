local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
	error("This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)")
end

local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local conf = require("telescope.config").values
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local sorters = require("telescope.sorters")
local utils = require("telescope.utils")
local db_client = require("telescope._extensions.frecency.db_client")

local os_path_sep = utils.get_separator()

local state = {
	results = {},
	previous_buffer = nil,
	show_scores = false,
	picker = nil,
	display_full_path = false,
}

local function pretty_score(seconds)
	if seconds >= 24 * 60 * 60 then
		return string.format("%dd", seconds / (24 * 60 * 60))
	elseif seconds >= 60 * 60 then
		return string.format("%dh", seconds / (60 * 60))
	elseif seconds >= 60 then
		return string.format("%dm", seconds / 60)
	else
		return string.format("%ds", seconds)
	end
end

local frecency = function(opts)
	opts = opts or {}

	local function get_display_cols()
		local res = {}
		-- score
		res[1] = state.show_scores and { width = 8 } or nil
		-- icon
		if has_devicons and not state.disable_devicons then
			table.insert(res, { width = 2 })
		end
		-- file
		table.insert(res, { remaining = true })
		return res
	end

	local displayer = entry_display.create({
		separator = "",
		hl_chars = { [os_path_sep] = "TelescopePathSeparator" },
		items = get_display_cols(),
	})

	local bufnr, buf_is_loaded, display_filename, hl_filename, display_items, icon, icon_highlight
	local make_display = function(entry)
		bufnr = vim.fn.bufnr
		buf_is_loaded = vim.api.nvim_buf_is_loaded
		display_filename = entry.name
		hl_filename = buf_is_loaded(bufnr(display_filename)) and "TelescopeBufferLoaded" or ""

		display_items = state.show_scores and { { pretty_score(entry.score), "TelescopeFrecencyScores" } } or {}

		if has_devicons and not state.disable_devicons then
			icon, icon_highlight = devicons.get_icon(entry.name, string.match(entry.name, "%a+$"), { default = true })
			table.insert(display_items, { icon, icon_highlight })
		end

		table.insert(display_items, { display_filename, hl_filename })

		return displayer(display_items)
	end

	local update_results = function()
		local filter_updated = false

		if vim.tbl_isempty(state.results) or filter_updated then
			state.results = db_client.get_file_scores()
		end
		return filter_updated
	end

	-- populate initial results
	update_results()

	local entry_maker = function(entry)
		return {
			filename = entry.filename,
			display = make_display,
			ordinal = entry.filename,
			name = entry.filename,
			score = entry.score,
		}
	end

	state.picker = pickers.new(opts, {
		prompt_title = "Recent Files",
		-- attach_mappings = function(prompt_bufnr)
		--   actions.select_default:replace_if(function()
		--     local compinfo = vim.fn.complete_info()
		--     return compinfo.pum_visible == 1
		--   end, function()
		--     local compinfo = vim.fn.complete_info()
		--     local keys = compinfo.selected == -1 and "<C-e><Bs><Right>" or "<C-y><Right>:"
		--     local accept_completion = vim.api.nvim_replace_termcodes(keys, true, false, true)
		--     vim.api.nvim_feedkeys(accept_completion, "n", true)
		--   end)
		--
		--   return true
		-- end,
		finder = finders.new_table({
			results = db_client.get_file_scores(),
			entry_maker = entry_maker,
		}),
		previewer = conf.file_previewer(opts),
		sorter = sorters.get_substr_matcher(),
	})
	state.picker:find()

	vim.api.nvim_buf_set_option(state.picker.prompt_bufnr, "filetype", "frecency")
	vim.api.nvim_buf_set_option(state.picker.prompt_bufnr, "completefunc", "frecency#FrecencyComplete")
	vim.api.nvim_buf_set_keymap(
		state.picker.prompt_bufnr,
		"i",
		"<Tab>",
		"pumvisible() ? '<C-n>'  : '<C-x><C-u>'",
		{ expr = true, noremap = true }
	)
	vim.api.nvim_buf_set_keymap(
		state.picker.prompt_bufnr,
		"i",
		"<S-Tab>",
		"pumvisible() ? '<C-p>'  : ''",
		{ expr = true, noremap = true }
	)
end

local function set_config_state(opt_name, value, default)
	state[opt_name] = value == nil and default or value
end

local health_ok = vim.fn["health#report_ok"]
local health_error = vim.fn["health#report_error"]

local function checkhealth()
	local has_sql, _ = pcall(require, "sqlite")
	if has_sql then
		health_ok("sql.nvim installed.")
	-- return "MOOP"
	else
		health_error("NOOO")
	end
end

return telescope.register_extension({
	setup = function(ext_config)
		set_config_state("db_root", ext_config.db_root, nil)
		set_config_state("show_scores", ext_config.show_scores, false)
		set_config_state("disable_devicons", ext_config.disable_devicons, false)
		set_config_state("display_full_path", ext_config.display_full_path, nil)

		-- start the database client
		db_client.init(
			ext_config.db_root,
			ext_config.ignore_patterns,
			vim.F.if_nil(ext_config.db_safe_mode, true),
			vim.F.if_nil(ext_config.auto_validate, true)
		)
	end,
	exports = {
		frecency = frecency,
		validate_db = db_client.validate,
	},
	health = checkhealth,
})
