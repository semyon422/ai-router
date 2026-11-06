local class = require("class")
local json = require("web.json")
local random = require("web.random")
local Catalog = require("ai.router.Catalog")
local Router = require("ai.router.Router")
local ChatProtocol = require("ai.openai.ChatCompletionsProtocol")
local ResponsesProtocol = require("ai.openai.ResponsesProtocol")
local RequestLogsRepo = require("ai.router.RequestLogsRepo")
local RequestMetrics = require("ai.router.RequestMetrics")
local RequestCapture = require("ai.router.RequestCapture")
local ResponseWriter = require("ai.router.ResponseWriter")
local sendError = ResponseWriter.sendError
local sendJson = ResponseWriter.sendJson
local sendEvent = ResponseWriter.sendEvent
local startEventStream = ResponseWriter.startEventStream
local sendResponseEvent = ResponseWriter.sendResponseEvent

-- Shared inference execution for authenticated API and browser requests.
-- Owns catalog/provider state, per-user limits, streaming and final accounting;
-- it does not own a listener, HTTP routes, authentication or session cookies.
---@class ai.router.InferenceService
---@operator call: ai.router.InferenceService
---@field users_repo ai.router.UsersRepo
---@field usage_repo ai.router.UsageRepo
---@field request_logs_repo ai.router.RequestLogsRepo
---@field monitor ai.router.UsageMonitor
---@field router ai.router.Router
---@field providers {[integer]: ai.router.ProviderMethods}
---@field provider_factory fun(channel: ai.router.ChannelRow): ai.router.ProviderMethods?
---@field catalog_errors string[]
---@field logger fun(line: string)
---@field get_time fun(): number
---@field max_body_size integer
---@field max_concurrent_requests_per_user integer
---@field max_requests_per_minute integer
---@field active_requests {[string]: integer}
---@field request_windows {[string]: {started_at: number, count: integer}}
local InferenceService = class()

InferenceService.max_body_size = 16 * 1024 * 1024
InferenceService.max_concurrent_requests_per_user = 4
InferenceService.max_requests_per_minute = 120

-- The provider methods inference and explicit channel probes call; implemented
-- by OpenAIProvider, ZaiProvider, and CompatProvider.
---@class ai.router.ProviderMethods
---@field complete (fun(self: ai.router.ProviderMethods, body: table, upstream_model: string): openai.CanonicalMessage?, string?, table?)?
---@field completeStream (fun(self: ai.router.ProviderMethods, body: table, upstream_model: string, on_delta: fun(delta: table): boolean?): openai.CanonicalMessage?, string?, table?)?
---@field createResponse (fun(self: ai.router.ProviderMethods, body: table, upstream_model: string, session_id: string?, on_event: (fun(event: table): boolean?)?): table?, string?, table?)?
---@field fetchUsage (fun(self: ai.router.ProviderMethods): table?, string?, ai.router.UsageFetchError?)?

---@class ai.router.InferenceServiceOptions
---@field users_repo ai.router.UsersRepo
---@field usage_repo ai.router.UsageRepo
---@field monitor ai.router.UsageMonitor
---@field provider_factory fun(channel: ai.router.ChannelRow): ai.router.ProviderMethods?
---@field logger (fun(line: string))?
---@field get_time fun(): number
---@field max_body_size integer?
---@field max_concurrent_requests_per_user integer?
---@field max_requests_per_minute integer?

---@param options ai.router.InferenceServiceOptions
function InferenceService:new(options)
	assert(options.provider_factory, "provider_factory is required")
	self.users_repo = options.users_repo
	self.request_logs_repo = RequestLogsRepo(options.users_repo.models)
	self.usage_repo = options.usage_repo
	self.monitor = options.monitor
	self.provider_factory = options.provider_factory
	self.logger = options.logger or print
	assert(type(options.get_time) == "function", "get_time is required")
	self.get_time = options.get_time
	self.max_body_size = options.max_body_size or self.max_body_size
	self.max_concurrent_requests_per_user = options.max_concurrent_requests_per_user
		or self.max_concurrent_requests_per_user
	self.max_requests_per_minute = options.max_requests_per_minute or self.max_requests_per_minute
	assert(self.max_body_size >= 1, "max_body_size must be positive")
	assert(self.max_concurrent_requests_per_user >= 1, "max_concurrent_requests_per_user must be positive")
	assert(self.max_requests_per_minute >= 1, "max_requests_per_minute must be positive")
	self.active_requests = {}
	self.request_windows = {}
	self.providers = {}
	self.catalog_errors = {}
	self.router = Router({state = Catalog.fromRows({}, {})})
end

-- Rebuilds routing state, providers, and monitor wiring from repository
-- rows. Called at startup and after catalog mutations or an explicit retry.
---@param channel_rows ai.router.ChannelRow[]
---@param model_rows ai.router.ModelRow[]
function InferenceService:reload(channel_rows, model_rows)
	local state, errors = Catalog.fromRows(channel_rows, model_rows)
	self.catalog_errors = errors
	assert(#errors == 0, "invalid router catalog:\n" .. table.concat(errors, "\n"))
	local router = Router({state = state})
	---@type {[integer]: ai.router.ProviderMethods}
	local providers = {}
	---@type {[integer]: fun(): table?, string?, table?}
	local fetchers = {}
	for _, row in ipairs(channel_rows) do
		local provider = self.provider_factory(row)
		if provider then
			providers[row.id] = provider
			if provider.fetchUsage then
				fetchers[row.id] = function()
					return provider:fetchUsage()
				end
			end
		end
	end
	self.monitor:setChannels(state.channels, fetchers)
	self.router = router
	self.providers = providers
end

-- Estimates token counts when the provider did not report usage.
---@param value any
---@return integer
local function estimate(value)
	if value == nil then return 0 end
	return math.ceil(#json.encode(value) / 4)
end

---@param user_key string
---@param limit integer?
---@return boolean
function InferenceService:consumeRateLimit(user_key, limit)
	local now = self.get_time()
	local window = self.request_windows[user_key]
	if not window or now - window.started_at >= 60 then
		self.request_windows[user_key] = {started_at = now, count = 1}
		return true
	elseif window.count >= (limit or self.max_requests_per_minute) then
		return false
	end
	window.count = window.count + 1
	return true
end

---@param user_key string
---@param limit integer?
---@return boolean
function InferenceService:acquireRequest(user_key, limit)
	local active = self.active_requests[user_key] or 0
	if active >= (limit or self.max_concurrent_requests_per_user) then return false end
	self.active_requests[user_key] = active + 1
	return true
end

---@param user_key string
function InferenceService:releaseRequest(user_key)
	local active = assert(self.active_requests[user_key]) - 1
	self.active_requests[user_key] = active > 0 and active or nil
end

-- One request to the explicitly selected channel. Never retries.
---@class ai.router.AttemptResult
---@field message openai.CanonicalMessage?
---@field response table? Native Responses result; never converted to a canonical assistant message.
---@field provider_error table?
---@field refresh_usage boolean?
---@field downstream_closed boolean?
---@field channel string?
---@field upstream_model string?
---@field status_code integer Logical request outcome, including failures after HTTP 200 commit.

---@param self ai.router.InferenceService
---@param res web.Response
---@param request {[string]: any}
---@param public_model string
---@param candidate ai.router.Candidate
---@param completion_id string
---@param created integer
---@param include_usage boolean
---@param metrics ai.router.RequestMetrics
---@return ai.router.AttemptResult
local function attempt(self, res, request, public_model, candidate, completion_id, created, include_usage, metrics)
	local provider = self.providers[candidate.channel.id]
	if not provider then
		return {status_code = 503}
	end
	local stream = request.stream == true
	local body = request
	if body.model ~= candidate.model then
		---@type {[string]: any}
		local copy = {}
		---@cast body {[string]: any}
		for key, value in pairs(body) do
			copy[key] = value
		end
		copy.model = candidate.model
		body = copy
	end
	local upstream_model = candidate.upstream_model

	if not stream then
		local ok, message, err, provider_error = pcall(provider.complete, provider, body, upstream_model)
		if not ok then message, err = nil, "upstream request failed" end
		if not message then
			metrics:providerError(err, provider_error)
			local status = provider_error and provider_error.status
			return {
				status_code = status or 502,
				provider_error = provider_error or {message = err, type = "upstream_error", code = "upstream_error"},
				refresh_usage = status == 429 or provider_error and provider_error.type == "rate_limit_error",
			}
		end
		local completion = ChatProtocol.completion(completion_id, created, public_model, message)
		local sent = sendJson(res, completion)
		return {message = message, downstream_closed = not sent, status_code = sent and 200 or 499}
	end

	-- Streaming: commit downstream only when the first output delta arrives.
	local committed = false
	local downstream_closed = false
	local function commit()
		if committed then return true end
		if not startEventStream(res)
			or not sendEvent(res, ChatProtocol.chunk(completion_id, created, public_model,
				{role = "assistant"}, nil, include_usage))
		then
			return false
		end
		committed = true
		return true
	end
	local ok, message, err, provider_error = pcall(provider.completeStream, provider, body, upstream_model, function(delta)
		if downstream_closed then return false end
		if ChatProtocol.hasOutput(delta) then metrics:markOutput() end
		-- Role announcements and empty deltas are not assistant output.
		if not committed then
			local has_output = false
			for key, value in pairs(delta) do
				if key ~= "role" and value ~= json.null and value ~= ""
					and (type(value) ~= "table" or next(value)) then has_output = true break end
			end
			if not has_output then return true end
		end
		if not commit() then
			downstream_closed = true
			return false
		end
		local sent = sendEvent(res, ChatProtocol.chunk(completion_id, created, public_model, delta, nil, include_usage))
		if not sent then
			downstream_closed = true
			return false
		end
		return true
	end)
	metrics:finishGeneration()
	if not ok then message, err = nil, "upstream request failed" end
	if not message then
		metrics:providerError(err, provider_error)
		if downstream_closed then
			return {status_code = 499, downstream_closed = true}
		end
		if committed or res.headers_sent then
			local error_body = provider_error or {
				message = "upstream request failed",
				type = "upstream_error",
				code = "upstream_error",
			}
			---@cast error_body {[string]: any}
			local sent = sendEvent(res, {error = {
				message = error_body.message,
				type = error_body.type,
				code = error_body.code,
				request_id = error_body.request_id,
			}})
			if sent then sent = sendEvent(res, "[DONE]") end
			if sent then sent = res:send("") ~= nil end
			return {status_code = sent and 502 or 499, downstream_closed = not sent, provider_error = error_body,
				refresh_usage = error_body.status == 429 or error_body.type == "rate_limit_error"}
		end
		local status = provider_error and provider_error.status
		return {
			status_code = status or 502,
			provider_error = provider_error or {message = err, type = "upstream_error", code = "upstream_error"},
			refresh_usage = status == 429 or provider_error and provider_error.type == "rate_limit_error",
		}
	end
	if downstream_closed or not commit() then
		return {status_code = 499, message = message, downstream_closed = true}
	end
	local sent = sendEvent(res, ChatProtocol.chunk(completion_id, created, public_model, json.object(), ChatProtocol.finishReason(message), include_usage))
	if sent and include_usage then
		local usage = ChatProtocol.completionUsage(message.usage)
		if usage then
			sent = sendEvent(res, ChatProtocol.usageChunk(completion_id, created, public_model, usage))
		end
	end
	if sent then sent = sendEvent(res, "[DONE]") end
	if sent then sent = res:send("") ~= nil end
	return {message = message, downstream_closed = not sent, status_code = sent and 200 or 499}
end

---@param response {[string]: any}
---@param model string
---@return table
local function publicResponse(response, model)
	---@type {[string]: any}
	local copy = {}
	for key, value in pairs(response) do copy[key] = value end
	copy.model = model
	return copy
end

-- Native SSE preserves every typed event, including response.created.
---@param self ai.router.InferenceService
---@param res web.Response
---@param request {[string]: any}
---@param public_model string
---@param candidate ai.router.Candidate
---@param session_id string?
---@param metrics ai.router.RequestMetrics
---@return ai.router.AttemptResult
local function attemptResponse(self, res, request, public_model, candidate, session_id, metrics)
	local provider = self.providers[candidate.channel.id]
	if not provider then return {status_code = 503} end
	local committed, downstream_closed = false, false
	local sequence_number = -1
	---@type (fun(event: table): boolean?)?
	local callback
	if request.stream == true then
		---@param event {[string]: any}
		---@return boolean
		function callback(event)
			if downstream_closed then return false end
			if RequestMetrics.responseOutput(event) then metrics:markOutput() end
			sequence_number = type(event.sequence_number) == "number" and event.sequence_number or sequence_number + 1
			committed = true
			if not startEventStream(res) then downstream_closed = true return false end
			if type(event.response) == "table" then
				---@type {[string]: any}
				local copy = {}
				for key, value in pairs(event) do copy[key] = value end
				copy.response = publicResponse(event.response, public_model)
				event = copy
			end
			if not sendResponseEvent(res, event) then downstream_closed = true return false end
			return true
		end
	end
	local ok, response, err, provider_error = pcall(provider.createResponse, provider,
		request, candidate.upstream_model, session_id, callback)
	metrics:finishGeneration()
	if not ok then response, err = nil, "upstream request failed" end
	if downstream_closed then return {status_code = 499, downstream_closed = true} end
	if not response then
		metrics:providerError(err, provider_error)
		local error_body = provider_error or {message = "upstream request failed", type = "upstream_error", code = "upstream_error"}
		local status = error_body.status
		---@type ai.router.AttemptResult
		local result = {
			status_code = status or 502, provider_error = error_body,
			refresh_usage = status == 429 or error_body.type == "rate_limit_error",
		}
		if committed or res.headers_sent then
			local sent = sendResponseEvent(res, {type = "error", code = error_body.code,
				message = error_body.message, param = json.null, sequence_number = sequence_number + 1})
			if sent then sent = res:send("") ~= nil end
			result.status_code = sent and 502 or 499
			result.downstream_closed = not sent
		end
		return result
	end
	local sent
	if request.stream == true then
		sent = startEventStream(res) and res:send("") ~= nil
	else
		sent = sendJson(res, publicResponse(response, public_model))
	end
	local response_error = response.error
	if response.status == "failed" then
		metrics:providerError(nil, type(response_error) == "table" and response_error or nil)
	end
	return {response = response, downstream_closed = not sent,
		refresh_usage = type(response_error) == "table"
			and (response_error.code == "rate_limit_exceeded" or response_error.type == "rate_limit_error"),
		status_code = not sent and 499 or response.status == "failed" and 502 or 200}
end

-- Resolves one channel and checks its native protocol, without retrying.
---@param res web.Response
---@param request {[string]: any}
---@param user ai.router.UserRow
---@param protocol "responses"|"chat_completions"?
---@param session_id string?
---@param metrics ai.router.RequestMetrics?
---@return integer status
---@return ai.router.AttemptResult? result
function InferenceService:complete(res, request, user, protocol, session_id, metrics)
	metrics = metrics or RequestMetrics(self.get_time)
	local public_model = request.model
	---@type {[string]: boolean}
	local grants = {}
	for _, model in ipairs(self.users_repo:getGrants(user.id)) do
		grants[model] = true
	end
	if type(public_model) ~= "string" or not grants[public_model]
		or not self.router.state.public_models[public_model] then
		sendError(res, 404, "model is not available", "invalid_request_error", "model_not_found", metrics)
		return 404
	end
	local candidate = self.router:resolve(public_model)
	if not candidate then
		sendError(res, 503, "no upstream is available for this model", "upstream_error", "upstream_unavailable", metrics)
		return 503
	end
	local native = protocol == "responses"
	if (candidate.channel.kind == "openai") ~= native then
		sendError(res, 400, "model is not available on this endpoint; use its native protocol",
			"invalid_request_error", "unsupported_protocol", metrics)
		return 400
	end
	if native then
		local message, code = ResponsesProtocol.validateRequest(request)
		if message then
			sendError(res, 400, message, "invalid_request_error", assert(code), metrics)
			return 400
		end
		session_id = session_id or ResponsesProtocol.cacheSessionId(request.prompt_cache_key)
	end

	local completion_id = "chatcmpl-" .. random.hex(16)
	local created = os.time()
	local stream_options = request.stream_options
	local include_usage = type(stream_options) == "table" and stream_options.include_usage == true or false
	local result
	if native then
		result = attemptResponse(self, res, request, public_model, candidate, session_id, metrics)
	else
		result = attempt(self, res, request, public_model, candidate, completion_id, created, include_usage, metrics)
	end
	result.channel, result.upstream_model = candidate.channel.name, candidate.upstream_model
	if result.refresh_usage then self.monitor:refresh(candidate.channel.id) end
	local status = result.status_code
	if status >= 400 and not res.headers_sent and not result.downstream_closed then
		local err = result.provider_error or {message = "upstream is unavailable", type = "upstream_error", code = "upstream_unavailable"}
		sendError(res, status, err.message, err.type, err.code, metrics)
	end
	return status, result
end

---@param request {[string]: any}
---@param result ai.router.AttemptResult?
---@return ai.router.UsageCounters
local function requestCounters(request, result)
	local message = result and result.message
	local response = result and result.response
	local usage = response and ChatProtocol.canonicalUsage(response.usage) or message and message.usage
	local input_tokens = usage and usage.input_tokens or 0
	local output_tokens = usage and usage.output_tokens or 0
	local cached = usage and usage.cached_input_tokens or 0
	if not usage then
		input_tokens = estimate({messages = request.messages, tools = request.tools,
			input = request.input, instructions = request.instructions})
		output_tokens = response and estimate(response.output)
			or message and estimate({content = message.content, tool_calls = message.tool_calls}) or 0
	end
	return {input_tokens = input_tokens, output_tokens = output_tokens,
		cached_input_tokens = cached, estimated = usage == nil}
end

---@class ai.router.InferenceContext
---@field protocol "responses"|"chat_completions"
---@field metrics ai.router.RequestMetrics
---@field created_at integer
---@field started_at number
---@field user_key string
---@field status integer
---@field request table?
---@field result ai.router.AttemptResult?
---@field admitted boolean?
---@field finalized boolean?
---@field capture ai.router.RequestCapture?
---@field request_path string?

-- All exit paths share this finalizer. Persistence failures are isolated:
-- neither aggregate writes nor request-log writes can keep a slot occupied or
-- prevent the other store from being updated. Counters are calculated once.
---@param user ai.router.UserRow
---@param context ai.router.InferenceContext
function InferenceService:finalize(user, context)
	if context.finalized then return end
	context.finalized = true
	if context.admitted then self:releaseRequest(context.user_key) end
	local request, result = context.request, context.result
	local counters
	if request then
		local ok, value = pcall(requestCounters, request, result)
		if ok then counters = value else self.logger("usage counters failed") end
	end
	if context.admitted and counters then
		local recorded = pcall(function()
			self.usage_repo:record(os.time(), user.name, context.status,
				type(request.model) == "string" and request.model or "",
				result and result.upstream_model or "", result and result.channel or "", counters)
		end)
		if not recorded then self.logger("usage write failed") end
	end
	if not user.disabled then
		local log_row
		local logged = pcall(function()
			log_row = self.request_logs_repo:record({created_at = context.created_at, user_id = user.id, user = user.name,
				model = request and type(request.model) == "string" and request.model:sub(1, 193) or "",
				channel = result and result.channel or "",
				upstream_model = result and result.upstream_model or "",
				protocol = context.protocol,
				stream = request ~= nil and request.stream == true,
				status = context.status,
				duration_ms = math.max(0, math.floor((self.get_time() - context.started_at) * 1000)),
				input_tokens = counters and counters.input_tokens or 0,
				output_tokens = counters and counters.output_tokens or 0,
				cached_input_tokens = counters and counters.cached_input_tokens or 0,
				estimated = not counters or counters.estimated,
				ttft_ms = context.metrics:ttftMs(), generation_ms = context.metrics:generationMs(),
				error_code = context.metrics:outcomeCode(context.status),
			})
		end)
		if not logged then self.logger("request log write failed") end
		if logged and log_row and context.capture then
			local saved = pcall(function()
				-- A failed capture must not keep a payload older than this owner's last ten completions.
				self.request_logs_repo:rotateDetails(user.id)
				local details = context.capture:snapshot()
				details.request_path = context.request_path
				self.request_logs_repo:recordDetails(log_row.id, user.id, details, context.created_at)
			end)
			if not saved then self.logger("request detail write failed") end
		end
	end
end

-- Validate HTTP framing before reading the bounded JSON body. Keeping this
-- shared prevents API and cookie-authenticated requests from diverging.
---@param req web.Request
---@param res web.Response
---@param metrics ai.router.RequestMetrics
---@return table? request
---@return integer? status
---@param capture ai.router.RequestCapture?
function InferenceService:readRequest(req, res, metrics, capture)
	local transfer_encodings = req.headers:getTable("Transfer-Encoding")
	local content_lengths = req.headers:getTable("Content-Length")
	local status, message, code
	if #transfer_encodings > 0 then
		status, message, code = 400, "Transfer-Encoding is not supported", "unsupported_transfer_encoding"
	elseif #content_lengths == 0 then
		status, message, code = 411, "Content-Length is required", "length_required"
	elseif #content_lengths ~= 1 then
		status, message, code = 400, "multiple Content-Length headers are not allowed", "invalid_content_length"
	else
		local content_length = tonumber(content_lengths[1])
		if not content_length then
			status, message, code = 400, "Content-Length is invalid", "invalid_content_length"
		elseif content_length > self.max_body_size then
			status, message, code = 413, "request body is too large", "request_too_large"
		end
	end
	if status then
		sendError(res, status, message, "invalid_request_error", code, metrics)
		return nil, status
	end
	if capture then capture.request_state = "partial" end
	local body, receive_err, partial = req:receive("*a")
	if capture and not pcall(capture.read, capture, body, partial) then capture.capture_failed = true end
	if body then
		local decoded, decode_err = json.decode_safe(body)
		if type(decoded) == "table" then return decoded end
		receive_err = decode_err
	end
	sendError(res, 400, "invalid JSON body: " .. tostring(receive_err), "invalid_request_error", "invalid_json", metrics)
	return nil, 400
end

-- Execute one authenticated inference request. Admission, body/affinity checks,
-- provider execution and response writes are covered by one error boundary;
-- finalization runs exactly once, including rate/concurrency rejections.
---@param req web.Request
---@param res web.Response
---@param user ai.router.UserRow
---@param protocol "responses"|"chat_completions"
---@param metrics ai.router.RequestMetrics?
---@return integer status
function InferenceService:process(req, res, user, protocol, metrics)
	metrics = metrics or RequestMetrics(self.get_time)
	---@type ai.router.InferenceContext
	local context = {protocol = protocol, metrics = metrics, created_at = os.time(),
		started_at = metrics.started_at, user_key = tostring(user.id), status = 500}
	local native = protocol == "responses"
	context.request_path = (req.uri or ""):match("^[^?]+")
	if context.request_path ~= "/v1/chat/completions" and context.request_path ~= "/v1/responses"
		and context.request_path ~= "/chat/completions" then
		context.request_path = native and "/v1/responses" or "/v1/chat/completions"
	end
	context.capture = RequestCapture()
	context.capture:attach(res)
	local ok = pcall(function()
		if not self:consumeRateLimit(context.user_key, user.max_rpm) then
			context.status = 429
			res.headers:set("Retry-After", 60)
			sendError(res, 429, "rate limit exceeded", "rate_limit_error", "rate_limit_exceeded", metrics)
			return
		end
		if not self:acquireRequest(context.user_key, user.max_concurrency) then
			context.status = 429
			res.headers:set("Retry-After", 1)
			sendError(res, 429, "too many concurrent requests", "rate_limit_error", "concurrency_limit_exceeded", metrics)
			return
		end
		context.admitted = true
		context.request, context.status = self:readRequest(req, res, metrics, context.capture)
		if not context.request then return end
		local session_id, session_err
		if native then session_id, session_err = ResponsesProtocol.getSessionAffinity(req) end
		if session_err then
			context.status = 400
			sendError(res, 400, session_err, "invalid_request_error", "invalid_session_affinity", metrics)
			return
		end
		context.status, context.result = self:complete(res, context.request, user, protocol, session_id, metrics)
	end)
	if not ok then
		context.status = 500
		metrics.error_code = "internal_error"
		-- Never expose exception text or replace committed SSE with JSON.
		pcall(function()
			if res.headers_sent then
				-- Native Responses closes here: no attempt sequence state exists.
				if not native then
					sendEvent(res, {error = {message = "request failed", type = "internal_error", code = "internal_error"}})
					sendEvent(res, "[DONE]")
				end
				res:send("")
			else
				sendError(res, 500, "request failed", "internal_error", "internal_error")
			end
		end)
	end
	context.capture:detach(res, context.status)
	self:finalize(user, context)
	return context.status
end

return InferenceService
