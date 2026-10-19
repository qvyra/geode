--!strict

local Proxy = require("./Proxy")
local Spec = require("../_lib/Spec")

-- Just enough of DataStoreService for the proxy: stores remember the name and scope they were
-- opened with and answer from a table
local function fakeService()
	local opened: { { name: string, scope: string?, args: number } } = {}
	local data: { [string]: unknown } = {}
	local service = {}
	function service.GetDataStore(_self: any, name: string, scope: string?, ...: any): any
		table.insert(opened, { name = name, scope = scope, args = 1 + select("#", ...) })
		local store = {}
		function store.GetAsync(_store: any, key: string): unknown
			return data[key]
		end
		function store.UpdateAsync(
			_store: any,
			key: string,
			transform: (unknown) -> unknown
		): unknown
			data[key] = transform(data[key])
			return data[key]
		end
		function store.SetAsync(_store: any, key: string)
			error(`503: throttled writing {key}`, 0)
		end
		return store
	end
	function service.GetRequestBudgetForRequestType(_self: any, _requestType: unknown): number
		return 42
	end
	return service, opened
end

local function clock(): () -> number
	local now = 0
	return function(): number
		now += 1
		return now
	end
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("bench DataStore proxy", function()
		it("forwards calls and logs each one", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			local store = proxy.service:GetDataStore("Bench_A")
			store:UpdateAsync("k", function(current: number?)
				return (current or 0) + 5
			end)
			expect(store:GetAsync("k")).toBe(5)
			expect(#proxy.calls).toBe(2)
			expect(proxy.calls[1].method).toBe("UpdateAsync")
			expect(proxy.calls[1].key).toBe("k")
			expect(proxy.calls[1].ok).toBe(true)
			expect(proxy.calls[2].method).toBe("GetAsync")
		end)

		it("refuses any other DataStore name", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			expect(function()
				proxy.service:GetDataStore("____PS")
			end).toThrow("isn't allowed")
			expect(function()
				proxy.service:GetOrderedDataStore("Bench_A")
			end).toThrow("isn't allowed")
		end)

		it("refuses store members it doesn't forward", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			local store = proxy.service:GetDataStore("Bench_A")
			expect(function()
				return store.OnUpdate
			end).toThrow("isn't allowed")
		end)

		it("moves an alias under a scope of the allowed name", function()
			local real, opened = fakeService()
			local proxy = Proxy.new({
				real = real,
				allowed = "Bench_A",
				clock = clock(),
				aliases = { Bench_A_mailbox = { scope = "mailbox" } },
			})
			proxy.service:GetDataStore("Bench_A_mailbox", "global")
			proxy.service:GetDataStore("Bench_A_mailbox", "run")
			expect(opened[1].name).toBe("Bench_A")
			expect(opened[1].scope).toBe("mailbox")
			expect(opened[2].scope).toBe("mailbox-run")
		end)

		it("keeps the arguments the library passed", function()
			local real, opened = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			proxy.service:GetDataStore("Bench_A")
			proxy.service:GetDataStore("Bench_A", nil, "options")
			expect(opened[1].args).toBe(1)
			expect(opened[2].args).toBe(2)
		end)

		it("logs a failed call and rethrows its message unchanged", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			local store = proxy.service:GetDataStore("Bench_A")
			local ok, err = pcall(function()
				store:SetAsync("k", 1)
			end)
			expect(ok).toBe(false)
			expect(err).toBe("503: throttled writing k")
			expect(proxy.calls[1].ok).toBe(false)
			expect(proxy.calls[1].err).toBe("503: throttled writing k")
		end)

		it("passes budget questions through without logging them", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			expect(proxy.service:GetRequestBudgetForRequestType("x")).toBe(42)
			expect(#proxy.calls).toBe(0)
		end)

		it("finds the calls made since a moment, for one key", function()
			local real = fakeService()
			local proxy = Proxy.new({ real = real, allowed = "Bench_A", clock = clock() })
			local store = proxy.service:GetDataStore("Bench_A")
			store:GetAsync("a")
			store:GetAsync("b")
			store:GetAsync("a")
			expect(#Proxy.since(proxy, 2, "a")).toBe(1)
			expect(#Proxy.since(proxy, 0)).toBe(3)
		end)
	end)
end
