local CONFIG = {
	maxScripts = 1500,
	maxEnumerated = 100000,
	maxSourceBytes = 1024 * 1024,
	maxFileBytes = 32 * 1024 * 1024,
	decompileSeconds = 15,
	totalSeconds = 180,
}

for name, fn in pairs({ writefile = writefile or false, appendfile = appendfile or false, decompile = decompile or false }) do
	assert(type(fn) == "function", "Missing executor function: " .. name)
end

local httpService = game:GetService("HttpService")
local coreGui = game:FindFirstChild("CoreGui")
local corePackages = game:FindFirstChild("CorePackages")
local fileName = "AR2Dump_" .. tostring(game.PlaceId) .. "_" .. httpService:GenerateGUID(false) .. ".txt"
local records, seen = {}, {}
local bytesWritten = 0
local outputFull = false
local inventoryLimited = false

writefile(fileName, "")

-- Reserve space for the final status even if a source reaches the output limit.
local function emit(text)
	local chunk = text .. "\n"
	if bytesWritten + #chunk > CONFIG.maxFileBytes - 4096 then
		outputFull = true
		return false
	end
	local ok, err = pcall(appendfile, fileName, chunk)
	assert(ok, "Could not append to " .. fileName .. ": " .. tostring(err))
	bytesWritten = bytesWritten + #chunk
	return true
end

local function addScript(object, provider)
	if typeof(object) ~= "Instance" then return end
	if seen[object] then return end
	seen[object] = true
	local ok, record = pcall(function()
		if coreGui and object:IsDescendantOf(coreGui) then return nil end
		if corePackages and object:IsDescendantOf(corePackages) then return nil end
		local isClient = object:IsA("LocalScript") or object:IsA("ModuleScript")
		if object:IsA("Script") then
			isClient = object.RunContext == Enum.RunContext.Client
		end
		if not isClient then return nil end
		return {
			object = object,
			class = object.ClassName,
			path = object:GetFullName():sub(1, 4096),
			nilParent = object.Parent == nil,
			provider = provider,
		}
	end)
	if ok and record then
		if #records >= CONFIG.maxScripts then
			inventoryLimited = true
		else
			table.insert(records, record)
		end
	end
end

local function collect(name, fn)
	if type(fn) ~= "function" then
		emit("ENUMERATOR " .. name .. ": unavailable")
		return
	end
	local ok, objects = pcall(fn)
	if not ok or type(objects) ~= "table" then
		emit("ENUMERATOR " .. name .. ": failed: " .. tostring(objects):sub(1, 2048))
		return
	end
	local visited = 0
	for _, object in pairs(objects) do
		visited = visited + 1
		if visited > CONFIG.maxEnumerated then
			inventoryLimited = true
			break
		end
		addScript(object, name)
		if visited % 250 == 0 then task.wait() end
	end
	emit(string.format("ENUMERATOR %s: visited=%d", name, math.min(visited, CONFIG.maxEnumerated)))
end

-- This deadline works while the scheduler runs; it cannot interrupt a blocking native call.
local function getSource(object, seconds)
	local done, succeeded, result = false, false, nil
	local started = os.clock()
	local worker = task.defer(function()
		succeeded, result = pcall(decompile, object)
		done = true
	end)
	while not done and os.clock() - started < seconds do task.wait(0.05) end
	if not done then
		pcall(task.cancel, worker)
		return "timeout", "Stopped after the deadline; worker cancellation is best effort."
	end
	if not succeeded then return "error", tostring(result):sub(1, 2048) end
	if type(result) ~= "string" or result:match("^%s*$") then
		return "error", "Decompiler returned no source text."
	end
	return "returned", result
end

local function run()
	emit("AR2 CLIENT SCRIPT SNAPSHOT")
	emit(string.format("PlaceId=%s GameId=%s PlaceVersion=%s", tostring(game.PlaceId), tostring(game.GameId), tostring(game.PlaceVersion)))
	emit("CreatedUTC=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
	emit("Decompiled output is reconstructed text and may include decompiler errors.")
	emit("Coverage is limited to scripts exposed to this client at capture time.\n")
	emit("CoreGui and CorePackages descendants are excluded from this snapshot.")
	collect("getscripts", getscripts)
	collect("getrunningscripts", getrunningscripts)
	collect("getloadedmodules", getloadedmodules)
	collect("getnilinstances", getnilinstances)
	if #records == 0 then
		collect("GetDescendants fallback", function() return game:GetDescendants() end)
	end
	table.sort(records, function(a, b)
		if a.path == b.path then return a.class < b.class end
		return a.path < b.path
	end)

	-- Persist paths before decompilation so partial runs remain inspectable.
	emit(string.format("\nINVENTORY count=%d limited=%s", #records, tostring(inventoryLimited)))
	for index, record in ipairs(records) do
		if not emit(string.format("[%04d] %s path=%q nilParent=%s via=%s", index, record.class, record.path, tostring(record.nilParent), record.provider)) then break end
	end
	print("Script inventory saved: " .. fileName .. " (" .. #records .. " scripts)")

	local started = os.clock()
	local returned, errors, attempted = 0, 0, 0
	local stopReason = #records == 0 and "no_scripts_found" or "all_records_attempted"
	for index, record in ipairs(records) do
		if outputFull then stopReason = "file_size_limit"; break end
		local remaining = CONFIG.totalSeconds - (os.clock() - started)
		if remaining <= 0 then stopReason = "total_time_limit"; break end
		if not emit(string.format("\nBEGIN SCRIPT %04d path=%q", index, record.path)) then
			stopReason = "file_size_limit"
			break
		end
		attempted = attempted + 1
		local status, source = getSource(record.object, math.min(CONFIG.decompileSeconds, remaining))
		local sourceBytes = #source
		local truncated = sourceBytes > CONFIG.maxSourceBytes
		local body = source:sub(1, CONFIG.maxSourceBytes)
		local chunk = string.format("STATUS=%s returnedBytes=%d truncated=%s\n%s\nEND SCRIPT %04d", status, sourceBytes, tostring(truncated), body, index)
		if not emit(chunk) then stopReason = "file_size_limit"; break end
		if status == "returned" then returned = returned + 1 else errors = errors + 1 end
		if status == "timeout" then stopReason = "decompiler_timeout"; break end
		if index % 25 == 0 then print(string.format("Dump progress: %d/%d", index, #records)) end
		task.wait()
	end
	local summary = string.format("\nSUMMARY inventory=%d attempted=%d returned=%d errors=%d inventoryLimited=%s stop=%s\n", #records, attempted, returned, errors, tostring(inventoryLimited), stopReason)
	appendfile(fileName, summary)
	print(summary .. "Saved in the executor workspace: " .. fileName)
end

local ok, err = xpcall(run, function(message) return debug.traceback(tostring(message), 2) end)
if not ok then
	pcall(appendfile, fileName, "\nFATAL: " .. tostring(err):sub(1, 2048) .. "\n")
	warn("Dump stopped; partial output may exist at " .. fileName .. "\n" .. tostring(err))
end
