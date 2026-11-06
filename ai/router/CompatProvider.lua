local class = require("class")
local ChatCompletionsClient = require("ai.openai.ChatCompletionsClient")
local Provider = require("ai.router.Provider")
local ChatProtocol = require("ai.openai.ChatCompletionsProtocol")

-- Upstream adapter for a trusted local OpenAI-compatible endpoint such as
-- llama.cpp. No field allowlist is applied: the validated client body is
-- forwarded with the model name replaced and streaming usage always requested;
-- deltas are relayed unchanged.
---@class ai.router.CompatProvider
---@operator call: ai.router.CompatProvider
---@field create_client fun(): openai.ChatCompletionsClient
local CompatProvider = class()

---@class ai.router.CompatProviderOptions
---@field config {[string]: any} channel config: base_url, api_key?, models
---@field request openai.RequestFunc
---@field open_stream openai.OpenStreamFunc
---@field timeout number?
---@field get_time fun(): number

---@param options ai.router.CompatProviderOptions
function CompatProvider:new(options)
	assert(type(options.get_time) == "function", "get_time is required")
	local config = options.config
	assert(type(config.base_url) == "string" and config.base_url ~= "", "compat base_url is required")
	assert(type(config.models) == "table" and #config.models > 0, "compat models are required")
	local request = options.request
	local open_stream = options.open_stream
	self.create_client = function()
		return ChatCompletionsClient({
			get_time = options.get_time,
			base_url = config.base_url,
			api_key = config.api_key,
			timeout = options.timeout,
			request = request,
			open_stream = open_stream,
		})
	end
end

-- Copies the request body and sends the resolved upstream model name.
---@param body table
---@param upstream_model string
---@return table upstream_body
function CompatProvider.upstreamBody(body, upstream_model)
	---@type {[string]: any}
	local upstream_body = {}
	---@cast body {[string]: any}
	for key, value in pairs(body) do
		upstream_body[key] = value
	end
	upstream_body.model = upstream_model
	return upstream_body
end

---@param body table
---@param upstream_model string
---@return openai.CanonicalMessage? message
---@return string? err
---@return openai.ChatCompletionsError? provider_error
function CompatProvider:complete(body, upstream_model)
	local completion, err, provider_error = self.create_client():complete(CompatProvider.upstreamBody(body, upstream_model))
	if not completion then
		return nil, err, provider_error
	end
	---@cast completion {[string]: any}
	local choice = completion.choices[1]
	---@type openai.CanonicalMessage
	local canonical = ChatProtocol.canonicalMessage(choice.message, completion.usage)
	if type(choice.finish_reason) == "string" then
		canonical.finish_reason = choice.finish_reason
	end
	return canonical
end

---@param body table
---@param upstream_model string
---@param on_delta fun(delta: table): boolean?
---@return openai.CanonicalMessage? message
---@return string? err
---@return openai.ChatCompletionsError? provider_error
function CompatProvider:completeStream(body, upstream_model, on_delta)
	local message, err, provider_error = self.create_client():completeStream(
		Provider.streamingBody(CompatProvider.upstreamBody(body, upstream_model)), on_delta)
	if not message then
		return nil, err, provider_error
	end
	return ChatProtocol.canonicalMessage(message)
end

return CompatProvider
