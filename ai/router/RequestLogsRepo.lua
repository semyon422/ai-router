local class = require("class")

---@class ai.router.RequestLogRow
---@field id integer?
---@field user_id integer
---@field created_at integer
---@field user string
---@field model string
---@field channel string
---@field upstream_model string
---@field protocol "responses"|"chat_completions"
---@field stream boolean
---@field status integer logical outcome, including failures after SSE commit
---@field duration_ms integer
---@field input_tokens integer
---@field output_tokens integer
---@field cached_input_tokens integer
---@field estimated boolean
---@field ttft_ms integer? first nonempty streamed output, including reasoning/tool arguments
---@field generation_ms integer? first output to provider completion
---@field output_tps number? derived only for successful streams with reported usage
---@field error_code ai.router.RequestErrorCode?
---@field has_details boolean? Present on metadata reads, never stores payloads inline.

---@class ai.router.RequestLogFilters
---@field before integer?
---@field user_id integer? Trusted authorization scope, never read from a browser query.
---@field user string?
---@field model string?
---@field channel string?
---@field outcome "success"|"error"?

-- Metadata plus ten bounded client payload pairs per stable user ID.
-- Bodies are deliberately absent from list/filter queries and application logs.
---@class ai.router.RequestLogsRepo
---@operator call: ai.router.RequestLogsRepo
---@field models rdb.Models
local RequestLogsRepo = class()

RequestLogsRepo.max_rows = 10000
RequestLogsRepo.retention_seconds = 7 * 24 * 3600
RequestLogsRepo.page_size = 50
RequestLogsRepo.details_per_user = 10
RequestLogsRepo.preview_size = 64 * 1024

local has_details = [[EXISTS (SELECT 1 FROM router_request_details AS d
	WHERE d.request_id = router_request_logs.id AND d.user_id = router_request_logs.user_id)]]
local retained = "(created_at >= ? OR " .. has_details .. ")"
local select_logs = "SELECT router_request_logs.*, " .. has_details .. " AS has_details FROM router_request_logs"

local function ownerClause(user_id, values)
	if user_id == nil then return "" end
	assert(type(user_id) == "number" and user_id >= 1 and user_id % 1 == 0, "invalid history owner")
	values[#values + 1] = user_id
	return " AND user_id = ?"
end

local function normalize(row)
	for _, key in ipairs({"id", "user_id", "created_at", "status", "duration_ms", "input_tokens", "output_tokens", "cached_input_tokens"}) do
		row[key] = assert(tonumber(row[key]))
	end
	row.stream, row.estimated, row.has_details = row.stream == 1, row.estimated == 1, row.has_details == 1
	row.ttft_ms, row.generation_ms = tonumber(row.ttft_ms), tonumber(row.generation_ms)
	if row.stream and row.status < 400 and not row.estimated and row.output_tokens > 0
		and row.ttft_ms and row.generation_ms and row.generation_ms > 0 then
		row.output_tps = row.output_tokens * 1000 / row.generation_ms
	end
	return row
end

---@param models rdb.Models
function RequestLogsRepo:new(models)
	self.models = models
end

---@param row ai.router.RequestLogRow
function RequestLogsRepo:record(row)
	local saved = self.models.router_request_logs:create(row)
	self:prune(row.created_at)
	return saved
end

function RequestLogsRepo:prune(now)
	local db = self.models.router_request_logs.orm.db
	-- Detailed rows are pinned until that owner's next requests evict them.
	-- Do not use ORM DELETE RETURNING * for large payloads.
	db:query("DELETE FROM router_request_logs WHERE created_at < ? AND NOT " .. has_details,
		{now - self.retention_seconds})
	db:query("DELETE FROM router_request_logs WHERE id IN (SELECT id FROM router_request_logs WHERE NOT "
		.. has_details .. " ORDER BY id DESC LIMIT -1 OFFSET ?)", {self.max_rows})
end

function RequestLogsRepo:rotateDetails(user_id)
	ownerClause(user_id, {})
	assert(user_id, "detail owner is required")
	self.models.router_request_logs.orm.db:query([[DELETE FROM router_request_details WHERE user_id = ? AND request_id NOT IN
		(SELECT id FROM router_request_logs WHERE user_id = ? ORDER BY id DESC LIMIT ?)]],
		{user_id, user_id, self.details_per_user})
end

-- Isolated from metadata and aggregate writes. Rotation is atomic, never global
-- and never tied to mutable display names or an age limit.
function RequestLogsRepo:recordDetails(id, user_id, details, now)
	local orm = self.models.router_request_logs.orm
	local values = {id}
	local owner = ownerClause(user_id, values)
	assert(user_id and orm:query("SELECT id FROM router_request_logs WHERE id = ?" .. owner, values)[1], "invalid detail owner")
	local columns = {"request_id", "user_id", "request_path", "request_body", "response_body", "request_bytes",
		"response_bytes", "request_state", "request_truncated", "response_truncated", "response_complete",
		"capture_failed", "http_status", "response_content_type"}
	values = {id, user_id}
	local placeholders = {"?", "?"}
	for index = 3, #columns do
		local value = details[columns[index]]
		assert(value ~= nil, "missing detail field")
		if type(value) == "boolean" then value = value and 1 or 0 end
		values[#values + 1] = value
		placeholders[#placeholders + 1] = "?"
	end
	orm:begin()
	local ok, err = pcall(function()
		orm.db:query("INSERT INTO router_request_details (" .. table.concat(columns, ",") .. ") VALUES ("
			.. table.concat(placeholders, ",") .. ")", values)
		self:rotateDetails(user_id)
		orm:commit()
	end)
	if not ok then orm.db:exec("ROLLBACK") error(err) end
	self:prune(now)
end

function RequestLogsRepo:get(id, user_id, now)
	local values = {id, now - self.retention_seconds}
	local row = self.models.router_request_logs.orm:query(select_logs .. " WHERE id = ? AND " .. retained
		.. ownerClause(user_id, values), values)[1]
	return row and normalize(row)
end

function RequestLogsRepo:getDetails(id, user_id)
	local values = {self.preview_size, self.preview_size, id}
	local owner = ownerClause(user_id, values)
	local row = self.models.router_request_logs.orm:query([[SELECT d.request_path, d.request_state,
		d.request_bytes, d.response_bytes, d.request_truncated, d.response_truncated, d.response_complete,
		d.capture_failed, d.http_status, d.response_content_type,
		length(CAST(d.request_body AS BLOB)) AS request_saved_bytes,
		length(CAST(d.response_body AS BLOB)) AS response_saved_bytes,
		substr(CAST(d.request_body AS BLOB), 1, ?) AS request_preview,
		substr(CAST(d.response_body AS BLOB), 1, ?) AS response_preview
		FROM router_request_details AS d JOIN router_request_logs USING (user_id)
		WHERE d.request_id = router_request_logs.id AND d.request_id = ?]] .. owner, values)[1]
	if not row then return end
	for _, key in ipairs({"request_bytes", "response_bytes", "request_saved_bytes", "response_saved_bytes", "http_status"}) do
		row[key] = assert(tonumber(row[key]))
	end
	for _, key in ipairs({"request_truncated", "response_truncated", "response_complete", "capture_failed"}) do
		row[key] = row[key] == 1
	end
	return row
end

function RequestLogsRepo:getBody(id, side, user_id)
	assert(side == "request" or side == "response", "invalid body side")
	local values = {id}
	local owner = ownerClause(user_id, values)
	local row = self.models.router_request_logs.orm:query("SELECT d." .. side .. [[_body AS body
		FROM router_request_details AS d JOIN router_request_logs USING (user_id)
		WHERE d.request_id = router_request_logs.id AND d.request_id = ?]] .. owner, values)[1]
	return row and row.body
end

---@param filters ai.router.RequestLogFilters
---@param now integer
---@return ai.router.RequestLogRow[] rows
---@return integer? next_before
function RequestLogsRepo:list(filters, now)
	local clauses = {retained}
	---@type (string|number)[]
	local values = {now - self.retention_seconds}
	if filters.user_id ~= nil then
		assert(type(filters.user_id) == "number" and filters.user_id >= 1 and filters.user_id % 1 == 0, "invalid history owner")
		table.insert(clauses, "user_id = ?")
		table.insert(values, filters.user_id)
	end
	for _, key in ipairs({"user", "model", "channel"}) do
		---@type string?
		local value = filters[key]
		if value and value ~= "" then
			table.insert(clauses, key .. " = ?")
			table.insert(values, value)
		end
	end
	if filters.before then
		table.insert(clauses, "id < ?")
		table.insert(values, filters.before)
	end
	if filters.outcome == "error" then table.insert(clauses, "status >= 400")
	elseif filters.outcome == "success" then table.insert(clauses, "status < 400") end
	table.insert(values, self.page_size + 1)
	local rows = self.models.router_request_logs.orm:query(select_logs .. " WHERE "
		.. table.concat(clauses, " AND ") .. " ORDER BY id DESC LIMIT ?", values)
	for _, row in ipairs(rows) do normalize(row) end
	---@type integer?
	local next_before
	if #rows > self.page_size then
		table.remove(rows)
		next_before = rows[#rows].id
	end
	return rows, next_before
end

---@class ai.router.RequestLogFilterOptions
---@field user string[]
---@field model string[]
---@field channel string[]

---@param now integer
---@param user_id integer? Trusted authorization scope for suggestions as well as rows.
---@return ai.router.RequestLogFilterOptions
function RequestLogsRepo:filterOptions(now, user_id)
	---@type ai.router.RequestLogFilterOptions
	local options = {user = {}, model = {}, channel = {}}
	local owner_clause = ""
	local values = {now - self.retention_seconds}
	if user_id ~= nil then
		assert(type(user_id) == "number" and user_id >= 1 and user_id % 1 == 0, "invalid history owner")
		owner_clause = " AND user_id = ?"
		table.insert(values, user_id)
	end
	for _, key in ipairs({"user", "model", "channel"}) do
		local rows = self.models.router_request_logs.orm:query("SELECT DISTINCT " .. key
			.. " AS value FROM router_request_logs WHERE " .. retained .. owner_clause .. " AND " .. key .. " <> '' ORDER BY " .. key .. " LIMIT 100",
			values)
		---@type string[]
		local values = options[key]
		for _, row in ipairs(rows) do table.insert(values, row.value) end
	end
	return options
end

return RequestLogsRepo
