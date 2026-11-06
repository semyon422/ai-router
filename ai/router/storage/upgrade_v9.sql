CREATE TABLE router_request_details (
	request_id INTEGER PRIMARY KEY,
	user_id INTEGER NOT NULL,
	request_path TEXT NOT NULL,
	request_body BLOB NOT NULL CHECK (length(CAST(request_body AS BLOB)) <= 16777216),
	response_body BLOB NOT NULL CHECK (length(CAST(response_body AS BLOB)) <= 16777216),
	request_bytes INTEGER NOT NULL,
	response_bytes INTEGER NOT NULL,
	request_state TEXT NOT NULL CHECK (request_state IN ('not_read', 'partial', 'complete')),
	request_truncated INTEGER NOT NULL CHECK (request_truncated IN (0, 1)),
	response_truncated INTEGER NOT NULL CHECK (response_truncated IN (0, 1)),
	response_complete INTEGER NOT NULL CHECK (response_complete IN (0, 1)),
	capture_failed INTEGER NOT NULL CHECK (capture_failed IN (0, 1)),
	http_status INTEGER NOT NULL,
	response_content_type TEXT NOT NULL
);

CREATE INDEX router_request_details_user_id ON router_request_details (user_id, request_id);
