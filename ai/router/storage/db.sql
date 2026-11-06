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

CREATE TABLE router_user_models (
	user_id INTEGER NOT NULL,
	model TEXT NOT NULL,
	PRIMARY KEY (user_id, model)
);

CREATE TABLE router_channels (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE,
	kind TEXT NOT NULL,
	enabled INTEGER NOT NULL DEFAULT 1,
	config TEXT NOT NULL,
	limits TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);

CREATE TABLE router_models (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE,
	target TEXT NOT NULL,
	description TEXT,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);

CREATE TABLE router_oauth_credentials (
	channel_id INTEGER PRIMARY KEY,
	generation TEXT NOT NULL,
	access_token TEXT NOT NULL,
	refresh_token TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	account_id TEXT NOT NULL
);

CREATE TABLE router_usage_models (
	bucket INTEGER NOT NULL,
	user TEXT NOT NULL,
	model TEXT NOT NULL,
	upstream_model TEXT NOT NULL,
	channel TEXT NOT NULL,
	requests INTEGER NOT NULL,
	errors INTEGER NOT NULL,
	input_tokens INTEGER NOT NULL,
	output_tokens INTEGER NOT NULL,
	cached_input_tokens INTEGER NOT NULL DEFAULT 0,
	estimated_requests INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (bucket, user, model, upstream_model, channel)
);

CREATE INDEX router_usage_channel_bucket ON router_usage_models (channel, bucket);

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

CREATE TABLE router_request_details (
	request_id INTEGER PRIMARY KEY,
	user_id INTEGER NOT NULL,
	request_path TEXT NOT NULL,
	request_body BLOB NOT NULL CHECK (length(CAST(request_body AS BLOB)) <= 16777216),
	response_body BLOB NOT NULL CHECK (length(CAST(response_body AS BLOB)) <= 16777216),
	request_bytes INTEGER NOT NULL,
	response_bytes INTEGER NOT NULL,
	request_state TEXT NOT NULL CHECK (request_state IN ('not_read', 'partial', 'complete')),
	request_truncated INTEGER NOT NULL CHECK (request_truncated IN (0, 1)),
	response_truncated INTEGER NOT NULL CHECK (response_truncated IN (0, 1)),
	response_complete INTEGER NOT NULL CHECK (response_complete IN (0, 1)),
	capture_failed INTEGER NOT NULL CHECK (capture_failed IN (0, 1)),
	http_status INTEGER NOT NULL,
	response_content_type TEXT NOT NULL
);

CREATE INDEX router_request_details_user_id ON router_request_details (user_id, request_id);
