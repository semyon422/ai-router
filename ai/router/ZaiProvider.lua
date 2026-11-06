local class = require("class")
local UsageClient = require("ai.zai.UsageClient")
local ZaiClient = require("ai.zai.Client")
local ZaiProtocol = require("ai.zai.Protocol")
local Provider = require("ai.router.Provider")
local ChatProtocol = require("ai.openai.ChatCompletionsProtocol")

-- Upstream adapter for a GLM Coding Plan channel. Reuses the standalone
-- proxy's field allowlist and model resolution so router traffic follows the
-- same validation rules; request bodies are rebuilt, never forwarded verbatim.
---@class ai.router.ZaiProvider
---@operator call: ai.router.ZaiProvider
---@field models_set {[string]: boolean}
---@field model_redirects {[string]: string}
---@field thinking "enabled"|"disabled"?
---@field tool_stream boolean
---@field api_key string
---@field usage_url string
---@field request zai.RequestFunc
---@field create_client fun(): zai.Client
local ZaiProvider = class()

ZaiProvider.usage_url = UsageClient.url

---@class ai.router.ZaiProviderOptions
---@field config {[string]: any} channel config: base_url, api_key, models, model_redirects?, thinking?, tool_stream?
---@field request zai.RequestFunc
---@field open_stream zai.OpenStreamFunc
---@field timeout number?
---@field get_time fun(): number

---@param options ai.router.ZaiProviderOptions
function ZaiProvider:new(options)
	assert(type(options.get_time) == "function", "get_time is required")
	local config = options.config
	assert(type(config.base_url) == "string" and config.base_url ~= "", "zai base_url is required")
	assert(type(config.api_key) == "string" and config.api_key ~= "", "zai api_key is required")
	assert(type(config.models) == "table" and #config.models > 0, "zai models are required")
	self.models_set = {}
	local config_models = config.models
	---@cast config_models string[]
	for _, model in ipairs(config_models) do
		self.models_set[model] = true
	end
	self.model_redirects = {}
	local config_redirects = config.model_redirects
	---@cast config_redirects {[string]: string}?
	for source, target in pairs(config_redirects or {}) do
		self.model_redirects[source] = target
	end
	self.thinking = config.thinking
	self.tool_stream = config.tool_stream ~= false
	self.api_key = config.api_key
	self.request = options.request
	self.usage_url = config.usage_url or ZaiProvider.usage_url
	local request = options.request
	local open_stream = options.open_stream
	self.create_client = function()
		return ZaiClient({
			get_time = options.get_time,
			base_url = config.base_url,
			api_key = config.api_key,
			timeout = options.timeout,
			request = request,
			open_stream = open_stream,
		})
	end
end

-- Validates and normalizes the request through the standalone proxy rules.
-- The caller sets body.model to the resolved concrete model; the provider maps
-- it through the channel's permanent redirects.
---@param body table
---@return table? upstream_body
---@return string? public_model
---@return boolean stream
---@return boolean include_usage
---@return string? message
---@return string? code
function ZaiProvider:normalize(body)
	return ZaiProtocol.normalizeRequest(body, self.models_set, self.model_redirects,
		self.thinking, self.tool_stream)
end

---@param body table
---@param _upstream_model string unused: normalize computes the redirected model
---@return openai.CanonicalMessage? message
---@return string? err
---@return zai.ProviderError? provider_error
function ZaiProvider:complete(body, _upstream_model)
	local upstream_body, _, _, _, message, code = self:normalize(body)
	if not upstream_body then
		return nil, nil, {status = 400, message = message, type = "invalid_request_error", code = code}
	end
	local completion, err, provider_error = self.create_client():complete(upstream_body)
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

-- Relays upstream Chat Completions deltas verbatim; the server wraps them
-- into chunks echoing the public model name.
---@param body table
---@param _upstream_model string unused: normalize computes the redirected model
---@param on_delta fun(delta: table): boolean?
---@return openai.CanonicalMessage? message
---@return string? err
---@return zai.ProviderError? provider_error
function ZaiProvider:completeStream(body, _upstream_model, on_delta)
	local upstream_body, _, _, _, message, code = self:normalize(body)
	if not upstream_body then
		return nil, nil, {status = 400, message = message, type = "invalid_request_error", code = code}
	end
	local message_result, err, provider_error = self.create_client():completeStream(Provider.streamingBody(upstream_body), on_delta)
	if not message_result then
		return nil, err, provider_error
	end
	return ChatProtocol.canonicalMessage(message_result)
end

-- Fetches the z.ai monitor endpoint with the same Coding Plan API key as
-- inference: `unit 3/number 5` is the five-hour window and `unit 6/number 1`
-- the rolling weekly window. Returns the monitor `data` object raw.
---@return table? usage
---@return string? request_error
---@return ai.router.UsageFetchError? provider_error
function ZaiProvider:fetchUsage()
	return UsageClient.fetch({request = self.request, api_key = self.api_key, url = self.usage_url})
end

return ZaiProvider
