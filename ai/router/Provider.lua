-- Router policy for upstream requests. Protocol shapes/normalization live in
-- ai.openai.ChatCompletionsProtocol; mandatory accounting stays with the app.
local Provider = {}

-- Always collect usage, independently of downstream usage-frame preferences.
-- Copy both levels so provider adaptation never changes the client request.
---@param body table
---@return table
function Provider.streamingBody(body)
	local result, options = {}, {}
	for key, value in pairs(body) do result[key] = value end
	if type(body.stream_options) == "table" then
		for key, value in pairs(body.stream_options) do options[key] = value end
	end
	options.include_usage = true
	result.stream = true
	result.stream_options = options
	return result
end

return Provider
