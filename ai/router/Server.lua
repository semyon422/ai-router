local class = require("class")
local digest = require("digest")
local json = require("web.json")
local HttpServer = require("web.http.Server")
local InferenceService = require("ai.router.InferenceService")
local RequestMetrics = require("ai.router.RequestMetrics")
local ResponseWriter = require("ai.router.ResponseWriter")

-- Listener and HTTP boundary: routes, bearer authentication, model discovery
-- and sanitized access logs. Authenticated execution belongs to inference.
---@class ai.router.Server
---@operator call: ai.router.Server
---@field users_repo ai.router.UsersRepo
---@field inference ai.router.InferenceService
---@field logger fun(line: string)
---@field get_time fun(): number
---@field mcp_server mcp.Server?
---@field admin_handler (fun(req: web.Request, res: web.Response): boolean?)?
---@field chat_handler (fun(req: web.Request, res: web.Response, ip: string): boolean?)?
---@field http_server web.HttpServer
local Server = class()

Server.max_clients = 64

---@class ai.router.ServerOptions: ai.router.InferenceServiceOptions
---@field scheduler web.CosocketScheduler
---@field client_timeout number?
---@field max_clients integer?
---@field admin_handler (fun(req: web.Request, res: web.Response): boolean?)?
---@field chat_handler (fun(req: web.Request, res: web.Response, ip: string): boolean?)?

---@param options ai.router.ServerOptions
function Server:new(options)
	self.users_repo = options.users_repo
	self.logger = options.logger or print
	assert(type(options.get_time) == "function", "get_time is required")
	self.get_time = options.get_time
	self.admin_handler = options.admin_handler
	self.chat_handler = options.chat_handler
	self.inference = InferenceService({
		users_repo = options.users_repo, usage_repo = options.usage_repo,
		monitor = options.monitor, provider_factory = options.provider_factory,
		-- Keep one clock/logger for HTTP and execution, including test overrides.
		get_time = function() return self.get_time() end,
		logger = function(line) self.logger(line) end,
		max_body_size = options.max_body_size,
		max_concurrent_requests_per_user = options.max_concurrent_requests_per_user,
		max_requests_per_minute = options.max_requests_per_minute,
	})
	local max_clients = options.max_clients or self.max_clients
	assert(max_clients >= 1, "max_clients must be positive")
	self.http_server = HttpServer(options.scheduler, function(req, res, ip)
		self:handle(req, res, ip)
	end, {
		client_timeout = options.client_timeout or 30,
		max_clients = max_clients,
		max_header_size = 16384,
		max_header_count = 64,
	})
end

-- Management's reload boundary; all live routing state has a single owner.
---@param channel_rows ai.router.ChannelRow[]
---@param model_rows ai.router.ModelRow[]
function Server:reload(channel_rows, model_rows)
	self.inference:reload(channel_rows, model_rows)
end

---@param req web.Request
---@return string? token
function Server:authenticate(req)
	local authorization = req.headers:get("Authorization")
	return authorization and authorization:match("^Bearer (.+)$")
end

---@param value any
---@return string
local function sanitizeLogValue(value)
	return (string.gsub(tostring(value), "[%c\127]", "?"))
end

-- One access-log line per request, without keys, bodies or raw error text.
---@param ip string
---@param user ai.router.UserRow?
---@param method string
---@param path string
---@param status integer
---@param duration number
function Server:logRequest(ip, user, method, path, status, duration)
	self.logger(("user=%s ip=%s method=%s path=%s status=%d duration=%.3fs")
		:format(
			sanitizeLogValue(user and user.name or "-"),
			sanitizeLogValue(ip),
			sanitizeLogValue(method),
			sanitizeLogValue(path),
			status,
			duration
		))
end

---@param req web.Request
---@param res web.Response
---@param ip string
function Server:handle(req, res, ip)
	local path = req.uri:match("^[^?]+") or req.uri
	if path == "/mcp" and self.mcp_server then
		self.mcp_server:handleHttp(req, res, ip, 0)
		return
	end
	if self.admin_handler and self.admin_handler(req, res) then return end
	if self.chat_handler and self.chat_handler(req, res, ip) then return end
	local metrics = RequestMetrics(self.get_time)
	local token = self:authenticate(req)
	local user = token and self.users_repo:findByKeyHash(digest.hash("sha256", token, true)) or nil
	---@type integer
	local status
	if not user or user.disabled then
		ResponseWriter.sendError(res, 401, "invalid access token", "authentication_error", "invalid_api_key")
		status = 401
	elseif req.method == "GET" and path == "/v1/models" then
		local grants = {}
		for _, model in ipairs(self.users_repo:getGrants(user.id)) do
			if self.inference.router.state.public_models[model] then
				table.insert(grants, {id = model, object = "model", owned_by = "router"})
			end
		end
		ResponseWriter.sendJson(res, {object = "list", data = json.array(grants)})
		status = 200
	elseif req.method ~= "POST" or (path ~= "/v1/chat/completions" and path ~= "/v1/responses") then
		ResponseWriter.sendError(res, 404, "route not found", "invalid_request_error", "not_found")
		status = 404
	else
		status = self.inference:process(req, res, user,
			path == "/v1/responses" and "responses" or "chat_completions", metrics)
	end
	self:logRequest(ip, user, req.method, path, status, self.get_time() - metrics.started_at)
end

---@param host string
---@param port integer
---@return true?
---@return string?
function Server:start(host, port)
	return self.http_server:start(host, port)
end

function Server:stop()
	self.http_server:stop()
end

---@return string?
---@return integer?
function Server:getAddress()
	return self.http_server:getAddress()
end

return Server
