export sweep, eta, status, progress, abort!, prune!, jobs, result
export reconstruct, @dataserver
using Base.Cartesian, JLD
using AxisArrays
using MacroTools
import AxisArrays: axes
import Base.Cartesian.inlineanonymous
import Base: show, isless, getindex, push!, length, eta
import DataStructures: PriorityQueue, enqueue!, dequeue!, peek

# Priorities for sweep jobs
const NEVER = -1
const LOW = 0
const NORMAL = 5
const HIGH = 10

"""
    macro handler(expr)
Macro for handling the response from remote calls via JuliaWebAPI.
"""
macro handler(expr)
    return quote
        response = $(esc(expr))
        c = response["code"]
        c != 200 && error("remote call failed with HTTP response code: ", string(c))
        response["data"]
    end
end

"""
    macro dataserver(expr)
Macro for interfacing painlessly with the running ICDataServer.

- Any function call in `expr` will be replaced by a corresponding remote call to the
  ICDataServer, provided that function call has been exposed by ICDataServer's inter-process
  communication API.
- Functions that have not been exposed will be called locally.
- Any arguments to the function calls are evaluated locally.
"""
macro dataserver(expr)
    validapi = @handler apicall(apiinvoker(), "ipcapi")
    esc(MacroTools.postwalk(expr) do x
        if @capture(x, f_(args__))
            f in validapi ? :(InstrumentControl.@handler $(transform_remote(f, args...))) : x
        elseif @capture(x, f_(args__; kwargs__))
            f in validapi ? :(InstrumentControl.@handler $(transform_remote(f, args..., kwargs...))) : x
        else
            return x
        end
    end)
end

"""
    transform_remote(f, args...)
Given symbol `f` and `args...`, construct a remote function call to execute on ICDataServer.
"""
function transform_remote(f, args...)
    return Expr(:call, :(InstrumentControl.apicall),
                Expr(:call, :(InstrumentControl.apiinvoker)), string(f), args...)
end

"""
    mutable struct Sweep
        dep::Response
        indep::Tuple{Tuple{Stimulus, AbstractVector}}
        result::AxisArray
        Sweep(a,b) = new(a,b)
        Sweep(a,b,c) = new(a,b,c)
    end
Object representing a sweep; which will contain information on stimuli sent to
the instruments, information on what kind of response we will be measuring, and
the numerical data obtained from the measurement. `dep` (short for dependent) is
a `Response` that will be measured. `indep` is a tuple of `Stimulus`
objects and the values they will be sourced over. `result` is the result array of
the sweep, which need not be provided at the time the `Sweep` object is created.
"""
mutable struct Sweep
    dep::Response
    indep::Vector{Tuple{Stimulus, AbstractVector}}
    result::AxisArray
    Sweep(a,b) = new(a,b) #inner constructor to create object without initializing result array
    Sweep(a,b,c) = new(a,b,c)
end

@enum SweepStatus Waiting Running Aborted Done

"""
    @enum SweepStatus Waiting Running Aborted Done
Sweep statuses are represented with an enum for performance and code readibility

```jldoctest
julia> InstrumentControl.SweepStatus
Enum InstrumentControl.SweepStatus:
Waiting = 0
Running = 1
Aborted = 2
Done = 3
```
"""
SweepStatus

"""
    mutable struct SweepJob
        sweep::Sweep
        priority::Int
        job_id::Int
        status::Channel{SweepStatus}
        progress::Channel{Float64}
        whensub::DateTime
        username::String
        notifications::Bool
    end
Object representing a "sweep job." While a `Sweep` object has all information
related to the actual measurement, we would like to have some metadata associated
with each `Sweep` oject for the purposes of queueing multiple different sweeps,
automatic scheduling of sweeps in a queue, logging of information, etc. For this
purpose, we create a `SweepJob` type to hold together the sweep and all metadata
associated with it.

A `SweepJob` object holds a [`InstrumentControl.Sweep`](@ref)  `sweep` object.
`priority` is an `Int` from 0 to `typemax(Int)`, inclusive, and is used to
prioritize the next sweep in a queue (with multiple sweeps) to be run. It is
typically one of the following:

- `HIGH == 10`
- `NORMAL == 5`
- `LOW == 0`

`job_id` is used as the reference to the sweep job in the ICDataServer, and in the
jobs queue. When a new sweep is requested, and the corresponding `SweepJob` object
is made, an appropriate job_id is requested from the ICDataServer and is automatically
assigned to the job object. The job is then automatically submitted to the
queue with this `job_id` as it's identifier and handle.

`status` is a channel that holds the status of a job (Waiting,Running,Aborted,Done),
and is used for interstask communcations for operations on jobs such as starting
the job, aborting the job, queueing the job, etc, as well communication with
ICDataServer. For example: a change in status of a job to "Done" or "Aborted"
prompts the job status to be updated in the ICDataServer; or, once a queued sweep is
next in line to be run, the queue changes the sweep job's status from "Waiting"
to "Running", which then automatically prompts the queued sweep to be started.

`progress` is a channel to track the progress of a sweep job; the progress is
calculated as a sweep is run, and the number is put into this channel. The rest
of the fields are metadata for logging purposes: `whensub` is when the `Sweep`
was created, `whenstart` is when the `Sweep` was initially run, `username` is who
submitted the sweep job. If `notifications` is true, status updates are sent out
if possible. These metadata are logged in the database set up by ICDataServer with
which InstrumentControl interacts with
"""
mutable struct SweepJob
    sweep::Sweep
    priority::Int
    job_id::Int
    status::Channel{SweepStatus}
    progress::Channel{Float64}
    whensub::DateTime
    whenstart::DateTime
    username::String
    notifications::Bool
end

"""
    SweepJob(dep, indeps; priority=NORMAL_PRIORITY, username=confd["username"],
        notifications=confd["notifications"])
Initializes a `SweepJob` object given the arguments to initialize it's `Sweep`
object: `dep` and `indeps`. For initialization, the standard priority is "NORMAL",
the standard status is "Waiting." and progress is set to 0.  Until interaction
with the database, `job_id` is set to zero,  and `whenstart` is temporarily
(and inaccurately) set to `whensub`.
"""
function SweepJob(dep, indeps;
        priority=NORMAL, username=confd["username"], notifications=confd["notifications"])
    priority < 0 && error("priority must be greater than zero.")
    dt = now()
    sj = SweepJob(Sweep(dep, [indeps...]), priority, 0, Channel{SweepStatus}(1),
    Channel{Float64}(1), dt, dt, username, notifications)
    put!(sj.status, Waiting)
    put!(sj.progress, 0.0)
    sj
end

"""
    eta(x::SweepJob)
Return the estimated time of completion for sweep job `x`. It estimates this time
by first calculating the amount of time passed from when the job was submitted to
the time the function is called, and then calculating the ETA based on the current
progress of the job and this passed time
"""
function eta(x::SweepJob)
    if status(x) == Waiting # Check if job has started
        error("job has not started yet.")
    end
    # Check if job has finished
    if progress(x) == 1.0
        error("job finished already.")
    end
    interval = Dates.datetime2unix(now())-Dates.datetime2unix(x.whenstart)
    interval /= progress(x)
    Dates.Millisecond(round(interval*1000.0)) + x.whenstart
end

"""
    status(x::SweepJob)
Return the sweep job status.
"""
function status(x::SweepJob)
    isready(x.status) || error("status unavailable.")
    fetch(x.status)
end

"""
    progress(x::SweepJob)
Returns the sweep job progress, a `Float64` between 0 and 1 (inclusive).
"""
function progress(x::SweepJob)
    isready(x.progress) || error("progress unavailable.")
    fetch(x.progress)
end

"""
    result(sj::SweepJob)
Returns the result array of a sweep job `sj`. Throws an error if the result array
has not yet been initialized.
"""
function result(sj::SweepJob)
    if isdefined(sj.sweep, :result)
        sj.sweep.result
    else
        error("result array has not yet been initialized.")
    end
end

"""
    archieve_result(sj::SweepJob)
Save the result array of a 'Sweep' object in the path specified for saving data
by the user. This path is stored in the `confd` dictionary initialized when
InstrumentControl is imported
"""
function archive_result(sj::SweepJob)
    # We assume that the sweep result is an AxisArray.
    # For our archived data we do not save an AxisArray but rather split it
    # apart into pieces that can be reassembled later. We do this to secure
    # future compatibility in case the definition of an AxisArray changes.
    # We can always reconstruct the axis array later.
    if isdefined(sj.sweep, :result)
        axarray = sj.sweep.result
        archive = Dict{String,Any}("data" => axarray.data)
        firstdim = ndims(axarray) - length(sj.sweep.indep)
        for (i,ax) in enumerate(axes(axarray))
            archive["axis$(i)_$(axisname(ax))"] = ax.val
        end
        for (i, (s,a)) in enumerate(sj.sweep.indep)
            archive["desc$(i+firstdim)"] = axislabel(s)
        end

        try
            dpath = joinpath(confd["archivepath"], "$(Date(sj.whensub))")
            if !isdir(dpath)
                mkdir(dpath)
            end
            save(joinpath(dpath, "$(sj.job_id).jld"), archive)
        catch e
            warn("could not save data!")
            rethrow(e)
        end
    end
end

# overloading of isless method for PriorityQueue sorting, the PriorityQueue
# object it uses this function to sort it's keys
function isless(a::SweepJob, b::SweepJob)
    ap, bp = a.priority, b.priority
    isless(ap, bp) ||
        (ap == bp && isless(b.whensub, a.whensub))
end

#overloading of show method for easy display of important job parameters
function show(io::IO, s::SweepJob)
    progstr = @sprintf "%0.2f" progress(s)*100
    progstr *= "%"
    progstr = repeat(" ", 7-length(progstr))*progstr

    st = status(s)
    ststr = if st == Waiting
        "⌛"
    elseif st == Aborted
        "☠"
    elseif st == Running
        "🏃"
    else#if st == Done
        "🏁"
    end
    prstr = ifelse(s.priority == -1, "[----]", "[⚖  $(s.priority)]")
    println(io, "[$(ststr)  $(progstr)] $(prstr) $(s.whensub)")
end

"""
```
mutable struct SweepJobQueue
    #PriorityQueue is essentially a glorified dictionary with built-in functionality
    #for sorting of keys
    q::PriorityQueue{Int,SweepJob,
        Base.Order.ReverseOrdering{Base.Order.ForwardOrdering}}
    running_id::Channel{Int}
    last_finished_id::Channel{Int}
    trystart::Condition #used to communicate with the job_starter function
    update_taskref::Ref{Task} #used to communicate with the job_updater function
    update_channel::Channel{SweepJob} #channel for communicating with the job_updater function
    function SweepJobQueue()
        sjq = new(PriorityQueue(Int[],SweepJob[],Base.Order.Reverse),
            Channel{Int}(1), Channel{Int}(1), Condition())
        put!(sjq.running_id, -1)
        put!(sjq.last_finished_id,-1)
        sjq.update_taskref = Ref{Task}() #initializing a pointer for a task
        sjq.update_channel = Channel(t->job_updater(sjq, t);
            ctype = SweepJob, taskref=sjq.update_taskref)
        #the job_updater function is wrapped in a Task through this Channel constructor
        @schedule job_starter(sjq) #the job_started function is wrapped in a Task here
        sjq
    end
end
```

A queue responsible for prioritizing sweeps and executing them accordingly. The
queue holds `SweepJob` objects, and "indexes" them by their `job_id`. It prioritizes
jobs based on their priorities; for equal priority values, the job submitted earlier
takes precedent. The queue keeps track of which job is running (if any) by its
`running_id` `Channel`. The queue keeps track of the last finished job by the
`last_finished_id` channel, for easy access to the data of the last finished job.
Other fields are used for intertask communication. Note that a `running_id of` -1
signifies that no job is running.

When a `SweepJobQueue` is created through it's argumentless inner constructor (made
for initialization purposes), two tasks are initialized. One task manages
job updates, the other task is responsible for starting jobs; the former task
executes the `job_updater` function, the latter task executes the `job_starter`
function. Both functions execute infinite while loops, therefore they never end.

When the job starter task is notified with the `trystart::Condition` object in
the `SweepJobQueue` object, it will find the highest priority job in the queue.
Then, if a job is not running, and the prioritized job is waiting,
and if the prioritized job is runnable (the priority may be "NEVER"), then the
job is started. The database is updated asynchronously to reflect the new job,
the queue's `running_id` is changed to the job's id, and the job's status is
changed to "Running".

The job updater task tries to take a `SweepJob` from `update_channel`, the unbuffered
job `Channel` of the `SweepJobQueue` object. The task is blocked until a job is
put into the channel. Once a job arrives, provided the job has finished or has
been aborted, the database is asynchronously updated, the job is marked as no longer
running (by updating the `running_id` and `last_finished_id` channels), the sweep result
is asynchronously saved to disk, and finally the job starter task is notified
through the queue's `trystart` `Condition` object. The job updater task loops around
and waits for another job to arrive at its channel.
"""
mutable struct SweepJobQueue
    #PriorityQueue is essentially a glorified dictionary with built-in functionality
    #for sorting of keys
    q::PriorityQueue{Int,SweepJob,
        Base.Order.ReverseOrdering{Base.Order.ForwardOrdering}}
    running_id::Channel{Int}
    last_finished_id::Channel{Int}
    trystart::Condition #used to communicate with the job_starter function
    update_taskref::Ref{Task} #used to communicate with the job_updater function
    update_channel::Channel{SweepJob} #channel for communicating with the job_updater function
    function SweepJobQueue()
        sjq = new(PriorityQueue(Int[],SweepJob[],Base.Order.Reverse),
            Channel{Int}(1), Channel{Int}(1), Condition())
        #a running_id of -1 in the code is taken to mean that no job is currently running
        put!(sjq.running_id, -1)
        put!(sjq.last_finished_id,-1)
        sjq.update_taskref = Ref{Task}() #initializing a pointer for a task
        sjq.update_channel = Channel(t->job_updater(sjq, t);
            ctype = SweepJob, taskref=sjq.update_taskref)
        #the job_updater function is wrapped in a Task through this Channel constructor
        @schedule job_starter(sjq) #the job_started function is wrapped in a Task here
        sjq
    end
end

"""
    job_updater(sjq::SweepJobQueue, update_channel::Channel{SweepJob})
Used when a sweep job finishes; archieves the result of the finished sweep job,
updates all job and queue metadata, asynchronously updates ICDataServer, and notifies
the job_starter task to run through `sjq`'s `trystart` `Condition` object. This function
continuously runs continuously without stopping once called. In its current
implementation, this function is executed through a Task when a `SweepJobQueue`
object is initialized; this allows the function to be stopped and recontinued
asynchronously as is appropriate.

The function first waits until the update_channel is populated with a job. Once
a job arrives, the function takes the job from the channel, and given that it's status is
"Done" or "Aborted", it executes the items described above
"""
function job_updater(sjq::SweepJobQueue, update_channel::Channel{SweepJob})
    while true
        sj = take!(update_channel)
        st = status(sj)
        if st == Done || st == Aborted
            @async begin
                @handle apicall(api, "updatejob", sj.job_id, jobstop=now(), jobstatus=Int(st))
            end

            # Set to priority lower than can be specified by the user
            dequeue!(sjq.q, sj.job_id)
            sj.priority = NEVER
            enqueue!(sjq.q, sj.job_id, sj)

            # Flag that nothing is running by changing running_id to -1
            # (if statement in case we aborted a job that wasn't running)
            rid = fetch(sjq.running_id)
            if sj.job_id == rid
                take!(sjq.running_id)
                put!(sjq.running_id, -1)
                take!(sjq.last_finished_id)
                put!(sjq.last_finished_id,sj.job_id)
                @async archive_result(sj) #save whatever was measured regardless if job was done or aborted
            end
            notify(sjq.trystart)
        end
    end
end

"""
    job_starter(sjq::SweepJobQueue)
Used when starting a new sweep job. The function first obtains the highest priority
job in `sjq`; and given that a job is not running, it's status is "Waiting",
and if the prioritized job is runnable (the priority may be "never"), then the
job is started. The function updates all job and queue metadata and asynchronously
updates ICDataServer. This function continuously runs continuously without stopping
once called. In its current implementation, this function is executed through a
Task when a `SweepJobQueue` object is initialized; this allows the function to
be stopped and recontinued asynchronously as is appropriate.

The last thing the function does is change the job status to "Running". When a
job is scheduled with the sweep function, the sweep function waits for the status
of the job to be changed from "Waiting" to start sourcing the instruments and
performing measurements
"""
function job_starter(sjq::SweepJobQueue)
    while true
        wait(sjq.trystart)
        if !isempty(sjq.q)  # maybe unnecessary to even check
            k,sjtop = peek(sjq.q)
            sttop = status(sjtop)

            # job is waiting, nothing is running, and job is runnable
            rid = fetch(sjq.running_id)
            if sttop == Waiting && rid == -1 && sjtop.priority > NEVER
                sjtop.whenstart = now()
                @async begin
                    apicall(api, "updatejob", sjtop.job_id, jobstart=sjtop.whenstart,
                    jobstatus=Int(Running))
                end
                take!(sjq.running_id)
                put!(sjq.running_id, k)
                take!(sjtop.status)
                put!(sjtop.status, Running)
            end
        end
    end
end

# Base method extensions for SweepJobQueue
getindex(x::SweepJobQueue, k) = x.q[k]
enqueue!(x::SweepJobQueue, k, v) = enqueue!(x.q, k, v)
dequeue!(x::SweepJobQueue, k) = dequeue!(x.q, k)
dequeue!(x::SweepJobQueue) = dequeue!(x.q)
peek(x::SweepJobQueue) = peek(x.q)
length(x::SweepJobQueue) = length(x.q)

#besides adding a job to the queue, the overloaded push! method also notifies the
#trystart condition, which allows the job_starter task to start a new job if
# the highest priority job in the queue has status "Waiting"
function push!(sjq::SweepJobQueue, sj::SweepJob)
    enqueue!(sjq.q, sj.job_id, sj)
    notify(sjq.trystart)
end

function show(io::IO, x::SweepJobQueue)
    if length(x) == 0
        println(io, "No jobs in queue.")
    else
        rid = fetch(x.running_id)
        if rid != -1
            println("Running job")
            show(io, x[rid])
            println(io)
        end
        println(io, "Ten highest priority jobs")
        println(io, "ID   Progress   Priority    Submitted")

        jobs = SweepJob[]
        i = 10
        while length(x) > 0 && i > 0
            k,sj = peek(x)
            push!(jobs, sj)
            dequeue!(x,k)
            i -= 1
        end
        for sj in jobs
            show(io, Pair(sj.job_id, sj))
            enqueue!(x, sj.job_id, sj)
        end
    end
end

"""
    jobs()
Returns the default `SweepJobQueue` object, initialized when the InstrumentControl
module is imported/used. All jobs are scheduled in this object. Typically you call
this to see what jobs are waiting, aborted, or finished, and what job is running.
"""
jobs() = sweepjobqueue[]

"""
    jobs(job_id)
Return the `SweepJob` object associated with `job_id` scheduled in the default
sweep job queue object.
"""
jobs(job_id) = jobs()[job_id]

"""
    result(i::Integer)
Returns a result array by job id in job scheduled in the default sweep job queue object.
"""
result(i::Integer) = result(jobs(i))

"""
    result()
Returns the result array from the last finished or aborted job scheduled in the
default sweep job queue object.
"""
function result()
    sjq = sweepjobqueue[]
    last_finished_id=fetch(sjq.last_finished_id)
    last_finished_id == -1 &&
        error("no jobs have run yet; no results to return.")
    result(last_finished_id)
end

"""
    abort!()
Abort the currently running job (if any). If no job is running, the method does
not throw an error.

    abort!(x::Integer)
    abort!(x::SweepJob)
Abort a sweep job, either by passing the job index number or the SweepJob object.
Practically, the status of the job is changed to "Aborted",
and the job is put into the update_channel of the default `SweepJobQueue` object.
This automatically leads to: update of job metadata in the `SweepJob` object
as well as in the ICDataServer, update of queue metadata, archiving of the job's
result array, and start of the highest priority job in the default sweep job queue.
Thus, aborting a job is guaranteed to bail out of the sweep in such a way that the
data that has been measured for most recent sourcing of a stimulus, i.e. at the very
start of a "for loop" in [`InstrumentControl._sweep!`](@ref). You can
also abort a sweep before it even begins.

Presently this function does not interrupt `measure`, so if a single
measurement takes a long time then the sweep is only aborted after that finishes.
"""
function abort! end

function abort!()
    sjq = sweepjobqueue[]
    job_id = fetch(sjq.running_id)
    if job_id > 0
        abort!(sjq[job_id])
    end
end

abort!(i::Integer) = abort!(jobs(i))
function abort!(x::SweepJob)
    isready(x.status) || error("status unavailable.")
    sjq = sweepjobqueue[]
    oldstat = take!(x.status)
    if oldstat == Waiting || oldstat == Running
        put!(x.status, Aborted)
        put!(sjq.update_channel, x)
    else
        put!(x.status, oldstat)
        if oldstat == Done
            error("job already done.")
        else
            error("job already aborted.")
        end
    end
    x
end

"""
    prune!(q::SweepJobQueue)
Prunes a [`SweepJobQueue`](@ref) of all [`InstrumentControl.SweepJob`](@ref)s
with a status of `Done` or `Aborted`. This will have the side effect of releasing
old sweep results if there remain no references to them in julia, however they
should still be saved to disk and can be recovered later.
"""
function prune!(q::SweepJobQueue)
    for i in 1:length(q.q)
        s = q[i]
        st = status(s)
        if st == Done || st == Aborted
            dequeue!(q,i)
        end
    end
end

"""
    sweep{N}(dep::Response, indep::Vararg{Tuple{Stimulus, AbstractVector}, N};
        priority = NORMAL)

`sweep` measures a response as a function of an arbitrary number of stimuli,
sourced over the values given in the `AbstractVector` input, and returns
a handle to the sweep job. This can be used to access the results while the
sweep is being measured.

This function is responsible for 1) initialzing sockets for communication with the
ICDataServer, 2) initializing an appropriate array to hold the reults of the sweep,
3) preparing a [`InstrumentControl.SweepJob`](@ref) object with an appropriate `job_id`
obtained from the database, 4) adding the job to the default `SweepJobQueue` object
(defined when the InstrumentControl module is used/imported), and 5) launching an
asynchronous sweep job.

The `priority` keyword may be `LOW`, `NORMAL`, or `HIGH`, or any
integer greater than or equal to zero.

The actual sweeping, i.e., the actual `source` and `measure`
loops to measure data are in a private function [`InstrumentControl._sweep!`](@ref).
Note that if [`InstrumentControl._sweep!`](@ref) is not defined yet, this function will
also define the method in order to it to be used to schedule a sweep.
"""
function sweep(dep::Response, indep::Vararg{Tuple{Stimulus, AbstractVector}, N};
    priority = NORMAL, username=confd["username"],
    notifications=confd["notifications"]) where {N}

    # Initialize sockets so they are ready to use (maybe unnecessary)
    plotsocket()
    apiinvoker()

    # Check if measure function has been appropriately defined
    T = Base.promote_op(measure, typeof(dep))
    !isleaftype(T) && error(string("measure(::", typeof(dep), ") must return a leaf type. ",
        "Is this method type-stable?"))

    # Make a new SweepJob object and assign appropriate id and metadata
    sj = SweepJob(dep, indep; priority = priority, username = username,
        notifications = notifications)
    df = @handle apicall(api, "newjob", username=username, dataserver="local_data")
    job_id = df[:job_id][1]
    jobsubmit = df[:jobsubmit][1]
    sj.job_id = job_id
    sj.whensub = jobsubmit
    sj.whenstart = jobsubmit

    D = ndims(T) #dimension of output of measure function
    sjq = sweepjobqueue[]
    !method_exists(_sweep!, (Val{D}, Val{N}, Any, Any)) && define_sweep(D,N)
    @schedule _sweep!(Val{D}(), Val{N}(), sj, sjq.update_channel)
    push!(sjq, sj) #push sweep job into queue
    info("Sweep submitted with job id: ", sj.job_id)
    sj #return the SweepJob object to provide a handle to the job
end

default_value(x) = zero(x)
default_value(::Type{T}) where {T <: AbstractFloat} = T(NaN)
default_value(::Type{Complex{T}}) where {T <: AbstractFloat} = Complex{T}(NaN)

"""
```
_sweep!(::Val{D}, ::Val{N}, sj, update_channel)
```

This is a private function which should not be called directly by the user.
It is launched asynchronously by [`sweep`](@ref). The implementation uses macros from
[Base.Cartesian](https://docs.julialang.org/en/stable/devdocs/cartesian/).
The stimuli are sourced only when they need to be, at the start of each `for` loop level.

`D` is the dimension of the output array of the measure function (if multiple
things are measured for one Response type, the array will be multi-dimensional).
`N` is the number of stimuli which the sweep sources over. sj is the handle to
the `SweepJob` object, and update_channel is a channel of the queue used for
intertask comunication.

The axis scaling of `measure(sj.sweep.dep)`, i.e., the dimensions of the output
array of the function. is presumed to be fixed, as it is only looked at once,
the first time `measure` is called.
"""
function _sweep! end

function define_sweep(D,N)
    eval(InstrumentControl, quote
        function _sweep!(::Val{$D}, ::Val{$N}, sj, update_channel)
            @respond_to_status # Wait for job to run or be aborted

            # Assign local variable names for convenience and setup progress indicator.
            indep = sj.sweep.indep
            dep = sj.sweep.dep
            it = 0; tot = reduce(*, 1, length(indep[i][2]) for i in 1:$N)

            # Source to first value for each stimulus and do first measurement
            #This is done for initialization purposes
            @nexprs $N j->source(indep[$(N+1)-j][1], indep[$(N+1)-j][2][1])
            data = measure(dep)

            # Setup a result array with the correct shape and assign first result.
            array = AxisArray( Array{eltype(data)}(
                size(data)..., (length(a) for (stim, a) in indep)...),
                axes(data)..., stimaxis.(indep)...)
            array.data[:] = default_value(eltype(data))

            sj.sweep.result = array
            inds = ((@ntuple $D t->Colon())..., (@ntuple $N t->1)...)
            array[inds...] = data
            it += 1; take!(sj.progress); put!(sj.progress, it/tot) # Update progress.

            # Setup a plot and send our first result
            # io = IOBuffer()
            # serialize(io, ICCommon.PlotSetup(Array{eltype(data)}, size(array)))
            # produce(io)
            # io = IOBuffer()
            # serialize(io, ICCommon.PlotPoint(inds, data))
            # produce(io)

            (@ntuple $N t) = (@ntuple $N x->true)
            t_body = true
            #below, @respond_to_status is in the pre-expression of each loop,
            #if sweep is aborted, this macro returns, and ends the _sweep! function call
            @nloops $N i k->indices(array,k+$D) j->(@respond_to_status;
                @skipfirst t_j source(indep[j][1], indep[j][2][i_j])) begin

                if t_body == true
                    t_body = false
                else
                    yield()
                    data = measure(dep)
                    (@dnref $D $N array i) = data

                    # update progress
                    it += 1; take!(sj.progress); put!(sj.progress, it/tot)
                    # send forth results
                    # io = IOBuffer()
                    # serialize(io, ICCommon.PlotPoint((@dntuple $D $N i), data))
                    # produce(io)
                end
            end
            take!(sj.status); put!(sj.status, Done)
            put!(update_channel, sj)
        end
    end)
end

"""
```
@respond_to_status
```
Respond to status changes during a sweep. This is the entry point for sweeps to
be paused or aborted. When a sweep is scheduled, this macro has to end before
the sweep actually starts sourcing the instruments and performing measurements
through the [`InstrumentControl._sweep!`](@ref) function. The macro only ends
when the status of the job changes from "Waiting" to something else.

If the status is changed to "Aborted", the macro executes "return". In practice,
since this macro is called by the [`InstrumentControl._sweep!`](@ref) function,
this causes the [`InstrumentControl._sweep!`](@ref) function to abort as well,
thus stopping the sweep.

Not meant to be called by the user. It will break if
argument names of [`InstrumentControl._sweep!`](@ref) are modified.
"""
macro respond_to_status()
    esc(quote
        while status(sj) == Waiting
            sleep(0.1)
        end

        if status(sj) == Aborted
            return
        end
    end)
end

# AxisArrays patchwork
# Needed for when `measure` returns a scalar.
axisname(ax::Axis) = typeof(ax).parameters[1]
axes(::Number) = ()
stimaxis(sv) = Axis{axisname(sv[1])}(sv[2])

"""
    @dnref(D, N, A, sym)
This is a lot like `@nref` in `Base.Cartesian`. See the Julia documentation;
the only difference here is that we are going to have the first `D` indices
be `:` (which are constructed programmatically by `Colon()`).
"""
macro dnref(D, N, A, sym)
    _dnref(D, N, A, sym)
end

function _dnref(D::Int, N::Int, A, ex)
    vars = [ inlineanonymous(ex,i) for i = 1:N ]
    Expr(:escape, Expr(:ref, A, [Colon() for i = 1:D]..., vars...))
end

"""
    @dntuple(D, N, A, sym)
This is a lot like `@ntuple` in `Base.Cartesian`. See the Julia documentation;
the only difference here is that we are going to have the first `D` elements
be `:` (which may be constructed programmatically by `Colon()`).
"""
macro dntuple(D, N, ex)
    _dntuple(D, N, ex)
end

# This is a lot like @ntuple in Base.Cartesian, except we are going to have the
# first D indices be Colon().
function _dntuple(D::Int, N::Int, ex)
    vars = [ inlineanonymous(ex,i) for i = 1:N ]
    Expr(:escape, Expr(:tuple, [Colon() for i = 1:D]..., vars...))
end

"""
    @skipfirst(t, ex)
Place `ex` in a code block such that `ex` is only after the first time this code
block is encountered.

`t` is a symbol bound to `true`, which is the flag for if the code block should
be skipped or not. This macro sets `t` to `false` if it is `true` or otherwise
evaluates `ex`.
"""
macro skipfirst(t, ex)
    esc(quote
        if $t == true
            $t = false
        else
            $ex
        end
    end)
end
