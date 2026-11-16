--!strict

-- `lune run benchcpu` prints Geode's edit timings as JSON, see tests/bench/Cpu.luau. The path is
-- held in a variable so the Lune type check here doesn't follow it into src, which is checked
-- against Roblox's types with the tests
local process = require("@lune/process")
local serde = require("@lune/serde")

local CPU_PATH = "../tests/bench/Cpu"
local Cpu = (require :: any)(CPU_PATH)

local report = Cpu.run(os.clock)
report.lune = _VERSION
report.os = process.os
report.arch = process.arch
print(serde.encode("json", report))
