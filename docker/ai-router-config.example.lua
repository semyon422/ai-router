return {
	host = "127.0.0.1",
	port = 28083,
	-- HMAC signing only. Web login uses each user's API key.
	session_secret = "REPLACE_WITH_RANDOM_SESSION_SECRET",
	mcp_token = "REPLACE_WITH_RANDOM_MCP_TOKEN",
	db_path = "/router-state/router.db",
	network_path = "/router-state/network.lua",
	tls_cafile = "resources/certs/cacert.pem",
}
