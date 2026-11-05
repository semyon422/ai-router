local json = require("web.json")

-- Stateless HTTP/SSE output shared by the listener and inference execution.
local ResponseWriter = {}

---@param res web.Response
---@param status integer
---@param message string
---@param error_type string
---@param code string
---@param metrics ai.router.RequestMetrics?
function ResponseWriter.sendError(res, status, message, error_type, code, metrics)
	if metrics then metrics:setError(status, code) end
	local body = json.encode({error = {message = message, type = error_type, code = code}})
	res.status = status
	res.headers:set("Content-Type", "application/json")
	if status == 401 then res.headers:set("WWW-Authenticate", "Bearer") end
	res:set_length(#body)
	res:send(body)
end

---@param res web.Response
---@param body table
---@return boolean
function ResponseWriter.sendJson(res, body)
	local encoded = json.encode(body)
	res.status = 200
	res.headers:set("Content-Type", "application/json")
	res.headers:set("Cache-Control", "no-store")
	res:set_length(#encoded)
	return res:send(encoded) ~= nil
end

---@param res web.Response
---@param event table|string
---@return boolean
function ResponseWriter.sendEvent(res, event)
	local data = type(event) == "string" and event or json.encode(event)
	return res:send("data: " .. data .. "\n\n") ~= nil
end

---@param res web.Response
---@return boolean
function ResponseWriter.startEventStream(res)
	if res.headers_sent then return true end
	res.status = 200
	res.headers:set("Content-Type", "text/event-stream")
	res.headers:set("Cache-Control", "no-cache")
	res:set_chunked_encoding()
	return res:send_headers() ~= nil
end

---@param res web.Response
---@param event {[string]: any}
---@return boolean
function ResponseWriter.sendResponseEvent(res, event)
	local event_type = type(event.type) == "string" and event.type:match("^[%w._-]+$") or nil
	local prefix = event_type and "event: " .. event_type .. "\n" or ""
	return res:send(prefix .. "data: " .. json.encode(event) .. "\n\n") ~= nil
end

return ResponseWriter
