export sweep, eta, status, progress, abort!, prune!, jobs, result
export reconstruct, atvalue
using Base.Cartesian, JLD
using AxisArrays
import AxisArrays: axes
import Base.Cartesian.inlineanonymous
import Compat.view
import Base: show, isless, getindex, push!, length, eta
import Base.Collections: PriorityQueue, enqueue!, dequeue!, peek
# export Sweep, SweepJob, SweepStatus

# Priorities for sweep jobs
const NEVER = -1
const LOW = 0
const NORMAL = 5
const HIGH = 10

"""
```
type Sweep
    dep::Response
    indep::Tuple{Tuple{Stimulus, AbstractVector}}
    result::AxisArray
    Sweep(a,b) = new(a,b)
    Sweep(a,b,c) = new(a,b,c)
end
```

Object representing a sweep. `dep` (short for dependent) is a [`Response`](@ref)
that will be measured. `indep` is a tuple of [`Stimulus`](@ref) objects and the
values they will be sourced over. `result` is the result array of the sweep,
which need not be provided at the time the Sweep object is created.
"""
type Sweep
    dep::Response
    indep::Vector{Tuple{Stimulus, AbstractVector}}
    result::AxisArray
    Sweep(a,b) = new(a,b)
    Sweep(a,b,c) = new(a,b,c)
end

@enum SweepStatus Waiting Running Aborted Done

"""
```
@enum SweepStatus Waiting Running Aborted Done
```

Sweep statuses are represented with an enum.

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
```
type SweepJob
    sweep::Sweep
    priority::Int
    job_id::Int
    has_started::Bool
    status::Channel{SweepStatus}
    progress::Channel{Float64}
    whensub::DateTime
    username::String
    notifications::Bool
end
```

Object representing a "sweep job," that is a sweep with some associated metadata
to play nicely with queueing and logging. `sweep` is a
[`InstrumentControl.Sweep`](@ref) object. `priority` is an `Int` from 0 to
`typemax(Int)`, inclusive, typically one of the following:

- `HIGH == 10`
- `NORMAL == 5`
- `LOW == 0`

`status` and `progress` are channels for intertask communication about the
status and progress of the sweep. `whensub` is when the `Sweep` was created,
`whenstart` is when the `Sweep` was initially run. `username` is who submitted
the sweep job. If `notifications` is true, status updates are sent out if
possible.
"""
type SweepJob
    sweep::Sweep
    priority::Int
    job_id::Int
    has_started::Bool
    status::Channel{SweepStatus}
    progress::Channel{Float64}
    whensub::DateTime
    whenstart::DateTime
    username::String
    notifications::Bool
end

"""
```
SweepJob(dep, indeps; priority=NORMAL_PRIORITY, username=confd["username"],
    notifications=confd["notifications"])
```

Initialize a `SweepJob` object given `dep` and `indeps`. Until interaction
with the database, `job_id` is set to zero and `whenstart` is temporarily
(and inaccurately) set to `whensub`.
"""
function SweepJob(dep, indeps;
        priority=NORMAL, username=confd["username"],
        notifications=confd["notifications"])
    priority < 0 && error("priority must be greater than zero.")
    dt = now()
    sj = SweepJob(Sweep(dep, [indeps...]), priority, 0, false,
        Channel{SweepStatus}(1), Channel{Float64}(1), dt, dt, username,
        notifications)
    put!(sj.status, Waiting)
    put!(sj.progress, 0.0)
    sj
end

# For PriorityQueue sorting
function isless(a::SweepJob, b::SweepJob)
    ap, bp = a.priority, b.priority
    isless(ap, bp) ||
        (ap == bp && isless(b.whensub, a.whensub))
end

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
eta(x::SweepJob)
```

Return the estimated time of completion for sweep job `x`.
"""
function eta(x::SweepJob)
    # Check if job has started
    if !x.has_started
        error("job has not started yet.")
    end
    # Check if job has finished
    if progress(x) == 1.0
        error("job finished already.")
    end

    # returns Float64 seconds
    interval = Dates.datetime2unix(now())-Dates.datetime2unix(x.whenstart)
    interval /= progress(x)

    Dates.Millisecond(round(interval*1000.0)) + x.whenstart
end

"""
```
status(x::SweepJob)
```

Return the sweep job status.
"""
function status(x::SweepJob)
    isready(x.status) || error("status unavailable.")
    fetch(x.status)
end

"""
```
progress(x::SweepJob)
```

Returns the sweep job progress, a `Float64` between 0 and 1 (inclusive).
"""
function progress(x::SweepJob)
    isready(x.progress) || error("progress unavailable.")
    fetch(x.progress)
end

"""
```
abort!(x::SweepJob)
```

Abort a sweep job. Guaranteed to bail out of the sweep in such a way that the
data has been measured for most recent sourcing of a stimulus, i.e. at the very
start of a for loop in [`InstrumentControl._sweep!`](@ref). You can also abort a
sweep before it even begins. Presently this function does not interrupt
[`measure`](@ref), so if a single measurement takes a long time then the sweep
is only aborted after that finishes.
"""
function abort!(x::SweepJob)
    isready(x.status) || error("status unavailable.")
    oldstat = take!(x.status)
    if oldstat == Waiting || oldstat == Running
        put!(x.status, Aborted)
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
```
abort!()
```

Abort the currently running job (if any). If no job is running, the method does
not throw an error.
"""
function abort!()
    sjq = sweepjobqueue[]
    job_id = sjq.running_id
    if job_id > 0
        abort!(sjq[job_id])
    end
end

"""
```
result(sj::SweepJob)
```

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
```
result(i::Integer)
```

Returns a result array by job id.
"""
@inline result(i::Integer) = result(jobs(i))

"""
```
result()
```

Returns the result array from the last finished or aborted job.
"""
function result()
    sjq = sweepjobqueue[]
    sjq.last_finished_id == -1 &&
        error("no jobs have run yet; no results to return.")
    result(sjq.last_finished_id)
end

"""
```
type SweepJobQueue
    q::PriorityQueue{Int,SweepJob,
        Base.Order.ReverseOrdering{Base.Order.ForwardOrdering}}
    running_id::Int
    last_finished_id::Int
    update_condition::Condition
    function SweepJobQueue()
        new(PriorityQueue(Int[],SweepJob[],Base.Order.Reverse), -1, Condition())
    end
end
```

A queue responsible for prioritizing sweeps and executing them accordingly.
"""
type SweepJobQueue
    q::PriorityQueue{Int,SweepJob,
        Base.Order.ReverseOrdering{Base.Order.ForwardOrdering}}
    running_id::Int
    last_finished_id::Int
    update_condition::Condition
    function SweepJobQueue()
        new(PriorityQueue(Int[],SweepJob[],Base.Order.Reverse), -1, -1, Condition())
    end
end

# Base method extensions.
function show(io::IO, x::SweepJobQueue)
    if length(x) == 0
        println(io, "No jobs in queue.")
    else
        if x.running_id != -1
            println("Running job")
            show(io, x[x.running_id])
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

getindex(x::SweepJobQueue, k) = x.q[k]
enqueue!(x::SweepJobQueue, k, v) = enqueue!(x.q, k, v)
dequeue!(x::SweepJobQueue, k) = dequeue!(x.q, k)
dequeue!(x::SweepJobQueue) = dequeue!(x.q)
peek(x::SweepJobQueue) = peek(x.q)
length(x::SweepJobQueue) = length(x.q)

function push!(q::SweepJobQueue, sw::SweepJob)
    # Stick it in the queue and increment next job id
    enqueue!(q.q, sw.job_id, sw)

    # Maybe the job should be run, let's give the queue a chance to react
    notify(q.update_condition, sw)
end

"""
```
jobs()
```

Returns the default sweep job queue object. Typically you call this to see what
jobs are waiting, aborted, or finished, and what job is running.
"""
jobs() = sweepjobqueue[]

"""
```
jobs(job_id)
```

Return the job associated with `job_id`.
"""
jobs(job_id) = jobs()[job_id]

# Make SweepJobQueues callable
function (sq::SweepJobQueue)()
    sj = wait(sq.update_condition)
    while true
        st = status(sj)
        @sync begin
            if st == Done || st == Aborted
                @async begin
                    update_job_in_db(sj, jobstop=now(), jobstatus=Int(st)) ||
                    error("failed to update job $(sj.job_id).")
                end

                # Set to priority lower than can be specified by the user
                dequeue!(sq.q, sj.job_id)
                sj.priority = NEVER
                enqueue!(sq.q, sj.job_id, sj)

                # Flag that nothing is running
                # (if statement in case we aborted a job that wasn't running)
                if sj.job_id == sq.running_id
                    sq.running_id = -1
                end
                sq.last_finished_id = sj.job_id

                # Save whatever was measured, regardless of abort or done
                archive_result(sj)
            end
        end

        # Sync block ensures that the enclosed db update finishes before the
        # next db update. Updating db asynchronously so that there is no task
        # switching before we wait for the update condition. Without the async,
        # the returned job status might not show "running" if a job is launched
        # with nothing in the queue.
        @sync begin
            if !isempty(sq.q)  # maybe unnecessary to even check
                k,sjtop = peek(sq.q)
                sttop = status(sjtop)

                # job is waiting, nothing is running, and job is runnable
                if sttop == Waiting && sq.running_id == -1 &&
                        sjtop.priority > NEVER

                    sjtop.whenstart = now()
                    sjtop.has_started = true
                    @async begin
                        update_job_in_db(sjtop, jobstart=sjtop.whenstart,
                        jobstatus=Int(Running)) ||
                            error("failed to update job $(sjtop.job_id).")
                    end

                    sq.running_id = k
                    take!(sjtop.status)
                    put!(sjtop.status, Running)
                end
            end
            sj = wait(sq.update_condition)
        end
    end
end



"""
```
prune!(q::SweepJobQueue)
```

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

# TODO: default username and server mechanism
function new_job_in_db(;username="default")::Tuple{UInt, DateTime}
    request = ICCommon.NewJobRequest(username=username, dataserver="local_data")
    io = IOBuffer()
    serialize(io, request)
    ZMQ.send(dbsock[], ZMQ.Message(io))
    # Note that it is totally possible a task switch can happen here!
    msg = ZMQ.recv(dbsock[])
    out = convert(IOStream, msg)
    seekstart(out)
    job_id, jobsubmit = deserialize(out)
end

function update_job_in_db(sw; kwargs...)::Bool
    request = ICCommon.UpdateJobRequest(sw.job_id; kwargs...)
    io = IOBuffer()
    serialize(io, request)
    ZMQ.send(qsock[], ZMQ.Message(io))
    # Note that it is totally possible a task switch can happen here!
    msg = ZMQ.recv(qsock[])
    out = convert(IOStream, msg)
    seekstart(out)
    deserialize(out)
end

axisname(ax::Axis) = typeof(ax).parameters[1]

function archive_result(sj::SweepJob)
    # We assume that the sweep result is an AxisArray.
    # For our archived data we do not save an AxisArray but rather split it
    # apart into pieces that can be reassembled later. We do this to secure
    # future compatibility in case the definition of an AxisArray changes.
    # We can always reconstruct the axis array later.
    if isdefined(sj.sweep, :result)
        axarray = sj.sweep.result
        archive = Dict{String,Any}("data" => axarray.data)    #Add whole data matrix into the Dictionary with key "data"
        firstdim = ndims(axarray) - length(sj.sweep.indep)    #Last Dimension Number of dependent axes
        for (i,ax) in enumerate(axes(axarray))
            archive["axis$(i)_$(axisname(ax))"] = ax.val      #Storing Axes Types of the axes
        end
        for (i, (s,a)) in enumerate(sj.sweep.indep)
            archive["desc$(i+firstdim)"] = axislabel(s)       #Storing given names of independent axes
        end

        try
            dpath = joinpath(confd["archivepath"], "$(Date(sj.whensub))")
            if !isdir(dpath)
                mkdir(dpath)
            end
            save(joinpath(dpath, "$(sj.job_id).jld"), archive)  #Saving jld data files for use by Julia codes
            saveNRRD(joinpath(dpath, "$(sj.job_id)"),sj)  #Save data in NRRD format for other languages
        catch e
            warn("could not save data!")
            rethrow(e)
        end
    end
end

# Save the file in NRRD file format for cross-platform access
function saveNRRD(filename,sj::SweepJob)
    axarray = sj.sweep.result
    #If measured data is real, we write it as it is
    #Otherwise, we expand data to one more dimension for real and imaginary parts
    if isreal(axarray)
        datatyp = typeof(axarray[])
        dims = ndims(axarray)
        sizes = ""
        kinds = ""
        labels = ""
        RealFlag = true
    else
        datatyp = real(typeof(axarray[]))
        dims = ndims(axarray)+1     #Extra dimension Added
        sizes = "2"                 #Extra dimension has size 2 (for Real and Imaginary)
        kinds = "complex"           #The extra dimension created will be of kind complex
        labels = "Complex"
        RealFlag = false
    end
    #Setting Field Type:
    #Note: Some Julia datatypes are not supported by NRRD format
    if datatyp==Float32
        typ = "float"
    elseif datatyp==Float64
        typ = "double"
    elseif datatyp==Int8
        typ = "int8"
    elseif datatyp==Int16
        typ = "short"
    elseif datatyp==Int32
        typ = "int"
    elseif datatyp==Int64
        typ = "int64"
    elseif datatyp==Int128
        error("Unsupported datatype")
    elseif datatyp==Float16
        error("Unsupported datatype")
    elseif datatyp==UInt8
        typ = "uint8"
    elseif datatyp==UInt16
        typ = "ushort"
    elseif datatyp==UInt32
        typ = "uint"
    elseif datatyp==UInt64
        typ = "uint64"
    elseif datatyp==UInt128
        error("Unsupported datatype")
    elseif datatyp==Bool
        error("Unsupported datatype")
    else
        error("Unrecognizable Datatype")
    end
    #Setting Field Sizes:
    for i in size(axarray) sizes=string(sizes," $(i)") end
    #Setting Fields Kinds: and Labels:
    if size(axarray)[1]>1
        kinds = "$(kinds) $(size(axarray)[1])-vector"
    else
        kinds = "$(kinds) scalar"
    end
    labels = "$(labels) $(axisname(axes(axarray)[1]))"
    for i=1:1:length(axes(ex2)[1])
        labels = "$(labels)_$(axes(axarray)[1][i])"
    end
    for (s,a) in sj.sweep.indep
        kinds = "$(kinds) domain"
        labels = "$(labels) $(axislabel(s))"
    end
    #We will be using detached NRRD file format so that a clean only-data file is available always
    #Writing header files
    open("$(filename).nhdr","w") do f
        write(f,"NRRD0004\r\n")
        write(f,"Content: Job ID $(sj.job_id)\r\n")
        write(f,"Type: $(typ)\r\n")
        write(f,"Dimension: $(dims)\r\n")
        write(f,"Encoding: ascii\r\n")
        write(f,"Endian: little\r\n")
        write(f,"Sizes: $(sizes)\r\n")
        write(f,"Kind: $(kinds)\r\n")
        write(f,"Labels: $(labels)\r\n")
        write(f,"Datafile: $(filename).txt\r\n")
        write(f,"\r\n")
    end
    #Writing the datafile
    open("$(filename).txt","w") do f
        if RealFlag
            for ele in axarray.data
                write(f,"$(ele)\r\n")
            end
        else
            #For complex data, increase dimension by writing real and imaginary
            #parts separately with a tab (\t) in between
            #Note: NRRD readers are supposed to interpret all delimiters in same way
            for ele in axarray.data
                write(f,"$(real(ele))\t$(imag(ele))\r\n")
            end
        end
    end
end

# Reconstruct AxisArray from an archived dictionary.
function reconstruct(d::Dict{String,Any})
    haskey(d, "data") || error("no `data` key.")

    r = r"^axis([0-9]+)_([\s\S]+)"
    keyz = collect(keys(d))
    where = [ismatch(r, str) for str in keyz]
    matches = keyz[where]
    a = map(str->begin m = match(r,str); parse(m[1]),m[2] end, matches)
    a2 = Vector{Tuple{Symbol, Any}}(length(a))
    for (f,g) in a
        a2[f] = (Symbol(g), d["axis$(f)_$(g)"])
    end
    AxisArray(d["data"], (Axis{name}(v) for (name,v) in a2)...)
end


"""
```
sweep{N}(dep::Response, indep::Vararg{Tuple{Stimulus, AbstractVector}, N};
    priority = NORMAL)
```

Measures a response as a function of an arbitrary number of stimuli, and returns
a handle to the sweep job. This can be used to access the results while the
sweep is being measured.

This function is responsible for initializing an appropriate array, preparing
a [`InstrumentControl.SweepJob`](@ref) object, and launching an asynchronous
sweep job. The actual `source` and `measure` loops are in a private function
[`InstrumentControl._sweep!`](@ref).

The `priority` keyword may be `LOW`, `NORMAL`, or `HIGH`, or any
integer greater than or equal to zero.
"""
function sweep{N}(dep::Response, indep::Vararg{Tuple{Stimulus, AbstractVector}, N};
    priority = NORMAL, username=confd["username"],
    notifications=confd["notifications"])

    # Make a new SweepJob object and assign the array we made to it
    sj = SweepJob(dep, indep; priority = priority, username = username,
        notifications = notifications)

    # Get a new job_id
    job_id, jobsubmit = new_job_in_db(username=username)
    sj.job_id = job_id
    sj.whensub = jobsubmit
    sj.whenstart = jobsubmit

    T = returntype(measure, (typeof(dep),))
    tup = (ndims(T), N)
    sjq = sweepjobqueue[]
    t = Task(()->_sweep!(sjq.update_condition, sj, Val{tup}()))

    @async begin
        for x in t
            ZMQ.send(plotsock[], ZMQ.Message(x))
        end
        notify(sjq.update_condition, sj)
    end
    push!(sjq, sj)

    info("Sweep submitted with job id: $(sj.job_id)")
    sj
end

default_value(x) = zero(x)
default_value{T<:AbstractFloat}(::Type{T}) = T(NaN)
default_value{T<:AbstractFloat}(::Type{Complex{T}}) = Complex{T}(NaN)

"""
```
@generated function _sweep!{T}(updated_status_of, sj, ::Val{T})
```

This is a private function which should not be called directly by the user.
It is launched asynchronously by [`sweep`](@ref).
The implementation uses `@generated` and macros from
[Base.Cartesian](http://docs.julialang.org/en/release-0.5/devdocs/cartesian/).
The stimuli are sourced only when they need to be, at the start of each
`for` loop level.

`T` is a `Tuple{Int,Int}` object where the first `Int` is the number of dimensions
coming from a single measurement, and the second `Int` is the number of independent
sweep axes.

The axis scaling of `measure(sj.sweep.dep)` is presumed to be fixed, as it is
only looked at once, the first time `measure` is called.
"""
@generated function _sweep!{T}(updated_status_of, sj, ::Val{T})
    D,N = T
    quote
        # Assign some local variable names for convenience
        # and setup our progress indicator.
        indep = sj.sweep.indep
        dep = sj.sweep.dep
        it = 0; tot = reduce(*, 1, length(indep[i][2]) for i in 1:$N)

        # Wait for job to run or be aborted
        @respond_to_status

        # Source to first value for each stimulus and do first measurement.
        @nexprs $N j->source(indep[$(N+1)-j][1], indep[$(N+1)-j][2][1])
        data = measure(dep)

        # Setup a result array with the correct shape and assign first result.
        # Update progress.
        array = AxisArray( Array{eltype(data)}(
            size(data)..., (length(a) for (stim, a) in indep)...),
            axes(data)..., stimaxis.(indep)...)
        array.data[:] = default_value(eltype(data))

        sj.sweep.result = array
        inds = ((@ntuple $D t->Colon())..., (@ntuple $N t->1)...)
        array[inds...] = data
        it += 1; take!(sj.progress); put!(sj.progress, it/tot)

        # Setup a plot and send our first result
        io = IOBuffer()
        serialize(io, ICCommon.PlotSetup(Array{eltype(data)}, size(array)))
        produce(io)
        io = IOBuffer()
        serialize(io, ICCommon.PlotPoint(inds, data))
        produce(io)

        (@ntuple $N t) = (@ntuple $N x->true)
        t_body = true
        @nloops $N i k->indices(array,k+$D) j->(@respond_to_status;
            @skipfirst t_j source(indep[j][1], indep[j][2][i_j])) begin

            if t_body == true
                t_body = false
            else
                data = measure(dep)
                (@dnref $D $N array i) = data

                # update progress
                it += 1; take!(sj.progress); put!(sj.progress, it/tot)

                # send forth results
                io = IOBuffer()
                serialize(io, ICCommon.PlotPoint((@dntuple $D $N i), data))
                produce(io)
            end
        end
        take!(sj.status); put!(sj.status, Done)
    end
end

# AxisArrays patchwork
# Needed for when `measure` returns a scalar.
axes(::Number) = ()

# Needed for indexing arrays by real value.
immutable Value{T}
    val::T
end
atvalue(x) = Value(x)
AxisArrays.axisindexes(::Type{AxisArrays.Dimensional}, ax::AbstractVector,
    idx::Value) = findfirst(ax.==idx.val)

stimaxis(sv) = Axis{axisname(sv[1])}(sv[2])

"""
```
@dnref(D, N, A, sym)
```

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
```
@dntuple(D, N, A, sym)
```

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
```
@skipfirst(t, ex)
```

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

"""
```
@respond_to_status
```

Respond to status changes during a sweep. This is the entry point for sweeps to
be paused or aborted. Not meant to be called by the user. It will break if
argument names of [`InstrumentControl._sweep!`](@ref) are modified.
"""
macro respond_to_status()
    esc(quote
        while status(sj) == Waiting
            sleep(0.1)
        end

        if status(sj) == Aborted
            notify(updated_status_of, sj)
            return
        end
    end)
end
