local class = require("class")

-- Per-request observer of client payloads, never headers or HTTP framing.
-- Recording attempted writes is intentional: disconnects cannot tell us exactly
-- which bytes the peer received. No observer failure may change inference.
---@class ai.router.RequestCapture
---@operator call: ai.router.RequestCapture
local RequestCapture = class()
RequestCapture.body_limit = 16 * 1024 * 1024

function RequestCapture:new(limit)
	self.limit = limit or self.body_limit
	self.request_body, self.request_bytes, self.request_state = "", 0, "not_read"
	self.response_bytes, self.response_stored = 0, 0
	self.chunks, self.pending, self.pending_bytes = {}, {}, 0
end

function RequestCapture:read(body, partial)
	local text = body or partial or ""
	self.request_bytes = #text
	self.request_body = text:sub(1, self.limit)
	self.request_state = body and "complete" or "partial"
end

function RequestCapture:flush()
	if self.pending_bytes == 0 then return end
	self.chunks[#self.chunks + 1] = table.concat(self.pending)
	self.pending, self.pending_bytes = {}, 0
end

function RequestCapture:append(data)
	self.response_bytes = self.response_bytes + #data
	local remaining = self.limit - self.response_stored
	if remaining <= 0 or #data == 0 then return end
	local part = data:sub(1, remaining)
	self.pending[#self.pending + 1] = part
	self.pending_bytes = self.pending_bytes + #part
	self.response_stored = self.response_stored + #part
	if self.pending_bytes >= 65536 then self:flush() end
end

function RequestCapture:attach(res)
	local send, send_headers = res.send, res.send_headers
	local own_send, own_headers = rawget(res, "send"), rawget(res, "send_headers")
	res.send_headers = function(response, ...)
		if not response.headers_sent and not self.http_status then self.http_status = response.status or 200 end
		local ok, a, b, c = pcall(send_headers, response, ...)
		if not ok or not a then self.write_failed = true end
		if not ok then error(a, 0) end
		return a, b, c
	end
	res.send = function(response, data, ...)
		if not pcall(self.append, self, data) then self.capture_failed = true end
		local ok, a, b, c = pcall(send, response, data, ...)
		if not ok or not a then self.write_failed = true end
		if not ok then error(a, 0) end
		return a, b, c
	end
	self.restore = function()
		res.send, res.send_headers = own_send, own_headers
	end
end

function RequestCapture:detach(res, status)
	self.restore()
	self.restore = nil
	self.http_status = self.http_status or res.status or status
	local content_type = res.headers:get("Content-Type") or ""
	self.response_content_type = content_type:match("^text/event%-stream") and "text/event-stream"
		or content_type:match("^application/json") and "application/json" or "text/plain"
	self.response_complete = not self.write_failed and not self.capture_failed
		and not (status >= 400 and self.response_content_type == "text/event-stream")
end

function RequestCapture:snapshot()
	if self.saved then return self.saved end
	self:flush()
	self.saved = {request_body = self.request_body, response_body = table.concat(self.chunks),
		request_bytes = self.request_bytes, response_bytes = self.response_bytes,
		request_state = self.request_state, request_truncated = self.request_bytes > #self.request_body,
		response_truncated = self.response_bytes > self.response_stored,
		response_complete = self.response_complete == true, capture_failed = self.capture_failed == true,
		http_status = self.http_status, response_content_type = self.response_content_type}
	self.chunks, self.pending = nil, nil
	return self.saved
end

return RequestCapture
