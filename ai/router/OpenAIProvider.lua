local class = require("class")
local UsageClient = require("ai.openai.UsageClient")
local SubscriptionAuth = require("ai.openai.SubscriptionAuth")
local SubscriptionClient = require("ai.openai.SubscriptionClient")

---@class ai.router.OpenAIProviderConfig
---@field reasoning_effort openai.ReasoningEffort?
---@field verbosity "low"|"medium"|"high"?
---@field max_response_size integer?

---@class ai.router.OpenAIProviderOptions
---@field config ai.router.OpenAIProviderConfig
---@field scheduler web.CosocketScheduler
---@field request zai.RequestFunc
---@field open_stream openai.OpenStreamFunc
---@field timeout number?
---@field get_time fun(): number
---@field auth openai.SubscriptionAuthGuard
---@field usage_url string?

-- Upstream adapter for one ChatGPT channel: per-channel OAuth
-- credentials, native Responses transport, and the
-- Codex usage monitor fetch.
---@class ai.router.OpenAIProvider
---@operator call: ai.router.OpenAIProvider
---@field config ai.router.OpenAIProviderConfig
---@field auth openai.SubscriptionAuthGuard
---@field scheduler web.CosocketScheduler
---@field request zai.RequestFunc
---@field open_stream openai.OpenStreamFunc
---@field timeout number?
---@field get_time fun(): number
---@field usage_url string
local OpenAIProvider = class()

OpenAIProvider.usage_url = UsageClient.url

---@class ai.router.OpenAIAuthOptions
---@field channel_id integer
---@field oauth_repo ai.router.OAuthRepo
---@field scheduler web.CosocketScheduler
---@field request openai.RequestFunc

---@param options ai.router.OpenAIAuthOptions
---@return openai.SubscriptionAuth
function OpenAIProvider.createAuth(options)
	local credentials = options.oauth_repo:get(options.channel_id)
	local generation = credentials.generation
	return SubscriptionAuth({
		scheduler = options.scheduler,
		credentials = credentials,
		save_credentials = function()
			options.oauth_repo:save(options.channel_id, generation, credentials)
		end,
		open_url = function() return true end,
		request = options.request,
	})
end

---@param options ai.router.OpenAIProviderOptions
function OpenAIProvider:new(options)
	local config = options.config
	self.config = config
	self.scheduler = options.scheduler
	self.request = options.request
	self.open_stream = options.open_stream
	self.timeout = options.timeout
	assert(type(options.get_time) == "function", "get_time is required")
	self.get_time = options.get_time
	self.usage_url = options.usage_url or OpenAIProvider.usage_url
	self.auth = assert(options.auth, "OpenAI auth guard is required")
end

-- Creates a per-request client so concurrent requests never share response
-- assembly or cancellation state; authentication stays shared and guarded.
---@param upstream_model string
---@param session_id string?
---@return openai.SubscriptionClient
function OpenAIProvider:createClient(upstream_model, session_id)
	return SubscriptionClient({
		auth = self.auth,
		model = upstream_model,
		reasoning_effort = self.config.reasoning_effort or "medium",
		session_id = session_id,
		verbosity = self.config.verbosity,
		max_response_size = self.config.max_response_size,
		timeout = self.timeout,
		get_time = self.get_time,
		open_stream = self.open_stream,
	})
end

-- The server validates native input and affinity before any upstream work.
---@param body {[string]: any}
---@param upstream_model string
---@param session_id string?
---@param on_event (fun(event: table): boolean?)?
---@return table? response
---@return string? err
---@return zai.ProviderError? provider_error
function OpenAIProvider:createResponse(body, upstream_model, session_id, on_event)
	return self:createClient(upstream_model, session_id):createResponse(body, on_event)
end

-- Fetches the upstream Codex usage object (rate limit windows). Returns the
-- raw upstream object; ai.openai.UsageProtocol parses its quota windows.
---@return table? usage
---@return string? request_error
---@return ai.router.UsageFetchError? provider_error
function OpenAIProvider:fetchUsage()
	return UsageClient.fetch({request = self.request, auth = self.auth, url = self.usage_url, originator = "ai-router"})
end

return OpenAIProvider
