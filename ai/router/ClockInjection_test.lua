local test = {}

---@param t testing.T
function test.inference_server_and_providers_require_and_forward_clocks(t)
	for _, name in ipairs({"Server", "InferenceService", "OpenAIProvider", "ZaiProvider", "CompatProvider"}) do
		local Constructor = require("ai.router." .. name)
		local options = {
			config = {base_url = "http://localhost/v1", api_key = "key", models = {"model"}},
			users_repo = {models = {}}, scheduler = {}, auth = {},
			provider_factory = function() return nil end,
			request = function() error("not used") end,
			open_stream = function() error("not used") end,
		}
		for _, clock_options in ipairs({{}, {get_time = false}, {get_time = 123}, {get_time = "clock"}}) do
			options.get_time = clock_options.get_time
			local ok, err = pcall(Constructor, options)
			t:eq(ok, false)
			t:assert(tostring(err):find("get_time is required", 1, true), name .. ": " .. tostring(err))
		end
		local clock = function() return 42.125 end
		options.get_time = clock
		local instance = Constructor(options)
		if name == "Server" then
			t:eq(instance.get_time, clock)
			t:eq(instance.inference.get_time(), 42.125)
		elseif name == "InferenceService" then
			t:eq(instance.get_time, clock)
		else
			local client = name == "OpenAIProvider" and instance:createClient("model") or instance.create_client()
			t:eq(client.get_time, clock)
		end
	end
end

return test
