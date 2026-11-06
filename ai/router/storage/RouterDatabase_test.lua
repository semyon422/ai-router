local RouterDatabase = require("ai.router.storage.RouterDatabase")
local LjsqliteDatabase = require("rdb.db.LjsqliteDatabase")

local test = {}

---@param t testing.T
function test.creates_empty_database(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	t:eq(storage.db:user_version(), 10)
	local names = {}
	for _, row in ipairs(storage.db:query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) do
		table.insert(names, row.name)
	end
	t:tdeq(names, {
		"router_channels",
		"router_models",
		"router_oauth_credentials",
		"router_request_details",
		"router_request_logs",
		"router_usage_models",
		"router_user_models",
		"router_users",
		"sqlite_sequence",
	})
	storage:close()
end

---@param t testing.T
function test.migrate_is_idempotent(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	storage:migrate()
	t:eq(storage.db:user_version(), 10)
	t:eq(#storage.models.router_users:select(), 0)
	storage:close()
end

---@param t testing.T
function test.rejects_future_version(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	storage.db:user_version(11)
	t:has_error(function() storage:migrate() end)
	t:eq(storage.db:user_version(), 11)
	storage:close()
end

---@param t testing.T
function test.schema_failure_rolls_back(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_users (id INTEGER PRIMARY KEY)")
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 0)
	t:eq(#db:query("PRAGMA table_info(router_users)"), 1)
	db:exec("BEGIN")
	db:exec("ROLLBACK")
	db:close()
end

---@param t testing.T
function test.rejects_legacy_schema_without_migrating(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_models (id INTEGER PRIMARY KEY, name TEXT, chain TEXT)")
	db:query("INSERT INTO router_models VALUES (1, 'lite', '[\"a\",\"b\"]')")
	db:user_version(1)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 1)
	t:eq(db:query("SELECT chain FROM router_models")[1].chain, '["a","b"]')
	t:tdeq(db:columns("router_models"), {"id", "name", "chain"})
	db:close()
end

---@param t testing.T
function test.rejects_version_two_without_modifying_priority_or_targets(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_subscriptions (id INTEGER PRIMARY KEY, priority INTEGER)")
	db:exec("CREATE TABLE router_models (id INTEGER PRIMARY KEY, target TEXT)")
	db:exec("INSERT INTO router_subscriptions VALUES (1, 10)")
	db:exec("INSERT INTO router_models VALUES (1, 'gpt')")
	db:user_version(2)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 2)
	t:eq(db:query("SELECT priority FROM router_subscriptions")[1].priority, 10)
	t:eq(db:query("SELECT target FROM router_models")[1].target, "gpt")
	db:close()
end

---@param t testing.T
function test.rejects_subscription_schema_without_renaming_data(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_subscriptions (id INTEGER PRIMARY KEY, name TEXT)")
	db:exec("CREATE TABLE router_usage_models (subscription TEXT)")
	db:exec("INSERT INTO router_subscriptions VALUES (1, 'openai')")
	db:exec("INSERT INTO router_usage_models VALUES ('openai')")
	db:user_version(3)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 3)
	t:eq(db:query("SELECT name FROM router_subscriptions")[1].name, "openai")
	t:eq(db:query("SELECT subscription FROM router_usage_models")[1].subscription, "openai")
	db:close()
end

---@param t testing.T
function test.rejects_version_four_without_adding_request_logs(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_channels (id INTEGER PRIMARY KEY, name TEXT)")
	db:exec("INSERT INTO router_channels VALUES (3, 'zai')")
	db:user_version(4)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 4)
	t:eq(db:query("SELECT name FROM router_channels")[1].name, "zai")
	t:eq(#db:query("SELECT name FROM sqlite_master WHERE name = 'router_request_logs'"), 0)
	db:close()
end

---@param t testing.T
function test.rejects_version_five_without_rewriting_request_history(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_request_logs (id INTEGER PRIMARY KEY, model TEXT)")
	db:exec("INSERT INTO router_request_logs VALUES (7, 'zai/glm')")
	db:user_version(5)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 5)
	t:tdeq(db:columns("router_request_logs"), {"id", "model"})
	t:eq(db:query("SELECT model FROM router_request_logs")[1].model, "zai/glm")
	db:close()
end

---@param t testing.T
function test.rejects_version_six_without_dropping_legacy_windows(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_channel_windows (channel_id INTEGER PRIMARY KEY, used_percent REAL)")
	db:exec("INSERT INTO router_channel_windows VALUES (1, 42.5)")
	db:user_version(6)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 6)
	t:eq(db:query("SELECT used_percent FROM router_channel_windows")[1].used_percent, 42.5)
	db:close()
end

---@param t testing.T
function test.rejects_version_seven_without_importing_oauth_files(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec("CREATE TABLE router_channels (id INTEGER PRIMARY KEY, config TEXT)")
	db:exec([[INSERT INTO router_channels VALUES (1, '{"auth_path":"legacy.lua"}')]])
	db:user_version(7)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 7)
	t:eq(db:query("SELECT config FROM router_channels")[1].config, '{"auth_path":"legacy.lua"}')
	t:eq(#db:query("SELECT name FROM sqlite_master WHERE name = 'router_oauth_credentials'"), 0)
	db:close()
end

---@param t testing.T
function test.upgrades_eight_preserving_accounts_grants_and_other_tables(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec([[CREATE TABLE router_users (id INTEGER PRIMARY KEY, name TEXT UNIQUE, key_hash TEXT UNIQUE,
		key_hint TEXT, disabled INTEGER, max_concurrency INTEGER, max_rpm INTEGER, created_at INTEGER, updated_at INTEGER);
		INSERT INTO router_users VALUES (7, 'existing', 'hash', 'hint', 0, 2, 10, 100, 200);
		CREATE TABLE router_user_models (user_id INTEGER, model TEXT);
		INSERT INTO router_user_models VALUES (7, 'model');
		CREATE TABLE router_request_logs (id INTEGER PRIMARY KEY, user TEXT);
		INSERT INTO router_request_logs VALUES (1, 'existing');
		CREATE TABLE router_usage_models (requests INTEGER);
		INSERT INTO router_usage_models VALUES (42);
		CREATE TABLE router_oauth_credentials (generation TEXT);
		INSERT INTO router_oauth_credentials VALUES ('unchanged');]])
	db:user_version(8)
	local storage = RouterDatabase(db)
	storage:migrate()
	t:eq(db:user_version(), 10)
	local user = db:query("SELECT * FROM router_users")[1]
	t:eq(user.id, 7)
	t:eq(user.role, "user")
	t:eq(user.key_hash, "hash")
	t:eq(user.max_concurrency, 2)
	t:eq(user.updated_at, 200)
	t:eq(db:query("SELECT * FROM router_user_models")[1].user_id, 7)
	t:eq(db:query("SELECT * FROM router_usage_models")[1].requests, 42)
	t:eq(db:query("SELECT * FROM router_oauth_credentials")[1].generation, "unchanged")
	t:eq(#db:query("SELECT * FROM router_request_logs"), 0)
	db:exec("DELETE FROM router_users")
	db:exec("INSERT INTO router_users (name, key_hash, key_hint, created_at, updated_at) VALUES ('new', 'new', 'new', 1, 1)")
	t:assert(db:query("SELECT id FROM router_users")[1].id > 7)
	storage:migrate()
	t:eq(#db:query("SELECT * FROM router_users"), 1)
	db:close()
end

---@param t testing.T
function test.failed_upgrade_rolls_back_account_rebuild(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	storage.db:exec("DROP TABLE router_request_logs")
	storage.db:user_version(8)
	t:has_error(function() storage:migrate() end)
	t:eq(storage.db:user_version(), 8)
	t:eq(#storage.db:query("SELECT name FROM sqlite_master WHERE name = 'router_users_v8'"), 0)
	t:eq(#storage.db:query("SELECT * FROM router_users"), 0)
	storage:close()
end

---@param t testing.T
function test.upgrades_nine_preserving_admins_and_owned_history(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	storage.db:exec("DROP TABLE router_request_details")
	storage.db:exec([[INSERT INTO router_users (id,name,role,key_hash,key_hint,created_at,updated_at)
		VALUES (42,'admin','admin','hash','hint',1,2)]])
	storage.db:user_version(9)
	local log = storage.models.router_request_logs:create({user_id = 42, created_at = 1000, user = "admin",
		model = "old", channel = "old", upstream_model = "old", protocol = "responses", stream = true,
		status = 200, duration_ms = 20, input_tokens = 5, output_tokens = 2, cached_input_tokens = 0, estimated = false})
	storage:migrate()
	t:eq(storage.db:user_version(), 10)
	t:eq(storage.db:query("SELECT model FROM router_request_logs WHERE id = " .. log.id)[1].model, "old")
	t:eq(storage.models.router_users:select()[1].role, "admin")
	t:eq(storage.models.router_users:select()[1].id, 42)
	t:eq(#storage.db:query("SELECT * FROM router_request_details"), 0)
	storage:migrate()
	storage:close()
end

---@param t testing.T
function test.failed_nine_upgrade_keeps_version_and_existing_tables(t)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	storage.db:user_version(9)
	t:has_error(function() storage:migrate() end)
	t:eq(storage.db:user_version(), 9)
	t:eq(#storage.db:query("SELECT * FROM router_request_details"), 0)
	storage:close()
end

function test.failure_in_second_upgrade_step_restores_schema_eight_and_unowned_logs(t)
	local db = LjsqliteDatabase()
	db:open(":memory:")
	db:exec([[CREATE TABLE router_users (id INTEGER PRIMARY KEY, name TEXT UNIQUE, key_hash TEXT UNIQUE,
		key_hint TEXT, disabled INTEGER, max_concurrency INTEGER, max_rpm INTEGER, created_at INTEGER, updated_at INTEGER);
		INSERT INTO router_users VALUES (7, 'old', 'hash', 'hint', 0, 2, 10, 100, 200);
		CREATE TABLE router_request_logs (id INTEGER PRIMARY KEY, user TEXT);
		INSERT INTO router_request_logs VALUES (123, 'unowned');
		CREATE TABLE router_request_details (conflict INTEGER);]])
	db:user_version(8)
	local storage = RouterDatabase(db)
	t:has_error(function() storage:migrate() end)
	t:eq(db:user_version(), 8)
	t:eq(db:query("SELECT user FROM router_request_logs WHERE id = 123")[1].user, "unowned")
	t:eq(db:query("SELECT key_hash FROM router_users WHERE id = 7")[1].key_hash, "hash")
	t:eq(#db:query("PRAGMA table_info(router_users)"), 9)
	t:eq(#db:query("SELECT name FROM sqlite_master WHERE name = 'router_users_v8'"), 0)
	db:exec("BEGIN")
	db:exec("ROLLBACK")
	db:close()
end

return test
