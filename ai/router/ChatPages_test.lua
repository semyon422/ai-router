local coext = require("coext")
---@type {gettime: fun(): number}
local socket = require("socket")
local json = require("web.json")
local digest = require("digest")
local CosocketScheduler = require("web.luasocket.CosocketScheduler")
local http_util = require("web.http.util")
local Server = require("ai.router.Server")
local ChatPages = require("ai.router.ChatPages")
local CompatProvider = require("ai.router.CompatProvider")
local UsageMonitor = require("ai.router.UsageMonitor")
local UsageRepo = require("ai.router.UsageRepo")
local UsersRepo = require("ai.router.UsersRepo")
local ChannelsRepo = require("ai.router.ChannelsRepo")
local ModelsRepo = require("ai.router.ModelsRepo")
local RouterDatabase = require("ai.router.storage.RouterDatabase")
local LjsqliteDatabase = require("rdb.db.LjsqliteDatabase")

local test = {}

local PASSWORD = "test-admin-password-test"
local TOKEN = "router-secret-router-secret-router"

---@class test.FakeProvider
---@field complete (fun(self: test.FakeProvider, body: table, upstream_model: string): openai.CanonicalMessage?, string?, table?)?
---@field completeStream (fun(self: test.FakeProvider, body: table, upstream_model: string, on_delta: fun(delta: table): boolean?): openai.CanonicalMessage?, string?, table?)?
---@field complete_count integer
---@field stream_count integer

-- A fake provider returning a canned canonical message or failures.
---@param opts {message: table?, deltas: table[]?, err: string?, provider_error: table?}?
---@return test.FakeProvider
local function fakeProvider(opts)
	opts = opts or {}
	---@type test.FakeProvider
	local provider = {complete_count = 0, stream_count = 0}
	function provider:complete(body, upstream_model)
		self.complete_count = self.complete_count + 1
		if opts.message then return opts.message end
		return nil, opts.err, opts.provider_error
	end
	function provider:completeStream(body, upstream_model, on_delta)
		self.stream_count = self.stream_count + 1
		for _, delta in ipairs(opts.deltas or {}) do
			if on_delta(delta) == false then return nil, "downstream response stream closed" end
		end
		if opts.message then return opts.message end
		return nil, opts.err, opts.provider_error
	end
	return provider
end

local ok_message = {
	content = "hello",
	finish_reason = "stop",
	usage = {input_tokens = 10, output_tokens = 5, cached_input_tokens = 2},
}

---@class test.Stack
---@field storage ai.router.RouterDatabase
---@field server ai.router.Server
---@field chat ai.router.ChatPages
---@field scheduler web.CosocketScheduler
---@field users ai.router.UsersRepo
---@field channels ai.router.ChannelsRepo
---@field models ai.router.ModelsRepo
---@field monitor ai.router.UsageMonitor
---@field usage_repo ai.router.UsageRepo
---@field providers_by_name {[string]: test.FakeProvider}
---@field user ai.router.UserRow

---@param opts {providers: {[string]: test.FakeProvider}}?
---@return test.Stack
local function startStack(opts)
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	local users = UsersRepo(storage.models)
	local channels = ChannelsRepo(storage.models)
	local models = ModelsRepo(storage.models)
	local usage_repo = UsageRepo(storage.models)
	local monitor = UsageMonitor({usage_repo = usage_repo, logger = function() end})
	---@type {[string]: test.FakeProvider}
	local providers_by_name = {}
	if opts and opts.providers then providers_by_name = opts.providers end
	local scheduler = CosocketScheduler()
	local server = Server({
		get_time = scheduler.get_time,
		scheduler = scheduler,
		users_repo = users,
		usage_repo = usage_repo,
		monitor = monitor,
		logger = function() end,
		provider_factory = function(channel)
			return providers_by_name[channel.name]
		end,
	})
	local user = users:create("alice", 1000)
	storage.models.router_users:update(
		{key_hash = digest.hash("sha256", TOKEN, true), key_hint = TOKEN:sub(-4)},
		{id = user.id}
	)
	users:setGrants(user.id, {"zai-1/glm-5.3", "openai-1/gpt-6-luna", "lite"})
	channels:create("zai-1", "zai", {
		base_url = "https://api.z.ai/api/coding/paas/v4",
		api_key = "key",
		models = {"glm-5.3"},
	}, {}, 1000)
	channels:create("openai-1", "openai_compat", {
		base_url = "http://localhost:28080/v1",
		models = {"gpt-6-luna", "glm-5.3"},
	}, {}, 1000)
	models:create("lite", "zai-1/glm-5.3", nil, 1000)
	server:reload(channels:list(), models:list())
	local chat = ChatPages({users_repo = users, server = server, session_secret = PASSWORD})
	server.chat_handler = function(req, res, ip) return chat:handle(req, res, ip) end
	local stack = {
		storage = storage,
		server = server,
		chat = chat,
		scheduler = scheduler,
		users = users,
		channels = channels,
		models = models,
		monitor = monitor,
		usage_repo = usage_repo,
		providers_by_name = providers_by_name,
		user = user,
	}
	assert(server:start("127.0.0.1", 0))
	return stack
end

---@param t testing.T
---@param stack test.Stack
---@param thread thread
local function pump(t, stack, thread)
	local deadline = socket.gettime() + 2
	while coroutine.status(thread) ~= "dead" do
		local ok, err = stack.scheduler:update(0.01)
		if not ok and err then error(err) end
		t:assert(socket.gettime() < deadline)
	end
end

---@class test.RequestOptions
---@field token string?
---@field cookie string?
---@field csrf string?
---@field method string?
---@field content_type string?

---@param t testing.T
---@param stack test.Stack
---@param path string
---@param body table?|string
---@param opts test.RequestOptions?
---@return {status: integer, body: string, set_cookie: string?, error: string?}
local function request(t, stack, path, body, opts)
	opts = opts or {}
	---@type {status: integer, body: string, set_cookie: string?, error: string?}
	local response
	local function make_request()
		---@type {[string]: string}
		local headers = {}
		if opts.token then headers.Authorization = "Bearer " .. opts.token end
		if opts.cookie then headers.Cookie = "router_chat=" .. opts.cookie end
		if opts.csrf then headers["X-CSRF-Token"] = opts.csrf end
		local body_str
		if body ~= nil then
			if type(body) == "string" then
				body_str = body
				headers["Content-Type"] = opts.content_type or "application/json"
			else
				body_str = http_util.encode_query_string(body)
				headers["Content-Type"] = "application/x-www-form-urlencoded"
			end
		end
		local _, port = stack.server:getAddress()
		local result, err = http_util.request(
			("http://127.0.0.1:%d%s"):format(assert(port), path),
			body_str,
			{
				method = opts.method or (body ~= nil and "POST" or "GET"),
				headers = headers,
				scheduler = stack.scheduler,
				timeout = 2,
			}
		)
		if not result then
			return nil, err
		end
		local set_cookies = result.headers:getTable("Set-Cookie")
		return {
			status = result.status,
			body = result.body,
			set_cookie = set_cookies and set_cookies[1],
		}
	end
	local thread = coext.detach(coroutine.create(function()
		local ok, result, err = pcall(make_request)
		if ok then response = result else response = {status = -1, body = "", error = tostring(err)} end
	end))
	coroutine.resume(thread)
	pump(t, stack, thread)
	return assert(response)
end

---@param body string
---@return string[] events
local function parseSse(body)
	---@type table[]
	local events = {}
	for data in body:gmatch("data: ([^\n]+)\n") do
		if data ~= "[DONE]" then
			table.insert(events, json.decode(data))
		end
	end
	return events
end

---@param page string
---@return string?
local function pageCsrf(page)
	return page:match('name="csrf_token" value="([^"]+)"')
end

---@param stack test.Stack
local function stop(stack)
	stack.server:stop()
	stack.storage:close()
end

---@param t testing.T
---@param stack test.Stack
---@return string cookie
---@return string csrf
local function signIn(t, stack, key)
	local response = request(t, stack, "/login", {api_key = key})
	t:eq(response.status, 303)
	t:assert(response.set_cookie)
	local cookie = assert(response.set_cookie):match("^router_chat=([^;]+)")
	response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:eq(response.status, 200)
	local csrf = pageCsrf(response.body)
	t:assert(csrf, "chat page embeds the csrf token")
	return cookie, csrf
end

---@param t testing.T
function test.login_page_then_session_and_model_list(t)
	local stack = startStack()
	local response = request(t, stack, "/login")
	t:eq(response.status, 200)
	t:assert(response.body:find("API key", 1, true))
	t:eq(response.body:find(TOKEN, 1, true), nil)

	response = request(t, stack, "/login", {api_key = "wrong-key-wrong"})
	t:eq(response.status, 401)
	t:assert(response.body:find("Invalid API key", 1, true))
	-- Missing key field.
	response = request(t, stack, "/login", {csrf_token = "irrelevant"})
	t:eq(response.status, 401)
	t:assert(response.body:find("Invalid API key", 1, true))
	t:eq(response.set_cookie, nil)
	-- A disabled user cannot sign in.
	stack.users:update(stack.user.id, {disabled = true}, 1001)
	response = request(t, stack, "/login", {api_key = TOKEN})
	t:eq(response.status, 401)
	t:assert(response.body:find("Invalid API key", 1, true))
	stack.users:update(stack.user.id, {disabled = false}, 1002)

	local cookie, csrf = signIn(t, stack, TOKEN)
	response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:eq(response.status, 200)
	t:assert(response.body:find("alice", 1, true))
	t:assert(response.body:find('"userId":' .. stack.user.id, 1, true))
	t:assert(response.body:find('"csrfToken":"' .. csrf .. '"', 1, true))
	local textarea_attributes, textarea_content = response.body:match('<textarea([^>]*id="chat%-input"[^>]*)>(.-)</textarea>')
	t:assert(textarea_attributes)
	t:eq(textarea_content, "")
	t:eq(textarea_attributes:find("disabled", 1, true), nil)
	-- Chat Completions grants are listed, alphabetically.
	t:assert(response.body:find('value="lite"', 1, true))
	t:assert(response.body:find('value="openai-1/gpt-6-luna"', 1, true))
	t:assert(response.body:find('value="zai-1/glm-5.3"', 1, true))
	t:eq(response.body:find(TOKEN, 1, true), nil)
	stop(stack)
end

---@param t testing.T
function test.native_and_ungranted_models_are_excluded_and_rejected(t)
	local native = fakeProvider({message = ok_message})
	local zai = fakeProvider({message = ok_message})
	local stack = startStack({providers = {["zai-1"] = zai}})
	stack.providers_by_name["native-1"] = native
	stack.channels:create("native-1", "openai", {models = {"gpt-6-luna"}}, {}, 1001)
	local grants = stack.users:getGrants(stack.user.id)
	table.insert(grants, "native-1/gpt-6-luna")
	stack.users:setGrants(stack.user.id, grants)
	stack.server:reload(stack.channels:list(), stack.models:list())
	local cookie, csrf = signIn(t, stack, TOKEN)
	local response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:eq(response.body:find('value="native-1/gpt-6-luna"', 1, true), nil)

	-- Native-only model is rejected exactly as on /v1/chat/completions.
	response = request(t, stack, "/chat/completions",
		json.encode({model = "native-1/gpt-6-luna", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = csrf})
	t:eq(response.status, 400)
	t:eq(json.decode(response.body).error.code, "unsupported_protocol")
	t:eq(native.complete_count + native.stream_count, 0)

	-- Ungranted model.
	response = request(t, stack, "/chat/completions",
		json.encode({model = "openai-1/glm-5.3", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = csrf})
	t:eq(response.status, 404)
	t:eq(json.decode(response.body).error.code, "model_not_found")
	t:eq(zai.complete_count + zai.stream_count, 0)
	stop(stack)
end

---@param t testing.T
function test.completions_non_stream_and_stream_record_like_api(t)
	local zai = fakeProvider({message = ok_message, deltas = {{role = "assistant", content = ""}, {content = "hello"}}})
	local stack = startStack({providers = {["zai-1"] = zai}})
	local cookie, csrf = signIn(t, stack, TOKEN)
	local response = request(t, stack, "/chat/completions",
		json.encode({model = "zai-1/glm-5.3", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = csrf})
	t:eq(response.status, 200)
	local completion = json.decode(response.body)
	t:eq(completion.model, "zai-1/glm-5.3")
	t:eq(completion.choices[1].message.content, "hello")
	t:eq(completion.usage.prompt_tokens, 10)

	response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}, stream = true,
			stream_options = {include_usage = true}}),
		{cookie = cookie, csrf = csrf})
	t:eq(response.status, 200)
	local events = parseSse(response.body)
	t:eq(events[1].choices[1].delta.role, "assistant")
	t:eq(events[2].choices[1].delta.content, "hello")
	t:eq(events[2].model, "lite")
	t:assert(response.body:find("data: [DONE]", 1, true))

	local history = stack.usage_repo:history(os.time())
	t:eq(#history.rows, 2)
	---@type {[string]: table}
	local by_model = {}
	for _, row in ipairs(history.rows) do by_model[row.model] = row end
	t:eq(by_model["zai-1/glm-5.3"].user, "alice")
	t:eq(by_model["zai-1/glm-5.3"].channel, "zai-1")
	t:eq(by_model["zai-1/glm-5.3"].input_tokens, 10)
	t:eq(by_model["lite"].channel, "zai-1")
	t:eq(by_model["lite"].upstream_model, "glm-5.3")
	t:eq(by_model["lite"].input_tokens, 10)

	local logs = stack.server.inference.request_logs_repo:list({}, os.time())
	t:eq(#logs, 2)
	-- Newest first.
	t:eq(logs[1].protocol, "chat_completions")
	t:eq(logs[1].stream, true)
	t:eq(logs[1].model, "lite")
	t:eq(logs[1].channel, "zai-1")
	t:eq(logs[1].status, 200)
	t:eq(logs[1].user, "alice")
	t:eq(logs[2].stream, false)
	t:eq(logs[2].model, "zai-1/glm-5.3")
	t:eq(logs[2].user, "alice")
	t:eq(json.encode(logs):find(TOKEN, 1, true), nil)
	stop(stack)
end

---@param t testing.T
function test.browser_usage_option_reaches_upstream_and_request_log(t)
	local stack = startStack()
	local captured
	stack.providers_by_name["zai-1"] = CompatProvider({
		get_time = stack.scheduler.get_time,
		config = {base_url = "http://compat.test/v1", models = {"glm-5.3"}},
		request = function() error("stream only") end,
		open_stream = function()
			local frames, index = {}, 0
			return {
				res = {status = 200},
				sendBody = function(_, body)
					captured = json.decode(body)
					frames = {'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'}
					if captured.stream_options and captured.stream_options.include_usage then
						table.insert(frames, 'data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":80}}}\n\n')
					end
					table.insert(frames, "data: [DONE]\n\n")
					return #body
				end,
				receiveHeaders = function() return true end,
				setTimeout = function() end,
				receiveAvailableChunk = function()
					index = index + 1
					if frames[index] then
						stack.scheduler:sleep(0.002)
						return frames[index]
					end
					return nil, "closed"
				end,
				close = function() return true end,
				cancel = function() return true end,
			}
		end,
	})
	stack.server:reload(stack.channels:list(), stack.models:list())
	local cookie, csrf = signIn(t, stack, TOKEN)
	-- Both API and chat must log reported usage even when clients omit it or opt out of SSE usage frames.
	for _, path in ipairs({"/chat/completions", "/v1/chat/completions"}) do
		for _, options in ipairs({json.null, {include_usage = false}, {include_usage = true}}) do
			local response = request(t, stack, path, json.encode({
				model = "lite", messages = {{role = "user", content = "hi"}}, stream = true,
				stream_options = options ~= json.null and options or nil,
			}), {cookie = cookie, csrf = csrf, token = TOKEN})
			t:eq(response.status, 200)
			t:eq(captured.stream_options.include_usage, true)
			local events = parseSse(response.body)
			local usage_frames = 0
			for _, event in ipairs(events) do
				if event.usage ~= json.null and type(event.usage) == "table" then usage_frames = usage_frames + 1 end
			end
			t:eq(usage_frames, options ~= json.null and options.include_usage and 1 or 0)
			local row = stack.server.inference.request_logs_repo:list({}, os.time())[1]
			t:eq(row.input_tokens, 120)
			t:eq(row.output_tokens, 30)
			t:eq(row.cached_input_tokens, 80)
			t:eq(row.estimated, false)
			t:assert(row.ttft_ms ~= nil)
			t:assert(row.generation_ms > 0)
		end
	end
	stop(stack)
end

---@param t testing.T
function test.session_and_csrf_boundaries(t)
	local stack = startStack()
	-- No session.
	local response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}}))
	t:eq(response.status, 401)
	t:eq(json.decode(response.body).error.code, "invalid_session")
	-- Garbage session.
	response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}}),
		{cookie = "garbage.garbage"})
	t:eq(response.status, 401)
	-- Wrong CSRF token.
	local cookie, csrf = signIn(t, stack, TOKEN)
	response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = "0000000000000000000000000000000000000000000000000000000000000000"})
	t:eq(response.status, 403)
	t:eq(json.decode(response.body).error.code, "csrf_mismatch")
	-- Method boundaries.
	response = request(t, stack, "/chat/completions", nil, {cookie = cookie, method = "GET"})
	t:eq(response.status, 405)
	response = request(t, stack, "/chat", nil, {cookie = cookie, method = "POST"})
	t:eq(response.status, 405)
	response = request(t, stack, "/login", nil, {method = "DELETE"})
	t:eq(response.status, 405)
	response = request(t, stack, "/chat/nope")
	t:eq(response.status, 404)
	stop(stack)
end

---@param t testing.T
function test.disable_delete_and_key_rotation_revoke_sessions(t)
	local stack = startStack()
	local cookie = request(t, stack, "/login", {api_key = TOKEN}).set_cookie:match("^router_chat=([^;]+)")
	t:assert(cookie)

	stack.users:update(stack.user.id, {disabled = true}, 1001)
	local response = request(t, stack, "/login", nil, {cookie = cookie})
	t:eq(response.status, 200)
	t:assert(response.body:find("no longer valid", 1, true))
	t:assert(response.set_cookie ~= nil)
	t:assert(response.set_cookie:find("Max-Age=0", 1, true))
	response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = "ignored"})
	t:eq(response.status, 401)

	-- Re-enabling restores the session; it is bound to the user row, not a password.
	stack.users:update(stack.user.id, {disabled = false}, 1002)
	response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:eq(response.status, 200)
	t:assert(response.body:find("alice", 1, true))

	-- Key rotation invalidates the existing session but a fresh login works.
	stack.users:regenerateKey(stack.user.id, 1003)
	response = request(t, stack, "/login", nil, {cookie = cookie})
	t:eq(response.status, 200)
	t:eq(response.body:find('id="chat-messages"', 1, true), nil)
	t:assert(response.body:find("API key", 1, true))
	stop(stack)
end

---@param t testing.T
function test.full_key_rotation_revokes_sessions_even_when_hints_match(t)
	local stack = startStack()
	local cookie, csrf = signIn(t, stack, TOKEN)
	local old_user = stack.users:get(stack.user.id)
	local new_key = "replacement-key-" .. old_user.key_hint
	-- Simulate a rotation whose last four characters collide with the old key.
	stack.users.models.router_users:update({
		key_hash = digest.hash("sha256", new_key, true), key_hint = old_user.key_hint,
	}, {id = stack.user.id})
	local response = request(t, stack, "/chat/completions",
		json.encode({model = "lite", messages = {{role = "user", content = "hi"}}}),
		{cookie = cookie, csrf = csrf})
	t:eq(response.status, 401)
	response = request(t, stack, "/login", nil, {cookie = cookie})
	t:assert(response.body:find("no longer valid", 1, true))
	local fresh_cookie = signIn(t, stack, new_key)
	local session = stack.chat.sessions:decode(fresh_cookie)
	t:assert(session.key_fingerprint)
	t:eq(session.key_hint, nil)
	t:eq(session.key_hash, nil)
	t:eq(session.key_fingerprint == stack.users:get(stack.user.id).key_hash, false)
	-- Legacy hint-only sessions must not remain valid after the upgrade.
	local legacy_cookie = stack.chat.sessions:encode({user_id = stack.user.id, key_hint = old_user.key_hint})
	response = request(t, stack, "/login", nil, {cookie = legacy_cookie})
	t:assert(response.body:find("no longer valid", 1, true))
	stack.users:delete(stack.user.id)
	response = request(t, stack, "/login", nil, {cookie = fresh_cookie})
	t:assert(response.body:find("no longer valid", 1, true))
	stop(stack)
end

---@param t testing.T
function test.chat_and_api_share_per_user_limits(t)
	local stack = startStack({providers = {["zai-1"] = fakeProvider({message = ok_message})}})
	stack.users:update(stack.user.id, {max_rpm = 1}, 1001)
	local cookie, csrf = signIn(t, stack, TOKEN)
	local body = json.encode({model = "zai-1/glm-5.3", messages = {{role = "user", content = "hi"}}})
	t:eq(request(t, stack, "/v1/chat/completions", body, {token = TOKEN}).status, 200)
	local response = request(t, stack, "/chat/completions", body, {cookie = cookie, csrf = csrf})
	t:eq(response.status, 429)
	t:eq(json.decode(response.body).error.code, "rate_limit_exceeded")
	stop(stack)
end

---@param t testing.T
function test.logout_with_csrf_clears_cookie(t)
	local stack = startStack()
	local cookie, csrf = signIn(t, stack, TOKEN)
	-- Invalid CSRF keeps the session.
	local response = request(t, stack, "/logout", {csrf_token = "bad"}, {cookie = cookie})
	t:eq(response.status, 403)
	response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:assert(response.body:find("alice", 1, true))
	-- Valid CSRF clears it.
	response = request(t, stack, "/logout", {csrf_token = csrf}, {cookie = cookie})
	t:eq(response.status, 303)
	t:assert(response.set_cookie:find("Max-Age=0", 1, true))
	-- A browser that honored the cleared cookie is back on the login page.
	response = request(t, stack, "/login")
	t:eq(response.status, 200)
	t:eq(response.body:find('id="chat-messages"', 1, true), nil)
	t:assert(response.body:find("API key", 1, true))
	stop(stack)
end

---@param t testing.T
function test.user_without_chat_models_gets_a_notice(t)
	local zai = fakeProvider({message = ok_message})
	local native = fakeProvider({message = ok_message})
	local stack = startStack({providers = {["zai-1"] = zai}})
	stack.providers_by_name["native-1"] = native
	stack.channels:create("native-1", "openai", {models = {"gpt-6-luna"}}, {}, 1001)
	local bob, bob_key = stack.users:create("bob", 1002)
	stack.users:setGrants(bob.id, {"native-1/gpt-6-luna"})
	stack.server:reload(stack.channels:list(), stack.models:list())
	local response = request(t, stack, "/login", {api_key = bob_key})
	t:eq(response.status, 303)
	local cookie = assert(response.set_cookie):match("^router_chat=([^;]+)")
	response = request(t, stack, "/chat", nil, {cookie = cookie})
	t:eq(response.status, 200)
	t:assert(response.body:find("No Chat Completions models are available", 1, true))
	t:assert(response.body:find("disabled", 1, true))
	local textarea_attributes, textarea_content = response.body:match('<textarea([^>]*id="chat%-input"[^>]*)>(.-)</textarea>')
	t:assert(textarea_attributes:find("disabled", 1, true))
	t:eq(textarea_content, "")
	t:eq(native.complete_count + native.stream_count, 0)
	stop(stack)
end

---@param t testing.T
function test.login_is_separate_from_chat_and_old_auth_urls_are_removed(t)
	local stack = startStack()
	t:eq(request(t, stack, "/chat").status, 303)
	local cookie = signIn(t, stack, TOKEN)
	t:eq(request(t, stack, "/login", nil, {cookie = cookie}).status, 303)
	for _, path in ipairs({"/chat/login", "/chat/logout"}) do
		t:eq(request(t, stack, path, nil, {cookie = cookie}).status, 404)
		t:eq(request(t, stack, path, {ignored = "1"}, {cookie = cookie}).status, 404)
	end
	stop(stack)
end

---@param t testing.T
function test.chat_settings_and_model_metadata_are_safe_and_grant_scoped(t)
	local stack = startStack()
	local cookie = signIn(t, stack, TOKEN)
	local response = request(t, stack, "/chat", nil, {cookie = cookie})
	for _, id in ipairs({"chat-reset", "chat-system", "chat-reasoning", "chat-tools", "chat-status"}) do
		t:assert(response.body:find('id="' .. id .. '"', 1, true), id)
	end
	local config = json.decode(assert(response.body:match("window%.routerChat = ([^\n]+);")))
	t:eq(config.modelInfo.lite.kind, "zai")
	t:eq(config.modelInfo.lite.channel, "zai-1")
	t:eq(config.modelInfo.lite.upstreamModel, "glm-5.3")
	t:eq(config.modelInfo["openai-1/gpt-6-luna"].kind, "openai_compat")
	t:eq(config.modelInfo["openai-1/glm-5.3"], nil)
	t:eq(response.body:find("https://api.z.ai", 1, true), nil)
	t:eq(response.body:find(TOKEN, 1, true), nil)
	t:eq(response.body:find(PASSWORD, 1, true), nil)
	stop(stack)
end

---@param t testing.T
function test.chat_tool_rounds_use_normal_inference_and_report_usage_individually(t)
	local provider = fakeProvider()
	function provider:completeStream(body, upstream_model, on_delta)
		self.stream_count = self.stream_count + 1
		t:eq(upstream_model, "glm-5.3")
		t:eq(body.messages[1].role, "system")
		t:eq(body.messages[1].content, "PRIVATE-SYSTEM-PROMPT")
		t:eq(body.thinking.type, "enabled")
		t:eq(body.tools[1]["function"].name, "browser_javascript")
		if self.stream_count == 1 then
			t:eq(#body.messages, 2)
			local call = {id = "call-js", type = "function", ["function"] = {name = "browser_javascript", arguments = '{"code":"return 1+1"}'}}
			on_delta({tool_calls = {{index = 0, id = call.id, type = call.type, ["function"] = call["function"]}}})
			return {content = "", tool_calls = {call}, finish_reason = "tool_calls", usage = ok_message.usage}
		end
		t:eq(#body.messages, 4)
		t:eq(body.messages[3].tool_calls[1].id, "call-js")
		t:eq(body.messages[4].role, "tool")
		t:eq(body.messages[4].tool_call_id, "call-js")
		t:eq(json.decode(body.messages[4].content).output, "2")
		on_delta({content = "2"})
		return {content = "2", finish_reason = "stop", usage = ok_message.usage}
	end
	local stack = startStack({providers = {["zai-1"] = provider}})
	local cookie, csrf = signIn(t, stack, TOKEN)
	local body = {model = "lite", messages = {{role = "system", content = "PRIVATE-SYSTEM-PROMPT"}, {role = "user", content = "PRIVATE-PROMPT"}},
		stream = true, stream_options = {include_usage = true}, thinking = {type = "enabled"},
		tools = {{type = "function", ["function"] = {name = "browser_javascript",
			parameters = {type = "object", properties = {code = {type = "string"}}, required = {"code"}}}}},
	}
	local response = request(t, stack, "/chat/completions", json.encode(body), {cookie = cookie, csrf = csrf})
	t:eq(response.status, 200)
	t:assert(response.body:find('"finish_reason":"tool_calls"', 1, true))
	t:assert(response.body:find('"prompt_tokens":10', 1, true))
	table.insert(body.messages, {role = "assistant", content = "", tool_calls = {{id = "call-js", type = "function", ["function"] = {name = "browser_javascript", arguments = '{"code":"return 1+1"}'}}}})
	table.insert(body.messages, {role = "tool", tool_call_id = "call-js", content = '{"ok":true,"output":"2"}'})
	response = request(t, stack, "/chat/completions", json.encode(body), {cookie = cookie, csrf = csrf})
	t:eq(response.status, 200)
	t:eq(provider.stream_count, 2)
	local rows = stack.server.inference.request_logs_repo:list({}, os.time())
	t:eq(#rows, 2)
	for _, row in ipairs(rows) do
		t:eq(row.user_id, stack.user.id)
		t:eq(row.input_tokens, 10)
		t:eq(row.output_tokens, 5)
		t:eq(row.estimated, false)
	end
	t:eq(json.encode(rows):find("PRIVATE-", 1, true), nil)
	local usage = stack.usage_repo:history(os.time())
	t:eq(usage.rows[1].requests, 2)
	t:eq(json.encode(usage):find("PRIVATE-", 1, true), nil)
	stop(stack)
end

return test
