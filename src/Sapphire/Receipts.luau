--!strict

-- A ProcessReceipt callback that never grants a purchase twice. The grant and the purchase id
-- commit together and save in the same write, and PurchaseGranted only goes back once that
-- write succeeded. If the server dies before saving, both are lost together and Roblox just
-- asks again

local ProfileStore = require("./ProfileStore")
local Transaction = require("../Matrix/Transaction")

export type ReceiptInfo = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string | number,
	[string]: unknown,
}

-- runs inside the granting transaction, throw to refuse the purchase for now
export type Handler = (tx: Transaction.Transaction, info: ReceiptInfo) -> ()

export type Decisions = {
	granted: unknown,
	notProcessed: unknown,
}

export type Options = {
	-- What the callback returns. Defaults to Enum.ProductPurchaseDecision, read when first used
	decisions: Decisions?,
	reportError: ((message: string) -> ())?,
}

local Receipts = {}

local function liveDecisions(): Decisions
	return {
		granted = Enum.ProductPurchaseDecision.PurchaseGranted,
		notProcessed = Enum.ProductPurchaseDecision.NotProcessedYet,
	}
end

--[=[
	A ProcessReceipt callback granting developer products to profiles of `store`. Assign it to
	MarketplaceService.ProcessReceipt. Yields while saving

	@within Geode
	@param store ProfileStore
	@param handlers { [number]: Handler } -- keyed by product id
	@param options ReceiptOptions?
	@return (info: ReceiptInfo) -> ProductPurchaseDecision

	```lua
	MarketplaceService.ProcessReceipt = Geode.receipts(PlayerData.store, {
		[123456] = function(tx)
			tx:increment("coins", 1000)
		end,
	})
	```
]=]
function Receipts.build(
	store: ProfileStore.ProfileStore,
	handlers: { [number]: Handler },
	options: Options?
): (info: ReceiptInfo) -> unknown
	local report = options and options.reportError or function(message: string)
		warn(message)
	end
	local decisions: Decisions? = options and options.decisions

	return function(info: ReceiptInfo): unknown
		local decide = decisions or liveDecisions()
		local purchaseId = tostring(info.PurchaseId)
		local profile = store:get(store:keyForUser(info.PlayerId))
		if profile == nil or not profile:isActive() then
			return decide.notProcessed
		end

		if not profile:hasReceipt(purchaseId) then
			local handler = handlers[info.ProductId]
			if handler == nil then
				report(
					`no handler for product {info.ProductId}, purchase {purchaseId} left pending`
				)
				return decide.notProcessed
			end
			local result = profile:transact(function(tx)
				handler(tx, info)
			end, { source = "system", note = `purchase {purchaseId}` })
			if not result.ok then
				report(`purchase {purchaseId} wasn't granted: {result.error.message}`)
				return decide.notProcessed
			end
			-- No yield since the commit, so any save sees the grant and its receipt together
			profile:recordReceipt(purchaseId)
		end

		if profile:isSaved() then
			return decide.granted
		end
		local saved = profile:save()
		return if saved.ok then decide.granted else decide.notProcessed
	end
end

return Receipts
