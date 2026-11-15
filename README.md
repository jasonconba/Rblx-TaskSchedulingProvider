# Code Sample: TaskSchedulingProvider

The task scheduling provider, not to be confused with Roblox's native task scheduler, is a
system that allows native Roblox event callbacks to be ran in a controlled, predictive, and
deterministic manner.

## Background

Like many other games, we rely heavily on the pub/sub pattern and event-driven programming to
power our game. It is very easy to work with, and when combined with certain programming patterns
like functional, procedural, and object-oriented, it becomes very capable.

However, at scale with complex systems, maintenance and complexity cost aside, we run into a
wall of predictability problem.

### The Problem

Natively, Roblox's luau scheduler is non-deterministic, meaning task execution order is very
arbitrary. For some systems, this is not a problem; but for others where one system relies on
the output of the other, this leads to a lot of code smell.

Suppose we have a newspaper delivery system. In a local town, a really popular newspaper must
manage its subscribers and deliver newspapers to them. The newspaper organization hires a delivery
boy to run the deliveries for them.

Normally, we would write code like this:

```luau
-- ResidentF.luau
NewspaperDelivered.Event:Connect(function()
    DeliveryBoy:Visit("House F")
end)

-- ResidentG.luau
NewspaperDelivered.Event:Connect(function()
    DeliveryBoy:Visit("House G")
end)

-- ResidentH.luau
NewspaperDelivered.Event:Connect(function()
    DeliveryBoy:Visit("House H")
end)

-- We expect House F -> House G -> House H
-- We might get House H -> House F -> House G, or any other combination of the three.
```

To guarantee execution order, we commonly introduce a centralized manager responsible for
invoking each operation. It's the shortest path to solving the problem, after all. And, it
works!

```luau
-- DeliveryManager.luau

function DeliveryManager:DeliverNewspapers()
    DeliveryBoy:Visit("House F")
    DeliveryBoy:Visit("House G")
    DeliveryBoy:Visit("House H")
end

NewspaperDelivered.Event:Connect(function()
    DeliveryManager:DeliverNewspapers()
end)
```

The delivery manager now determines the delivery route, sweet! But, remember when I said
the delivery manager is only responsible for ensuring newspapers get delivered? Well, the
manager is now micro-managing the boy, and the boy is very unhappy about it!

Beyond that, we now have tight coupling between the delivery manager and the delivery boy.
Suppose a new resident subscribes, whose house lies between F and G.

```luau
-- ResidentF2.luau
function ResidentF2:Subscribe()
    NewsOrganization:AddSubscriber("House F2")
end
```

We now have to modify the deliver manager:

```luau
-- DeliveryManager.luau

function DeliveryManager:DeliverNewspapers()
    DeliveryBoy:Visit("House F")
    DeliveryBoy:Visit("House F2") -- New dependency
    DeliveryBoy:Visit("House G")
    DeliveryBoy:Visit("House H")
end
```

And worse, if a resident has special requirements:

```luau
-- ResidentG.luau

function ResidentG:CanReceiveNewspaper()
    return not self.IsOnVacation
end
```

The manager may begin accumulating resident-specific logic:

```luau
-- DeliveryManager.luau

function DeliveryManager:DeliverNewspapers()
    DeliveryBoy:Visit("House F")

    if ResidentG:CanReceiveNewspaper() then
        DeliveryBoy:Visit("House G")
    end

    DeliveryBoy:Visit("House H")
end
```

### Why not ECS?

Entity component system has long rooted its way into game development for a good reason. When
needing to manage a lot of complex systems, having them represented in data-driven components, and
having individual systems operating on those components/architects can be a very good way to manage
the complexity.

ECS is not a silver bullet, however. It still suffers from the same problem of spaghetti code, and
most importantly for my team, there is both a lot of native support for systems like this (given Luau
is a dynamically typed language), and there's a lot of onboarding friction & cost overhead for both
our incoming and current developers——of which cost being one of the biggest factors for us.

## The Solution

### Mindset

Faced with this problem, I wanted to resolve it using an ECS-driven mindset (where systems are decoupled and operate on data-driven components), but with the convenience of a more tranditional
object-oriented and functional approach. This not only helps me write maintainable code, but also
helps onboarding the rest of the team, and everyone who will be working on the project in the future.

To do so, I wanted to create a system where I can explicitly define the execution order of event
callbacks, without the hassle of needing to create a centralized manager nor having to understand
the inner workings of the system. I believe that there should be a distinction between **orchestration** and **implementation**.

As such, I wanted to separate three responsibilities:

1. Task lifecycle: **Who** initiates and manages an operation?
2. Execution ordering: **When** should each operation execute?
3. Business logic: **What** should each operation actually do?

### Applying to the Problem

The manager, under this system, is responsible for the delivery lifecycle. They do not need to know
any implementation details about the route or individual residents whatsoever. **They just care about
the fact that newspapers are delivered.**

```luau
-- DeliveryManager.luau
local Provider = require(TaskSchedulingProvider)

const PRIORITIES = {
    VeryImportant = 1,
    Important = 100,
    CanProbablyWait = 1000,
}

local DeliveryTask = Provider:CreateTask("NewspaperDelivery", {
    "BeforeDelivery",
    "Deliver",
    "PostDelivery",
})

function DeliveryManager:StartDelivery()
    DeliveryTask:Run()
end
```

The subscription system independently binds itself to the appropriate sequence.

```luau
local DeliveryTask = Provider:WaitForTaskCreation("NewspaperDelivery")

DeliveryTask:BindFunctionToSequence("BeforeDelivery", function()
    DeliveryState.Addresses = SubscriptionSystem:GetActiveSubscribers()
end, PRIORITIES.VeryImportant)
```

The route planning system does its own planning.

```luau
-- RoutePlanningSystem.luau
local DeliveryTask = Provider:WaitForTaskCreation("NewspaperDelivery")

function RoutePlanningSystem:CalculateRoute(addresses) :: {string}
    -- Some complex route planning algorithm that compares
    -- address by alphabetical order, then by vector 3
    -- distance from some arbitrary point, and then by some
    -- other arbitrary factor.
    return addresses
end

DeliveryTask:BindFunctionToSequence("BeforeDelivery", function()
    DeliveryState.Route = RoutePlanningSystem:CalculateRoute(
        DeliveryState.Addresses
    )
end, PRIORITIES.Important)
```

And the delivery boy just deals with delivery.

```luau
-- DeliveryBoy.luau
local DeliveryTask = Provider:WaitForTaskCreation("NewspaperDelivery")

DeliveryTask:BindFunctionToSequence("Deliver", function()
    DeliveryBoy:ExecuteRoute(DeliveryState.Route)
end, PRIORITIES.VeryImportant)
```

And finally, the verification system checks to ensure that all newspapers were delivered.

```luau
-- VerificationSystem.luau
local DeliveryTask = Provider:WaitForTaskCreation("NewspaperDelivery")

DeliveryTask:BindFunctionToSequence("PostDelivery", function()
    DeliveryVerificationSystem:CheckDeliveries()
end, PRIORITIES.VeryImportant)
```

Now, suppose we have a new resident that really likes the newspaper, and starts subscribing to it.
All we need to do is this:

```luau
-- ResidentF2.luau

SubscriptionSystem:AddSubscriber({
    Address = "House F2",
    Position = Vector3.new(1, 2, 3),
})
```

### What's Different?

In this system, instead of having delivery manager do _everything_, we broke their responsibilities
into smaller systems that are responsible for their own business logic. To ensure we don't have a
"God object" nor a cascading-coding pattern (A calls B, B calls C, etc.), we have a task scheduling
provider that allows us to autonomously figure that out for us.

This is essentially sugar for:

```luau
-- DeliveryManager.luau
function DeliveryManager:StartDelivery()
    local addresses = SubscriptionSystem:GetActiveSubscribers()
    local route = RoutePlanningSystem:CalculateRoute(addresses)
    DeliveryBoy:ExecuteRoute(route)
    DeliveryVerificationSystem:CheckDeliveries()
end
```

#### But this is an over-engineered solution, right?

Yes, but it's also scalable. Over-engineering is not determined by how complex a solution is,
but rather the implementation introduces more complexity than the problem warrants. In this case,
it is acceptable.

For anything small, this is an overkill. Sure, if the delivery manager manages three addresses, we
probably don't need the headache of doing all this. The aforementioned coding solution is perfectly
fine, why fix what's broken?

But we are in a world where this is not the case.

If there's one thing making software has taught us, it's that software is never static. What's
hard-coded today and seems "convenient" will quickly turn into a nightmare when new requirements and
features roll in left and right. Suddenly, the delivery manager is now responsible for 100 addresses,
the route planning system is now responsible for calculating the most efficient route, the
delivery boy is now responsible for delivering to 100 addresses, and the verification system is
now responsible for checking if all 100 addresses received their newspapers...

I can maintain all bits and pieces of that system, sure. What if one day I am no longer available
to maintain it?

Therefore, the appropriate comparison is not “is making a scheduler more complicated than just
calling three functions?” Well no shit, it obviously is. The more appropriate comparision, if
I may, would be "would I rather want granular control over how much salt, pepper, garlic powder,
and paprika I put in my food across different dishes, or do I just chug everything in and hope for
the best?"

#### It's obviously without its own flaws

- If a function is bound to a sequence, where that function is ran through a coroutine (i.e. `task.spawn`), we now break the granularity control of the system.
- Systems needing to bind to the sequence must now know the name of the task and the sequence, and this will upset the purists where we are now introducing coupling between systems. There is definitely a real risk of this being a problem.
- The system is currently designed where one failed function will not halt the entire sequence, and in-turn, the task(s). For independently managed systems, this is not a problem. But for systems where one relies on the output of the other, this will create cascading failures, often in a hidden manner.
- This system does not offer any performance benefits, and in fact, will introduce a small overhead. When used properly, the overhead is negligible. However, if used improperly, or that there's an over-reliance on it, this will create a bottleneck in the system. Thus, I often remind our team and myself that this is meant to solve a very specific problem, rather than a catch-all solution.

### Application

This started more-so as a proof of concept as the then-technical lead of my team and I tried to
figure out a bug in a game. As a part of our repro, we inadvertently raised the question: why are we
just letting the luau scheduler freeballing it?

I presented this proof of concept into a framework around May/June 2026, and it was approved in a
pull request. After this being sat on stale for quite a few months, it's now being used in production
across games that I am currently working on. And, suffice to say, it's working very well.
