--[=[
	@class Sequence

	runs callbacks in ascending numeric priority within one task sequence.
	
	in the context of the task scheduling provider, a sequence is a collection of callbacks 
	that are exec'd in a specific order within a task. the order of execution is determined by 
	the numeric priority assigned to each callback.

	note that in documentation, the terms "phase" and "sequence" are used interchangeably.
]=]
local Sequence = {}
Sequence.__index = Sequence

type Data = {
	name: string,
	order: number,
	functions: { [number]: (...any) -> any? },
}
export type Sequence = typeof(setmetatable({} :: Data, Sequence))

--[=[
	creates a named task sequence.

	@param string -- sequence name.
	@param number -- sequence order within its task.
	@return Sequence
]=]
function Sequence.new(name: string, order: number): Sequence
	assert(typeof(name) == "string", "Sequence name must be a string.")

	return setmetatable({ name = name, order = order, functions = {} } :: Data, Sequence)
end

function Sequence:GetSelfOrder(): number
	return self.order
end

--[=[
	registers a callback at a numeric priority. **a lower number = a higher priority.**
	
	note that:
	- if the specified priority is already occupied, this new callback is moved to the next 
	available position.
	- if no priority is specified, the callback is assigned the current lowest available priority.

	@param (...any) -> any? -- callback to run during this sequence.
	@param number? -- if omitted, the callback is assigned the current lowest available priority.
]=]
function Sequence:Bind(func: (...any) -> any?, executionOrder: number?): ()
	assert(typeof(func) == "function", "Function must be a function.")
	local order = executionOrder
	if not order then
		order = 1
		for priority in pairs(self.functions) do
			order = math.max(order, priority + 1)
		end
	end

	assert(order >= 1 and order % 1 == 0, "Execution order must be a positive integer.")
	local callback: ((...any) -> any?)? = func

	while callback do
		local displaced = self.functions[order]
		self.functions[order] = callback
		callback = displaced
		order += 1
	end
end

--[=[
	@yields
	runs callbacks from highest to lowest priority (lowest number to highest number) in the sequence.

	if a callback errors, the error is logged and execution continues with the next callback.

	### WARNING
	- an error in a callback will not stop the execution of subsequent callbacks. however, it may affect subsequent callbacks
	if the they depend on the state of the failed one.
	- callbacks may yield, but **is strongly discouraged**.
	- callbacks must resolve as quickly as possible to prevent bottlenecking.

	@param ...any -- arguments passed to every callback.
]=]
function Sequence:Execute(...: any): ()
	local orders = {}
	for order in pairs(self.functions) do
		table.insert(orders, order)
	end

	table.sort(orders)

	for _, order in ipairs(orders) do
		local func = self.functions[order]

		debug.profilebegin(`Sequence_{self.name}_Function_{tostring(func)}`)
		local success, err = pcall(func, ...)
		debug.profileend()

		if not success then
			warn("Error executing function in sequence " .. self.name)
			warn(debug.traceback(err))
		end
	end
end

return Sequence
