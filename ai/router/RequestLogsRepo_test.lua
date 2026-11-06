local RequestLogsRepo = require("ai.router.RequestLogsRepo")
local RouterDatabase = require("ai.router.storage.RouterDatabase")
local LjsqliteDatabase = require("rdb.db.LjsqliteDatabase")

local test = {}

---@return ai.router.RequestLogsRepo
---@return ai.router.RouterDatabase
local function open()
	local storage = RouterDatabase(LjsqliteDatabase())
	storage.path = ":memory:"
	storage:open()
	return RequestLogsRepo(storage.models), storage
end

---@param now integer
---@param status integer?
---@return ai.router.RequestLogRow
local function row(now, status)
	return {user_id = 1, created_at = now, user = "alice", model = "fast", channel = "zai", upstream_model = "glm",
		protocol = "chat_completions", stream = true, status = status or 200, duration_ms = 1250,
		input_tokens = 10, output_tokens = 5, cached_input_tokens = 3, estimated = false}
end

---@param t testing.T
function test.persists_individual_rows_and_filters_safely(t)
	local repo, storage = open()
	repo:record(row(1000))
	repo:record(row(1001, 429))
	local other = row(1002)
	other.user, other.model, other.channel = "bob", "other", "openai"
	other.protocol, other.stream, other.estimated = "responses", false, true
	repo:record(other)
	local reloaded = RequestLogsRepo(storage.models)
	local rows = reloaded:list({}, 1002)
	t:eq(#rows, 3)
	t:eq(rows[1].id, 3)
	t:eq(rows[1].protocol, "responses")
	t:eq(rows[1].stream, false)
	t:eq(rows[1].estimated, true)
	rows = repo:list({user = "alice", model = "fast", channel = "zai", outcome = "error"}, 1002)
	t:eq(#rows, 1)
	t:eq(rows[1].status, 429)
	t:eq(rows[1].cached_input_tokens, 3)
	t:eq(rows[1].duration_ms, 1250)
	t:eq(#repo:list({outcome = "success"}, 1002), 2)
	t:eq(#repo:list({user = "' OR 1=1 --"}, 1002), 0)
	storage:close()
end

---@param t testing.T
function test.pagination_is_stable_when_new_requests_arrive(t)
	local repo, storage = open()
	repo.page_size = 2
	for now = 1000, 1004 do repo:record(row(now)) end
	local rows, cursor = repo:list({}, 1004)
	t:eq(rows[1].id, 5)
	t:eq(rows[2].id, 4)
	t:eq(cursor, 4)
	repo:record(row(1005))
	rows, cursor = repo:list({before = cursor}, 1005)
	t:eq(rows[1].id, 3)
	t:eq(rows[2].id, 2)
	t:eq(cursor, 2)
	rows, cursor = repo:list({before = cursor}, 1005)
	t:eq(#rows, 1)
	t:eq(rows[1].id, 1)
	t:eq(cursor, nil)
	storage:close()
end

---@param t testing.T
function test.retention_is_bounded_by_age_and_count_without_reusing_ids(t)
	local repo, storage = open()
	repo.max_rows, repo.retention_seconds = 2, 30
	repo:record(row(1000))
	repo:record(row(1010))
	repo:record(row(1020))
	local rows = repo:list({}, 1020)
	t:eq(#rows, 2)
	t:eq(rows[2].id, 2)
	t:eq(#repo:list({}, 1051), 0)
	repo:record(row(1060))
	rows = repo:list({}, 1060)
	t:eq(#rows, 1)
	t:eq(rows[1].id, 4)
	t:eq(#storage.db:query("SELECT * FROM router_request_logs"), 1)
	storage:close()
end

---@param t testing.T
function test.speed_requires_reported_usage_success_and_positive_stream_interval(t)
	local repo, storage = open()
	local measured = row(1000)
	measured.ttft_ms, measured.generation_ms = 250, 2000
	repo:record(measured)
	local rows = repo:list({}, 1000)
	t:eq(rows[1].ttft_ms, 250)
	t:eq(rows[1].generation_ms, 2000)
	t:eq(rows[1].output_tps, 2.5)
	measured.status, measured.error_code = 502, "timeout"
	repo:record(measured)
	rows = repo:list({}, 1000)
	t:eq(rows[1].error_code, "timeout")
	t:eq(rows[1].ttft_ms, 250)
	t:eq(rows[1].output_tps, nil)
	measured.status, measured.error_code, measured.estimated = 200, nil, true
	repo:record(measured)
	t:eq(repo:list({}, 1000)[1].output_tps, nil)
	measured.estimated, measured.generation_ms = false, 0
	repo:record(measured)
	t:eq(repo:list({}, 1000)[1].output_tps, nil)
	measured.stream, measured.generation_ms = false, 2000
	repo:record(measured)
	t:eq(repo:list({}, 1000)[1].output_tps, nil)
	repo:record(row(1000))
	rows = repo:list({}, 1000)
	t:eq(rows[1].ttft_ms, nil)
	t:eq(rows[1].generation_ms, nil)
	t:eq(rows[1].output_tps, nil)
	t:eq(rows[1].error_code, nil)
	storage:close()
end

---@param t testing.T
function test.filter_options_are_retained_distinct_sorted_and_bounded(t)
	local repo, storage = open()
	repo.retention_seconds = 10
	for i = 101, 1, -1 do
		local record = row(1000)
		record.user = ("user-%03d"):format(i)
		repo:record(record)
	end
	local duplicate = row(1000)
	duplicate.user = "user-001"
	repo:record(duplicate)
	local blank = row(1000)
	blank.user, blank.model, blank.channel = "", "", ""
	repo:record(blank)
	local options = repo:filterOptions(1010)
	t:eq(#options.user, 100)
	t:eq(options.user[1], "user-001")
	t:eq(options.user[100], "user-100")
	t:tdeq(options.model, {"fast"})
	t:tdeq(options.channel, {"zai"})
	options = repo:filterOptions(1011)
	t:tdeq(options, {user = {}, model = {}, channel = {}})
	t:eq(#storage.db:query("SELECT * FROM router_request_logs"), 103)
	storage:close()
end

---@param t testing.T
function test.owner_scope_applies_to_rows_and_filter_suggestions(t)
	local repo, storage = open()
	local own, foreign = row(1000), row(1001)
	foreign.user_id, foreign.model, foreign.channel = 2, "PRIVATE-MODEL", "PRIVATE-CHANNEL"
	-- Same display name must never confer ownership.
	repo:record(own)
	repo:record(foreign)
	t:eq(#repo:list({user_id = 1}, 1001), 1)
	t:eq(#repo:list({user_id = 1, model = "PRIVATE-MODEL"}, 1001), 0)
	t:tdeq(repo:filterOptions(1001, 1), {user = {"alice"}, model = {"fast"}, channel = {"zai"}})
	t:eq(#repo:list({}, 1001), 2)
	t:has_error(function() repo:list({user_id = "1 OR 1=1"}, 1001) end)
	storage:close()
end

local function details(text)
	text = text or '{"messages":[{"role":"user","content":"private"}]}'
	return {request_path = "/v1/chat/completions", request_body = text, response_body = "data: [DONE]\n\n",
		request_bytes = #text, response_bytes = 14, request_state = "complete", request_truncated = false,
		response_truncated = false, response_complete = true, capture_failed = false,
		http_status = 200, response_content_type = "text/event-stream"}
end

function test.ten_payload_pairs_are_retained_per_stable_owner_not_name(t)
	local repo, storage = open()
	local ids = {}
	for i = 1, 12 do
		for owner = 1, 2 do
			local entry = row(1000 + i)
			entry.user_id, entry.user = owner, "same-name"
			local saved = repo:record(entry)
			repo:recordDetails(saved.id, owner, details("owner" .. owner .. "-" .. i), entry.created_at)
			if owner == 1 then ids[i] = saved.id end
		end
	end
	t:eq(#storage.db:query("SELECT request_id FROM router_request_details"), 20)
	t:eq(repo:getDetails(ids[1], 1), nil)
	t:eq(repo:getDetails(ids[2], 1), nil)
	t:eq(repo:getBody(ids[3], "request", 1), "owner1-3")
	t:eq(repo:getBody(ids[3], "request", 2), nil)
	t:eq(repo:getDetails(ids[3], 2), nil)
	t:eq(repo:get(ids[3], 2, 1012), nil)
	t:eq(repo:getDetails(ids[3]).request_truncated, false)
	t:eq(repo:get(ids[1], 1, 1012).has_details, false)
	t:eq(repo:get(ids[3], 1, 1012).has_details, true)
	t:has_error(function() repo:getBody(ids[3], "request", "1 OR 1=1") end)
	t:has_error(function() repo:getBody(ids[3], "request_body FROM router_request_logs") end)
	storage:close()
end

function test.detailed_metadata_is_pinned_past_age_and_global_count_until_eviction(t)
	local repo, storage = open()
	repo.max_rows, repo.retention_seconds, repo.details_per_user = 2, 10, 1
	local saved = repo:record(row(1000))
	repo:recordDetails(saved.id, 1, details(), 1000)
	for i = 1, 5 do
		local other = row(2000 + i)
		other.user_id, other.user = 2, "bob"
		repo:record(other)
	end
	t:eq(#storage.db:query("SELECT id FROM router_request_logs"), 3)
	t:eq(#repo:list({user_id = 1}, 5000), 1)
	t:tdeq(repo:filterOptions(5000, 1).user, {"alice"})
	t:assert(repo:get(saved.id, 1, 5000))
	local newer = repo:record(row(5000))
	repo:recordDetails(newer.id, 1, details("new"), 5000)
	t:eq(repo:getDetails(saved.id, 1), nil)
	t:eq(repo:get(saved.id, 1, 5000), nil)
	t:eq(#storage.db:query("SELECT id FROM router_request_logs WHERE id = " .. saved.id), 0)
	t:eq(repo:getBody(newer.id, "request", 1), "new")
	storage:close()
end

function test.details_preserve_binary_bytes_but_only_return_bounded_previews(t)
	local repo, storage = open()
	repo.preview_size = 4
	local saved = repo:record(row(1000))
	local raw = "abc\0<script>\208\175</script>"
	repo:recordDetails(saved.id, 1, details(raw), 1000)
	local view = repo:getDetails(saved.id, 1)
	t:eq(view.request_preview, "abc\0")
	t:eq(view.request_saved_bytes, #raw)
	t:eq(repo:getBody(saved.id, "request", 1), raw)
	t:eq(repo:getBody(saved.id, "response", 1), "data: [DONE]\n\n")
	local listed = repo:list({}, 1000)
	t:eq(listed[1].request_body, nil)
	t:eq(listed[1].request_preview, nil)
	storage:close()
end

function test.detail_failure_rolls_back_without_losing_metadata_or_previous_bodies(t)
	local repo, storage = open()
	local saved = repo:record(row(1000))
	repo:recordDetails(saved.id, 1, details("keep"), 1000)
	t:has_error(function() repo:recordDetails(saved.id, 2, details("foreign"), 1000) end)
	t:has_error(function() repo:recordDetails(saved.id, 1, details("duplicate"), 1000) end)
	t:eq(repo:getBody(saved.id, "request", 1), "keep")
	local newer = repo:record(row(1001))
	local invalid = details("bad")
	invalid.request_state = "invalid"
	t:has_error(function() repo:recordDetails(newer.id, 1, invalid, 1001) end)
	t:assert(repo:get(newer.id, 1, 1001))
	t:eq(repo:getBody(saved.id, "request", 1), "keep")
	storage.db:exec("BEGIN")
	storage.db:exec("ROLLBACK")
	storage:close()
end

function test.storage_caps_cannot_be_bypassed_with_nul_text(t)
	local repo, storage = open()
	local saved = repo:record(row(1000))
	local oversized = details("\0" .. string.rep("x", 16 * 1024 * 1024))
	t:has_error(function() repo:recordDetails(saved.id, 1, oversized, 1000) end)
	t:eq(repo:getDetails(saved.id, 1), nil)
	local oversized_response = details("small")
	oversized_response.response_body, oversized_response.response_bytes = oversized.request_body, #oversized.request_body
	t:has_error(function() repo:recordDetails(saved.id, 1, oversized_response, 1000) end)
	t:eq(repo:getDetails(saved.id, 1), nil)
	t:assert(repo:get(saved.id, 1, 1000))
	storage:close()
end

function test.failed_capture_does_not_pin_payloads_older_than_the_last_ten_completions(t)
	local repo, storage = open()
	repo.details_per_user = 2
	local saved = repo:record(row(1000))
	repo:recordDetails(saved.id, 1, details("old"), 1000)
	repo:record(row(1001))
	repo:record(row(1002))
	repo:rotateDetails(1)
	t:eq(repo:getBody(saved.id, "request", 1), nil)
	t:eq(repo:get(saved.id, 1, 1002).has_details, false)
	storage:close()
end

return test
