local util = require("telescope._extensions.frecency.util")
local vim = vim
local Path = require("plenary.path")

local has_sqlite, sqlite = pcall(require, "sqlite")
if not has_sqlite then
	error("This plugin requires sqlite.lua (https://github.com/tami5/sqlite.lua) " .. tostring(sqlite))
end

local db_table = {}
db_table.files = "files"

local M = {}

function M:new()
	local o = {}
	setmetatable(o, self)
	self.__index = self
	self.db = nil

	return o
end

function M:bootstrap(db_root)
	if self.db then
		return
	end

	-- create the db if it doesn't exist
	db_root = db_root or vim.fn.stdpath("data")
	local db_filename = db_root .. "/file_recency.sqlite3"
	self.db = sqlite:open(db_filename)
	if not self.db then
		print("error")
		return
	end

	local first_run = false
	if not self.db:exists(db_table.files) then
		first_run = true
		-- create tables if they don't exist
		self.db:create(db_table.files, {
			id = { "INTEGER", "PRIMARY", "KEY" },
			timestamp = "REAL",
			path = "TEXT",
		})
	end

	self.db:close()
	return first_run
end

--

function M:do_transaction(t, params)
	-- print(vim.inspect(t))
	-- print(vim.inspect(params))
	return self.db:with_open(function(db)
		local case = {
			[1] = function()
				return db:select(t.cmd_data, params)
			end,
			[2] = function()
				return db:insert(t.cmd_data, params)
			end,
			[3] = function()
				return db:delete(t.cmd_data, params)
			end,
			[4] = function()
				return db:eval(t.cmd_data, params)
			end,
		}
		return case[t.cmd]()
	end)
end

local cmd = {
	select = 1,
	insert = 2,
	delete = 3,
	eval = 4,
}

local queries = {
	file_add_entry = {
		cmd = cmd.eval,
		cmd_data = "INSERT INTO files (path, timestamp) values(:path, julianday('now'));",
	},
	file_delete_entry = {
		cmd = cmd.delete,
		cmd_data = db_table.files,
	},
	file_get_entries = {
		cmd = cmd.select,
		cmd_data = db_table.files,
	},
	file_update_timestamp = {
		cmd = cmd.eval,
		cmd_data = "UPDATE files SET timestamp = julianday('now') WHERE path == :path;",
	},
	recency_score = {
		cmd = cmd.eval,
		cmd_data = "select path, CAST((julianday('now') - julianday(timestamp)) * 24 * 60 * 60 AS INTEGER) seconds from files where path != :exclude order by seconds;",
	},
}

M.queries = queries

--

local function row_id(entry)
	return (not vim.tbl_isempty(entry)) and entry[1].id or nil
end

function M:update(filepath)
	filepath = Path:new(filepath):absolute()
	local filestat = util.fs_stat(filepath)
	if vim.tbl_isempty(filestat) or filestat.exists == false or filestat.isdirectory == true then
		return
	end

	-- create entry if it doesn't exist
	local file_id
	file_id = row_id(self:do_transaction(queries.file_get_entries, { where = { path = filepath } }))
	if not file_id then
		self:do_transaction(queries.file_add_entry, { path = filepath })
	else
		-- ..or update existing entry
		self:do_transaction(queries.file_update_timestamp, { path = filepath })
	end
end

return M
