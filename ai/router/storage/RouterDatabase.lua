local class = require("class")
local TableOrm = require("rdb.TableOrm")
local Models = require("rdb.Models")
local users_model = require("ai.router.storage.models.router_users")
local user_models_model = require("ai.router.storage.models.router_user_models")
local channels_model = require("ai.router.storage.models.router_channels")
local models_model = require("ai.router.storage.models.router_models")
local usage_model = require("ai.router.storage.models.router_usage_models")
local request_logs_model = require("ai.router.storage.models.router_request_logs")
local oauth_model = require("ai.router.storage.models.router_oauth_credentials")
local io_util = require("io_util")

-- The schema lives next to this module; resolve it from the module path, not the checkout layout.
local schema_path = debug.getinfo(1, "S").source:match("^@?(.+)/[^/]+$") .. "/db.sql"

---@class ai.router.RouterDatabase
---@operator call: ai.router.RouterDatabase
---@field db rdb.SqliteDatabase
---@field orm rdb.TableOrm
---@field models rdb.Models
local RouterDatabase = class()

RouterDatabase.path = "userdata/ai_router.db"
local user_version = 9

---@param db rdb.SqliteDatabase
function RouterDatabase:new(db)
	self.db = db
	self.orm = TableOrm(db)
	self.models = Models({
		router_users = users_model,
		router_user_models = user_models_model,
		router_channels = channels_model,
		router_models = models_model,
		router_usage_models = usage_model,
		router_request_logs = request_logs_model,
		router_oauth_credentials = oauth_model,
	}, self.orm)
end

function RouterDatabase:open()
	local db = self.db
	db:open(self.path)
	local ok, err = pcall(function()
		db:exec("PRAGMA journal_mode = WAL")
		db:exec("PRAGMA synchronous = NORMAL")
		db:exec("PRAGMA busy_timeout = 10000")
		self:migrate()
	end)
	if not ok then
		db:close()
		error(err)
	end
end

function RouterDatabase:migrate()
	assert(self.db:user_version() <= user_version, "router database is newer than this code")
	local version = self.db:user_version()
	assert(version == 0 or version == 8 or version == user_version,
		"router database schema is incompatible; only schema 8 can be upgraded")
	local ok, err = pcall(function()
		if version == 0 or version == 8 then
			self.db:exec("BEGIN")
			local path = version == 8 and schema_path:gsub("db.sql$", "upgrade_v8.sql") or schema_path
			self.db:exec(io_util.read_file(path))
			self.db:user_version(user_version)
			self.db:exec("COMMIT")
		end
	end)
	if not ok then
		self.db:exec("ROLLBACK")
		error(err)
	end
end

function RouterDatabase:close()
	self.db:close()
end

return RouterDatabase
