local Capture = require("ai.router.RequestCapture")
local Headers = require("web.http.Headers")
local test = {}

local function response()
	local res = {status = 200, headers = Headers(), chunks = {}}
	function res:send_headers() self.headers_sent = true return 1 end
	function res:send(data)
		if not self.headers_sent then self:send_headers() end
		self.chunks[#self.chunks + 1] = data
		if self.closed then return nil, "closed", 3 end
		return #data
	end
	return res
end

function test.observes_exact_payloads_without_headers_and_restores_methods(t)
	local capture, res = Capture(), response()
	res.headers:set("Authorization", "PRIVATE-HEADER")
	res.headers:set("Content-Type", "text/event-stream")
	local original_send = res.send
	capture:attach(res)
	capture:read('{"messages":[{"content":"hello"}]}')
	local raw = 'event: response.output_text.delta\ndata: {"delta":"<script>"}\n\ndata: [DONE]\n\n'
	t:eq(res:send(raw), #raw)
	capture:detach(res, 200)
	t:eq(res.send, original_send)
	local saved = capture:snapshot()
	t:eq(saved.response_body, raw)
	t:eq(saved.http_status, 200)
	t:eq(saved.request_state, "complete")
	t:eq(saved.response_complete, true)
	t:eq(saved.response_body:find("PRIVATE-HEADER", 1, true), nil)
	t:eq(capture:snapshot(), saved)
end

function test.both_limits_are_byte_based_and_do_not_change_output(t)
	local capture, res = Capture(8), response()
	capture:attach(res)
	capture:read("0123456789")
	res:send("123456")
	res:send("789abcdef")
	capture:detach(res, 200)
	local saved = capture:snapshot()
	t:eq(saved.request_body, "01234567")
	t:eq(saved.response_body, "12345678")
	t:eq(saved.request_bytes, 10)
	t:eq(saved.response_bytes, 15)
	t:eq(saved.request_truncated, true)
	t:eq(saved.response_truncated, true)
	t:eq(saved.response_complete, true)
	t:eq(table.concat(res.chunks), "123456789abcdef")
end

function test.partial_reads_unread_rejections_and_failed_streams_are_explicit(t)
	local capture, res = Capture(), response()
	capture:attach(res)
	res.status = 429
	res:send("error")
	capture:detach(res, 429)
	t:eq(capture:snapshot().request_state, "not_read")
	t:eq(capture:snapshot().response_complete, true)
	capture, res = Capture(), response()
	capture:attach(res)
	capture:read(nil, "{partial")
	res.headers:set("Content-Type", "text/event-stream")
	res:send("data: {}\n\n")
	capture:detach(res, 502)
	t:eq(capture:snapshot().request_body, "{partial")
	t:eq(capture:snapshot().request_state, "partial")
	t:eq(capture:snapshot().response_complete, false)
end

function test.observer_and_transport_failures_do_not_replace_response_behavior(t)
	local capture, res = Capture(), response()
	capture:attach(res)
	capture.append = function() error("PRIVATE-CAPTURE-ERROR") end
	t:eq(res:send("original"), 8)
	capture:detach(res, 200)
	t:eq(table.concat(res.chunks), "original")
	t:eq(capture:snapshot().capture_failed, true)
	capture, res = Capture(), response()
	res.closed = true
	capture:attach(res)
	local result, err, partial = res:send("original")
	t:eq(result, nil)
	t:eq(err, "closed")
	t:eq(partial, 3)
	capture:detach(res, 499)
	t:eq(capture:snapshot().response_complete, false)
end

function test.coalesces_tiny_writes_and_keeps_captures_isolated(t)
	local a, b = Capture(200000), Capture(200000)
	for _ = 1, 100000 do a:append("a") end
	t:eq(#a.chunks, 1)
	t:assert(a.pending_bytes < 65536)
	b:append("b")
	t:eq(#a:snapshot().response_body, 100000)
	t:eq(b:snapshot().response_body, "b")
end

return test
