local json = require("web.json")
local Headers = require("web.http.Headers")
local InferenceService = require("ai.router.InferenceService")

local test = {}

-- Exercise the service without a listener, SQLite or browser. HTTP integration
-- and real transport cancellation remain covered by Server_test/ChatPages_test.
local function fixture()
	local state = {now = 100, calls = 0, aggregates = {}, rows = {}, details = {}, logs = {}}
	local service
	service = InferenceService({
		users_repo = {models = {}, getGrants = function() return {"local/mock"} end},
		usage_repo = {record = function(_, now, user, status, model, upstream_model, channel, counters)
			assert(next(service.active_requests) == nil, "slot must be released before persistence")
			table.insert(state.aggregates, {status = status, model = model, channel = channel, counters = counters})
			if state.fail_aggregate then error("PRIVATE-AGGREGATE") end
		end},
		monitor = {setChannels = function() end},
		provider_factory = function()
			local message = {content = "PRIVATE-REPLY", usage = {input_tokens = 120,
				output_tokens = 30, cached_input_tokens = 80}}
			return {
				complete = function()
					state.calls = state.calls + 1
					if state.fail_provider then error("PRIVATE-PROVIDER") end
					return message
				end,
				completeStream = function(_, _, _, on_delta)
					state.calls = state.calls + 1
					state.now = 101
					if on_delta({content = "PRIVATE-REPLY"}) == false then return nil, "closed" end
					state.now = 103
					return message
				end,
			}
		end,
		get_time = function() return state.now end,
		logger = function(line) table.insert(state.logs, line) end,
	})
	service.request_logs_repo = {record = function(_, row)
		assert(next(service.active_requests) == nil, "slot must be released before persistence")
		table.insert(state.rows, row)
		if state.fail_log then error("PRIVATE-LOG") end
		return {id = #state.rows}
	end, rotateDetails = function() end, recordDetails = function(_, id, owner, details)
		assert(next(service.active_requests) == nil, "slot must be released before payload persistence")
		state.details[#state.details + 1] = {id = id, owner = owner, data = details}
		if state.fail_detail then error("PRIVATE-PAYLOAD-WRITE") end
	end}
	service:reload({{id = 1, name = "local", kind = "openai_compat", enabled = true,
		config = {base_url = "http://unused.test/v1", models = {"mock"}}, limits = {}}}, {})
	local finalize = service.finalize
	service.finalize = function(self, user, context)
		state.context = context
		finalize(self, user, context)
	end
	return service, state, {id = 7, name = "alice", disabled = false}
end

local function request(stream)
	local body = json.encode({model = "local/mock", messages = {{role = "user", content = "PRIVATE-PROMPT"}}, stream = stream})
	local req = {headers = Headers(), receive = function() return body end}
	req.headers:set("Content-Length", #body)
	local res = {headers = Headers(), chunks = {}}
	function res:set_length() end
	function res:set_chunked_encoding() end
	function res:send_headers() self.headers_sent = true return 1 end
	function res:send(data)
		self.headers_sent = true
		table.insert(self.chunks, data)
		return #data
	end
	return req, res
end

---@param t testing.T
function test.finalization_records_once_and_reuses_reported_counters(t)
	local service, state, user = fixture()
	local req, res = request(true)
	t:eq(service:process(req, res, user, "chat_completions"), 200)
	t:eq(state.calls, 1)
	t:eq(next(service.active_requests), nil)
	t:eq(#state.aggregates, 1)
	t:eq(#state.rows, 1)
	t:eq(state.aggregates[1].counters.input_tokens, 120)
	t:eq(state.aggregates[1].counters.cached_input_tokens, 80)
	t:eq(state.rows[1].input_tokens, 120)
	t:eq(state.rows[1].output_tokens, 30)
	t:eq(state.rows[1].cached_input_tokens, 80)
	t:eq(state.rows[1].estimated, false)
	t:eq(state.rows[1].ttft_ms, 1000)
	t:eq(state.rows[1].generation_ms, 2000)
	t:eq(json.encode(state.rows):find("PRIVATE", 1, true), nil)
	service:finalize(user, state.context)
	t:eq(#state.aggregates, 1)
	t:eq(#state.rows, 1)
	t:eq(next(service.active_requests), nil)
end

---@param t testing.T
function test.persistence_errors_are_independent_and_do_not_leak_details(t)
	for _, fail in ipairs({"fail_aggregate", "fail_log", "both"}) do
		local service, state, user = fixture()
		state.fail_aggregate = fail == "fail_aggregate" or fail == "both"
		state.fail_log = fail == "fail_log" or fail == "both"
		local req, res = request(false)
		t:eq(service:process(req, res, user, "chat_completions"), 200)
		t:eq(#state.aggregates, 1)
		t:eq(#state.rows, 1)
		t:eq(next(service.active_requests), nil)
		t:eq(#state.logs, fail == "both" and 2 or 1)
		t:eq(state.logs[1], state.fail_aggregate and "usage write failed" or "request log write failed")
		if fail == "both" then t:eq(state.logs[2], "request log write failed") end
		service:finalize(user, state.context)
		t:eq(#state.aggregates, 1)
		t:eq(#state.rows, 1)
	end
end

---@param t testing.T
function test.read_and_response_exceptions_always_finalize(t)
	for _, fail in ipairs({"read", "write"}) do
		local service, state, user = fixture()
		local req, res = request(false)
		if fail == "read" then
			req.receive = function() error("PRIVATE-READ") end
		else
			res.send = function() error("PRIVATE-WRITE") end
		end
		t:eq(service:process(req, res, user, "chat_completions"), 500)
		t:eq(next(service.active_requests), nil)
		t:eq(#state.rows, 1)
		t:eq(state.rows[1].error_code, "internal_error")
		t:eq(json.encode(res.chunks):find("PRIVATE", 1, true), nil)
		t:eq(#state.aggregates, fail == "read" and 0 or 1)
		t:eq(state.details[1].data.request_state, fail == "read" and "partial" or "complete")
	end
end

---@param t testing.T
function test.rate_and_concurrency_rejections_do_not_release_another_requests_slot(t)
	for _, limit in ipairs({"rate", "concurrency"}) do
		local service, state, user = fixture()
		if limit == "rate" then
			user.max_rpm = 1
			t:assert(service:consumeRateLimit(tostring(user.id)))
		else
			user.max_concurrency = 1
		end
		t:assert(service:acquireRequest(tostring(user.id), 1))
		-- The existing request owns this slot. Rejected requests may log, but
		-- must not release it or add an aggregate row.
		service.request_logs_repo = {record = function(_, row) table.insert(state.rows, row) end}
		local req, res = request(false)
		t:eq(service:process(req, res, user, "chat_completions"), 429)
		t:eq(service.active_requests[tostring(user.id)], 1)
		t:eq(#state.aggregates, 0)
		t:eq(#state.rows, 1)
		t:eq(state.rows[1].error_code, limit == "rate" and "rate_limit" or "concurrency_limit")
		t:eq(state.calls, 0)
		service:finalize(user, state.context)
		t:eq(service.active_requests[tostring(user.id)], 1)
		service:releaseRequest(tostring(user.id))
	end
end

---@param t testing.T
function test.malformed_json_and_provider_errors_keep_existing_outcomes(t)
	for _, fail in ipairs({"json", "provider"}) do
		local service, state, user = fixture()
		local req, res = request(false)
		if fail == "json" then req.receive = function() return "{" end
		else state.fail_provider = true end
		t:eq(service:process(req, res, user, "chat_completions"), fail == "json" and 400 or 502)
		t:eq(next(service.active_requests), nil)
		t:eq(#state.rows, 1)
		t:eq(state.rows[1].error_code, fail == "json" and "invalid_request" or "upstream_error")
		t:eq(table.concat(res.chunks):find("PRIVATE", 1, true), nil)
	end
end

function test.full_client_payloads_are_independent_of_metadata_and_write_failures(t)
	for _, stream in ipairs({false, true}) do
		local service, state, user = fixture()
		local req, res = request(stream)
		req.uri = "/chat/completions?ignored=PRIVATE-QUERY"
		req.headers:set("Authorization", "Bearer PRIVATE-KEY")
		req.headers:set("Cookie", "PRIVATE-COOKIE")
		local raw = req:receive()
		t:eq(service:process(req, res, user, "chat_completions"), 200)
		t:eq(#state.details, 1)
		local saved = state.details[1]
		t:eq(saved.owner, user.id)
		t:eq(saved.data.request_body, raw)
		t:eq(saved.data.response_body, table.concat(res.chunks))
		t:eq(saved.data.response_complete, true)
		t:eq(saved.data.request_path, "/chat/completions")
		t:eq(saved.data.request_state, "complete")
		t:eq(json.encode(saved):find("PRIVATE-KEY", 1, true), nil)
		t:eq(json.encode(saved):find("PRIVATE-COOKIE", 1, true), nil)
		t:eq(json.encode(saved):find("PRIVATE-QUERY", 1, true), nil)
		service:finalize(user, state.context)
		t:eq(#state.details, 1)
	end
	local service, state, user = fixture()
	state.fail_detail = true
	local req, res = request(false)
	t:eq(service:process(req, res, user, "chat_completions"), 200)
	t:eq(#state.aggregates, 1)
	t:eq(#state.rows, 1)
	t:tdeq(state.logs, {"request detail write failed"})
	t:eq(next(service.active_requests), nil)
end

function test.invalid_and_unread_bodies_keep_honest_capture_states(t)
	local service, state, user = fixture()
	local req, res = request(false)
	req.receive = function() return "{bad-json" end
	t:eq(service:process(req, res, user, "chat_completions"), 400)
	t:eq(state.details[1].data.request_body, "{bad-json")
	t:eq(state.details[1].data.response_body, table.concat(res.chunks))
	t:eq(state.details[1].data.request_state, "complete")
	req, res = request(false)
	req.headers:set("Content-Length", service.max_body_size + 1)
	req.receive = function() error("must not read rejected body") end
	t:eq(service:process(req, res, user, "chat_completions"), 413)
	t:eq(state.details[2].data.request_state, "not_read")
	t:eq(state.details[2].data.request_body, "")
end

return test
