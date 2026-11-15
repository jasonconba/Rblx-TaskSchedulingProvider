local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SomeDirectory = ReplicatedStorage.SomeDirectory

const Vendor = SomeDirectory.Vendor
local Promise = require(Vendor.Promise)
local Signal = require(Vendor.Signal)

local Task = require(script.Task)

--[=[
	@class TaskSchedulingProvider

    not to be confused with Roblox's native task scheduler, <this system>'s task scheduling provider provides 
    a way to create an execution order for tasks to execute in a sequential, controlled, and predictable
    manner.

    task scheduling provider merely provides the sets of tasks and sequences, and does not run them. a separate system should
    create these tasks and manage its lifecycle.

    ### WARNING

    a task should be initialized by a system that is responsible for managing its lifecycle. such system should be **the
    only source** where sequences can be triggered. other codes may **bind** to the task/sequence, but should not actively tamper
    with its lifecycle.
]=]
local TaskSchedulingProvider = {
	Name = "TaskSchedulingProvider",

	Signals = {

		_taskCreated = Signal.new(),
	},
	Tasks = {} :: { [string]: Task },
}
type Task = typeof(Task.new("", {}))
type Connection = typeof(Signal.new():Connect(function() end))

--[=[
	gets a task by its name.
	@param string -- task identifier.

    @return Task? -- the task with the given name, or nil if it does not exist
]=]
function TaskSchedulingProvider:GetTask(taskName: string): Task?
	assert(typeof(taskName) == "string", "Task name must be a string.")

	local taskObj = TaskSchedulingProvider.Tasks[taskName]

	if not taskObj then
		warn("Task with name " .. taskName .. " does not exist.")
		return nil
	end
	return taskObj
end

--[=[
    creates a new task with the given name and sequences

	### WARNING
	THE TASK NAME MUST BE UNIQUE. CREATING A TASK WITH AN EXISTING NAME WILL THROW AN ERROR.

	IF YOU SUSPECT THAT A TASK WITH THE GIVEN NAME MAY ALREADY EXIST, USE `GetTask` TO CHECK FOR EXISTENCE,
	AND/OR WRAP `CreateTask` IN A `pcall`.

	@param string -- unique task name.
	@param {string} -- phase names in execution order.
	@return Task
]=]
function TaskSchedulingProvider:CreateTask(taskName: string, sequences: { string }): Task
	assert(typeof(taskName) == "string", "Task name must be a string.")

	if TaskSchedulingProvider.Tasks[taskName] then
		error("Task with name " .. taskName .. " already exists.")
	end

	local newTask = Task.new(taskName, sequences)
	TaskSchedulingProvider.Tasks[taskName] = newTask
	TaskSchedulingProvider.Signals._taskCreated:Fire(newTask)

	return newTask
end

function TaskSchedulingProvider:DestroyTask(taskName: string): ()
	assert(typeof(taskName) == "string", "Task name must be a string.")

	local task = TaskSchedulingProvider:GetTask(taskName)
	if not task then
		warn("Task with name " .. taskName .. " does not exist.")
		return
	end

	task:Destroy()
	TaskSchedulingProvider.Tasks[taskName] = nil
end

--[=[
	@yields

	waits for a task to be created with the given name. 
	
	if it exists, it returns immediately.
	otherwise, it waits until the task is created or the optional timeout is reached.

	@param string -- task identifier.
	@param number? -- maximum seconds to wait, defaults to nil (indefinite wait)
	@return Task? -- the task with the given name, or nil if it does not exist and the timeout was reached.
]=]
function TaskSchedulingProvider:WaitForTaskCreation(taskName: string, timeout: number?): Task?
	if TaskSchedulingProvider.Tasks[taskName] then
		return TaskSchedulingProvider.Tasks[taskName]
	end

	local waitingForTask = Promise.new(function(resolve, reject)
		local connection: Connection?
		connection = TaskSchedulingProvider.Signals._taskCreated:Connect(function(createdTask)
			if createdTask.name == taskName then
				if connection then
					connection:Disconnect()
				end
				resolve(createdTask)
			end
		end)

		if typeof(timeout) == "number" and timeout > 0 then
			task.delay(timeout, function()
				if connection then
					connection:Disconnect()
				end
				reject("Timeout waiting for task creation for task " .. taskName)
			end)
		end
	end)

	local success, taskObj = waitingForTask:await()

	if success then
		return taskObj
	end

	warn(`[TaskSchedulingProvider] Failed to wait for task creation for task {taskName}: {taskObj}`)
	return nil
end

return TaskSchedulingProvider
