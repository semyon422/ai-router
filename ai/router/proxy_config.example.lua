return {
	host = "127.0.0.1",
	port = 28083,
	-- Web-session HMAC secret (at least 16 random characters), not a login password.
	session_secret = "replace-with-a-long-random-session-secret",
	-- Privileged management API: separate token, at least 32 random characters.
	mcp_token = "replace-with-a-separate-random-management-token",
	db_path = "userdata/ai_router.db",
	network_path = "userdata/network.lua",
	tls_cafile = "resources/certs/cacert.pem",
	-- Upstream model prices, USD per million tokens; omitted models cost 0.
	-- Keys are upstream model names (after per-channel redirects).
	model_prices = {},
	upstream_timeout = 300,
	client_timeout = 300,
	max_body_size = 16 * 1024 * 1024,
	max_clients = 64,
	max_concurrent_requests_per_user = 4,
	max_requests_per_minute = 120,
	usage_poll_interval = 60,
}
