local ReplicatedStorage = game:GetService("ReplicatedStorage")

const SomeDirectory = ReplicatedStorage.SomeDirectory
const Vendor = SomeDirectory.Vendor
local Signal = require(Vendor.Signal)

local SequenceModule = require(script.Parent.Sequence)

--[=[
	@class Task

	in the context of the task scheduling provider, a task is a collection of sequences that  
	contains callbacks exec'd in a specific order. a callback is generally bound to a sequence.

	a task may contain multiple sequences. 

	::: info :::
	### info
	- a task may depend on other tasks to complete before it can run. this behavior may be useful in very specific
	scenarios. 
	- if the dependent task yields, **you should work to avoid depending on it entirely**.
	- sequences within tasks should complete **as quickly as possible**. yielding is permitted, but should be done very sparringly.
	- be careful not to introduce circular dependencies between tasks, as this will lead to deadlocks.

	note that in documentation, the terms "phase" and "sequence" are used interchangeably.
]=]
local Task = {}
Task.__index = Task

type Sequence = SequenceModule.Sequence
type Signal = typeof(Signal.new())
type SignalConnection = typeof(Signal.new():Connect(function() end))
type Trigger = RBXScriptSignal | Signal
type Data = {
	name: string,
	sequences: { [number]: Sequence },
	signals: {
		TaskStarted: Signal,
		TaskCompleted: Signal,
	},
	dependencies: { [string]: Task },
	trigger: Trigger?,
	_triggerConnection: (SignalConnection | RBXScriptConnection)?,
	currentlyRunning: boolean,
}
export type Task = typeof(setmetatable({} :: Data, Task))

--[=[
	creates a new task. note that:
	- the task name should be unique. creating a task with an existing name won't throw an error, but may lead to unexpected behavior.
	- sequence names may duplicate in the same task or across tasks. however, you should always name them uniquely.

	@param string -- task identifier.
	@param {string} -- sequence names in execution order.
	@return Task
]=]
function Task.new(name: string, sequences: { string }): Task
	assert(typeof(name) == "string", "Task name must be a string.")
	assert(typeof(sequences) == "table", "Task sequences must be a table.")

	local self = setmetatable(
		{
			name = name,
			sequences = {},
			signals = { TaskStarted = Signal.new(), TaskCompleted = Signal.new() },
			dependencies = {},
			currentlyRunning = false,
		} :: Data,
		Task
	)

	for index, sequenceName in ipairs(sequences) do
		assert(typeof(sequenceName) == "string", "Sequence name must be a string.")
		self.sequences[index] = SequenceModule.new(sequenceName, index)
	end

	return self :: Task
end

--[=[
    @return { string } -- a list of sequence names.
]=]
function Task:GetListOfSequences(): { string }
	local sequenceNames = {}
	for _, sequence: Sequence in ipairs(self.sequences) do
		table.insert(sequenceNames, sequence.name)
	end
	return sequenceNames
end

--[=[
	finds a phase by name.

	@param string -- sequence id/name
	@return Sequence? -- sequence, or nil if not found
]=]
function Task:FindChildSequence(sequenceName: string): Sequence?
	assert(typeof(sequenceName) == "string", "Sequence name must be a string.")

	for _, sequence: Sequence in ipairs(self.sequences) do
		if sequence.name == sequenceName then
			return sequence
		end
	end

	return nil
end

--[=[
	registers a callback within a named phase. if it does not exist, it throws an error.

	if you are not confident that the sequence exists, defensively check if the sequence exists first,
	and/or wrap this in a `pcall`.

	@param string -- sequence name.
	@param (...any) -> any? -- callback
	@param number? -- priority in sequence, where lower values run first. if nil, the callback is assigned to run at the current very end of the sequence.
]=]
function Task:BindFunctionToSequence(sequenceName: string, func: (...any) -> any?, executionOrder: number?): ()
	assert(typeof(sequenceName) == "string", "Sequence name must be a string.")
	assert(typeof(func) == "function", "Function must be a function.")

	local sequence = self:FindChildSequence(sequenceName) :: Sequence?
	if not sequence then
		error("Sequence with order " .. tostring(executionOrder or 1) .. " does not exist in task " .. self.name)
	end

	sequence:Bind(func, executionOrder)
end

--[=[
	@yields

	executes the task, running all sequences in the specified order.

	if the task is waiting for a dependency task to complete, it will yield until that task is completed before starting.

	@param ...any -- Arguments passed to every sequence callback.
]=]
function Task:Run(...: any): ()
	if self.currentlyRunning then
		warn(`[Task] Task {self.name} is already running. Ignoring Start call.`)
		return
	end

	if self.dependencies and next(self.dependencies) then
		for _, dependencyTask: Task in pairs(self.dependencies) do
			dependencyTask:WaitForCompletion()
		end
	end

	self.currentlyRunning = true
	local args = { ... }
	self.signals.TaskStarted:Fire()

	for _, sequence: Sequence in ipairs(self.sequences) do
		sequence:Execute(table.unpack(args))
	end

	self.currentlyRunning = false
	self.signals.TaskCompleted:Fire()
end

--[=[
	@yields

	waits for the task to complete. If the task is not currently running, this will return immediately.
]=]
function Task:WaitForCompletion(): ()
	if self.currentlyRunning then
		self.signals.TaskCompleted:Wait()
	end
end

--[=[
	makes future runs wait for another task if that task is currently running.

	@param Task -- Task whose active run must finish first.
]=]
function Task:SetDependencyOnTaskCompletion(otherTask: Task): ()
	assert(
		typeof(otherTask) == "table" and otherTask.signals and otherTask.signals.TaskCompleted,
		"otherTask must be a valid Task instance."
	)

	self.dependencies[otherTask.name] = otherTask
end

--[=[
	connects a signal to task execution.
	
	**note that this overwrites its previous trigger connection.**

	@param Trigger -- signal that starts this task.
]=]
function Task:SetTrigger(trigger: Trigger): ()
	if self._triggerConnection then
		self._triggerConnection:Disconnect()
	end
	self.trigger = trigger

	local function run(...: any)
		self:Run(...)
	end
	if typeof(trigger) == "RBXScriptSignal" then
		self._triggerConnection = trigger:Connect(run)
	else
		self._triggerConnection = (trigger :: Signal):Connect(run)
	end
end

function Task:Destroy(): ()
	if self._triggerConnection then
		self._triggerConnection:Disconnect()
		self._triggerConnection = nil
	end
	self.trigger = nil
	self.signals.TaskStarted:Destroy()
	self.signals.TaskCompleted:Destroy()
end

return Task
