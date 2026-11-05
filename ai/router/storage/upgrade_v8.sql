ALTER TABLE router_users RENAME TO router_users_v8;
CREATE TABLE router_users (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL UNIQUE,
	role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
	key_hash TEXT NOT NULL UNIQUE,
	key_hint TEXT NOT NULL,
	disabled INTEGER NOT NULL DEFAULT 0,
	max_concurrency INTEGER,
	max_rpm INTEGER,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
INSERT INTO router_users (id, name, key_hash, key_hint, disabled, max_concurrency, max_rpm, created_at, updated_at)
SELECT id, name, key_hash, key_hint, disabled, max_concurrency, max_rpm, created_at, updated_at FROM router_users_v8;
DROP TABLE router_users_v8;
DROP TABLE router_request_logs;
CREATE TABLE router_request_logs (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	user TEXT NOT NULL,
	model TEXT NOT NULL,
	channel TEXT NOT NULL,
	upstream_model TEXT NOT NULL,
	protocol TEXT NOT NULL,
	stream INTEGER NOT NULL,
	status INTEGER NOT NULL,
	duration_ms INTEGER NOT NULL,
	input_tokens INTEGER NOT NULL,
	output_tokens INTEGER NOT NULL,
	cached_input_tokens INTEGER NOT NULL,
	estimated INTEGER NOT NULL,
	ttft_ms INTEGER,
	generation_ms INTEGER,
	error_code TEXT
);
CREATE INDEX router_request_logs_created_at ON router_request_logs (created_at);
CREATE INDEX router_request_logs_user_id ON router_request_logs (user_id, id);
