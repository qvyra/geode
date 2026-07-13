--!strict

-- L1. The write path: transactions, ops and the in-memory document every store is built on

local Document = require("@self/Document")
local Transaction = require("@self/Transaction")

return {
	Document = Document,
	Transaction = Transaction,
}
