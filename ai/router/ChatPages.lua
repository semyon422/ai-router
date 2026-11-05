local class = require("class")
local digest = require("digest")
local etlua = require("web.etlua")
local json = require("web.json")
local io_util = require("io_util")
local http_util = require("web.http.util")
local Sessions = require("web.framework.Sessions")
local RequestMetrics = require("ai.router.RequestMetrics")

-- Assets live next to this module; resolve them from the module path, not the checkout layout.
local chat_dir = debug.getinfo(1, "S").source:match("^@?(.+)/[^/]+$") .. "/chat"

-- Web chat for named users: the user's API key is exchanged once for an
-- HMAC-signed session cookie, and POST /chat/completions runs the same
-- shared inference path as /v1/chat/completions (limits, grants,
-- accounting, request log).
---@class ai.router.ChatPages
---@operator call: ai.router.ChatPages
---@field sessions web.Sessions
---@field users_repo ai.router.UsersRepo
---@field server ai.router.Server
---@field get_time fun(): number
---@field stylesheet string
---@field theme_script string
---@field chat_script string
---@field templates {[string]: fun(env: table?): string}
local ChatPages = class()

ChatPages.cookie_name = "router_chat"
ChatPages.cookie_max_age = 10 * 365 * 24 * 3600

---@class ai.router.ChatPagesOptions
---@field users_repo ai.router.UsersRepo
---@field server ai.router.Server
---@field password string
---@field get_time (fun(): number)?

---@param options ai.router.ChatPagesOptions
function ChatPages:new(options)
	assert(type(options.password) == "string" and #options.password >= 16,
		"admin password must contain at least 16 characters")
	self.users_repo = options.users_repo
	self.server = options.server
	self.get_time = options.get_time or os.time
	-- Domain-separated derivation keeps the chat HMAC independent of the
	-- admin session while needing no extra configuration.
	self.sessions = Sessions(ChatPages.cookie_name,
		digest.hash("sha256", options.password .. "\0ai-router-chat", true))
	self.stylesheet = io_util.read_file(chat_dir .. "/chat.css")
	self.theme_script = io_util.read_file(chat_dir .. "/theme.js")
	self.chat_script = io_util.read_file(chat_dir .. "/chat.js")
	self.templates = {}
	self.templates.login = etlua.compile(io_util.read_file(chat_dir .. "/login.etlua"), "@chat/login")
	self.templates.chat = etlua.compile(io_util.read_file(chat_dir .. "/chat.etlua"), "@chat/chat")
end

---@param res web.Response
---@param status integer
---@param html string
local function send(res, status, html)
	res.status = status
	res.headers:set("Content-Type", "text/html; charset=utf-8")
	res.headers:set("Cache-Control", "no-store")
	res:set_length(#html)
	res:send(html)
end

---@param res web.Response
---@param status integer
---@param value {[string]: any}
local function sendJson(res, status, value)
	local body = json.encode(value)
	res.status = status
	res.headers:set("Content-Type", "application/json; charset=utf-8")
	res.headers:set("Cache-Control", "no-store")
	res:set_length(#body)
	res:send(body)
end

---@param res web.Response
---@param location string
local function redirect(res, location)
	res.status = 303
	res.headers:set("Location", location)
	res.headers:set("Cache-Control", "no-store")
	res:set_length(0)
	res:send("")
end

---A server-keyed fingerprint binds sessions to the full key hash without
---exposing that hash in the readable cookie.
---@param user ai.router.UserRow
---@return string
function ChatPages:keyFingerprint(user)
	return digest.hash("sha256", self.sessions:hmac("chat-key\0" .. user.key_hash), true)
end

---Decodes the session and re-reads the user row on every request, so
---disable and delete revoke chat sessions immediately, and key rotation
---revokes them via a fingerprint of the full key hash.
---@param req web.Request
---@return table? session
---@return ai.router.UserRow? user
function ChatPages:session(req)
	local session = self.sessions:get(req.headers)
	if session and type(session.user_id) == "number" then
		local user = self.users_repo:get(session.user_id)
		if user and not user.disabled and self:keyFingerprint(user) == session.key_fingerprint then
			return session, user
		end
	end
	return nil
end

---@param res web.Response
function ChatPages:clearSession(res)
	res.headers:add("Set-Cookie", ChatPages.cookie_name .. "=; Path=/; Max-Age=0")
end

---Granted models the web chat can serve: public catalog models whose
---channel speaks Chat Completions (not native Responses).
---@param user ai.router.UserRow
---@return string[]
function ChatPages:chatModels(user)
	---@type string[]
	local models = {}
	for _, model in ipairs(self.users_repo:getGrants(user.id)) do
		if self.server.inference.router.state.public_models[model] then
			local candidate = self.server.inference.router:resolve(model)
			if candidate and candidate.channel.kind ~= "openai" then
				table.insert(models, model)
			end
		end
	end
	table.sort(models)
	return models
end

---@param req web.Request
---@param res web.Response
function ChatPages:login(req, res)
	local form = http_util.get_form(req) or {}
	local key = form.api_key
	local user
	if type(key) == "string" and key ~= "" then
		user = self.users_repo:findByKeyHash(digest.hash("sha256", key, true))
	end
	if user and not user.disabled then
		self.sessions:set(res.headers, {user_id = user.id, key_fingerprint = self:keyFingerprint(user)},
			ChatPages.cookie_max_age)
		redirect(res, "/chat")
	else
		-- One generic message: never reveal which check failed.
		send(res, 401, self.templates.login({error_message = "Invalid API key.",
			stylesheet = self.stylesheet, theme_script = self.theme_script}))
	end
end

---@param req web.Request
---@param res web.Response
function ChatPages:logout(req, res)
	local session = self.sessions:get(req.headers)
	local form = http_util.get_form(req) or {}
	if not session or not self.sessions:validate_csrf_token(session, form.csrf_token) then
		send(res, 403, "Invalid CSRF token.")
	else
		self:clearSession(res)
		redirect(res, "/chat")
	end
end

---@param req web.Request
---@param res web.Response
---@param ip string
function ChatPages:completions(req, res, ip)
	local session, user = self:session(req)
	if not session or not user or user.disabled then
		self:clearSession(res)
		sendJson(res, 401, {error = {message = "Sign in with your API key to use the chat.",
			type = "authentication_error", code = "invalid_session"}})
		return
	end
	local token = req.headers:get("X-CSRF-Token")
	if not self.sessions:validate_csrf_token(session, token) then
		sendJson(res, 403, {error = {message = "Invalid CSRF token.",
			type = "invalid_request_error", code = "csrf_mismatch"}})
		return
	end
	local metrics = RequestMetrics(self.server.get_time)
	local started_at = metrics.started_at
	local status = self.server.inference:process(req, res, user, "chat_completions", metrics)
	self.server:logRequest(ip, user, "POST", "/chat/completions", status, self.server.get_time() - started_at)
end

---@param res web.Response
---@param session {user_id: integer, csrf_token: string}
---@param user ai.router.UserRow
function ChatPages:renderChat(res, session, user)
	local models = self:chatModels(user)
	local config = json.encode({csrfToken = session.csrf_token, userId = user.id, model = models[1] or ""})
	-- Keep the inline JSON from closing the script element; "\/" is still valid JSON.
	config = config:gsub("</", "<\\/")
	send(res, 200, self.templates.chat({
		username = user.name,
		models = models,
		config = config,
		csrf_token = session.csrf_token,
		stylesheet = self.stylesheet,
		theme_script = self.theme_script,
		page_script = self.chat_script,
	}))
end

---@param req web.Request
---@param res web.Response
---@param ip string
---@return boolean
function ChatPages:handle(req, res, ip)
	local path = req.uri:match("^[^?]+") or req.uri
	if path ~= "/chat" and not path:match("^/chat/") then return false end
	if path == "/chat" then
		if req.method ~= "GET" then
			res.headers:set("Allow", "GET")
			send(res, 405, "The chat page is read-only; submit messages through POST /chat/completions.")
			return true
		end
		local session, user = self:session(req)
		if not session then
			-- A decodable session means the user was disabled, deleted, or the
			-- key was rotated since sign-in; say so and clear the cookie.
			if self.sessions:get(req.headers) then
				self:clearSession(res)
				send(res, 200, self.templates.login({
					error_message = "Your session is no longer valid. Sign in with your API key.",
					stylesheet = self.stylesheet, theme_script = self.theme_script}))
			else
				send(res, 200, self.templates.login({stylesheet = self.stylesheet, theme_script = self.theme_script}))
			end
		else
			self:renderChat(res, session, user)
		end
		return true
	end
	if path == "/chat/login" then
		if req.method ~= "POST" then
			res.headers:set("Allow", "POST")
			send(res, 405, "Sign-in accepts form posts only.")
			return true
		end
		self:login(req, res)
		return true
	end
	if path == "/chat/logout" then
		if req.method ~= "POST" then
			res.headers:set("Allow", "POST")
			send(res, 405, "Sign-out accepts form posts only.")
			return true
		end
		self:logout(req, res)
		return true
	end
	if path == "/chat/completions" then
		if req.method ~= "POST" then
			res.headers:set("Allow", "POST")
			sendJson(res, 405, {error = {message = "Only POST is supported.",
				type = "invalid_request_error", code = "method_not_allowed"}})
			return true
		end
		self:completions(req, res, ip)
		return true
	end
	send(res, 404, "Unknown page.")
	return true
end

return ChatPages
