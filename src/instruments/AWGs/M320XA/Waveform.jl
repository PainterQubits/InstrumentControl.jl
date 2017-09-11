import DataFrames

#export Waveform
export WaveChProperty

export WavTrigMode
export WavDelay
export WavRepetitions
export QueuePosition
export WavPrescaler

export load_waveform
export queue_waveform
export queue_sequence
export queue_flush
export waveforms_flush
export memory_size

abstract type WaveChProperty end

abstract type WavTrigMode <: WaveChProperty end
abstract type WavDelay <: WaveChProperty end
abstract type WavRepetitions <: WaveChProperty end
abstract type QueuePosition <: WaveChProperty end
abstract type WavPrescaler <: WaveChProperty end

"""
    load_waveform(ins::InsAWGM320XA, waveformValues::Array{Float64}, id::Integer,
                       name::AbstractString; input_type::Symbol = :Analog16)
    load_waveform(ins::InsAWGM320XA, waveformFile::String, id::Integer,
                       name::AbstractString = string(id))

Loads a waveform into the the RAM of the AWG corresponding to object `ins`.
When loading a waveform, the user picks an id to be the identifier and handle for
the loaded waveform. Thus, the function takes as arguments the waveform digital
values, the user-specified id, a name for the waveform (meant to be a more descriptive
identifier than an integer), and the input type(refer to Table 9 of the userguide
for discussion on input types). The waveform digital values can be passed as an
array of values, or as a path to a file containing the values.

The function returns a handle to the new `Waveform` object created and stored
in `ins.waveforms`, indexed by it's user-specified id.
"""
function load_waveform end

function load_waveform(ins::InsAWGM320XA, waveform::Waveform, id::Integer;
                       input_type::Symbol = :Analog16)
    waveformValues = waveform.waveformValues
    temp_id = SD_Wave_newFromArrayDouble(symbol_to_keysight(input_type), waveformValues) #when loading the waveform to the AWG RAM, this id is overwritten
    temp_id < 0 && throw(InstrumentException(ins, temp_id))
    if haskey(ins.waveforms, id)
        @KSerror_handler SD_AOU_waveformReLoad(ins.ID, temp_id, id)
    else
        @KSerror_handler SD_AOU_waveformLoad(ins.ID, temp_id, id)
    end
    #initialize ch_properties field of waveform object with number of channels information from ins
    num_channels = size(collect(keys(ins.channels)))[1]
    for ch = 1:num_channels
        waveform.ch_properties[ch] = Dict{Any, Any}()
    end
    ins.waveforms[id] = waveform
    return ins.waveforms[id]
end

function load_waveform(ins::InsAWGM320XA, waveformValues::Array{Float64}, id::Integer,
                       name::AbstractString = string(id); input_type::Symbol = :Analog16)
    waveform = Waveform(waveformValues, name)
    load_waveform(ins, waveform, id, input_type = input_type)
end

function load_waveform(ins::InsAWGM320XA, waveformFile::String, id::Integer,
                       name::AbstractString = string(id))
    temp_id = SD_Wave_newFromFile(waveformFile)
    temp_id < 0 && throw(InstrumentException(ins, temp_id))
    if haskey(ins.waveforms, id)
        @KSerror_handler SD_AOU_waveformReLoad(ins.ID, temp_id, id)
    else
        @KSerror_handler SD_AOU_waveformLoad(ins.ID, temp_id, id)
    end
    #read csv file and extract waveformValues; NEEDS WORK
    temp_data = DataFrames.readtable(waveformFile) #how you read CSV files
    waveformValues = convert(Array, temp_data)
    waveform = Waveform(waveformValues, name)
    #initialize ch_properties field of waveform object with number of channels information from ins
    num_channels = size(keys(ins.channels))[1]
    for ch = 1:num_channels
        waveform.ch_properties[ch] = Dict{Any, Any}()
    end
    ins.waveforms[id] = waveform
    return ins.waveforms[id]
end

"""
    queue_waveform(ins::InsAWGM320XA, id::Integer, ch::Integer, trigger_mode::Symbol;
                  repetitions::Integer = 1, delay::Integer = 0, prescaler::Integer = 0 )
    queue_waveform(ins::InsAWGM320XA, id::Integer, ch::Integer, trigger_mode::Symbol;
                   repetitions::Integer = 1, delay::Integer = 0, prescaler::Integer = 0 )

Queues a waveform in a channel of the AWG either by a passed `Waveform` object
or the waveform id. It also takes values for configuration settings pertaining
to when and how the waveform will be generated and outputted, such as trigger mode,
number of repititions, delay between the trigger and generation, and the prescaler
value for the outputted waveform. While the channel and trigger_mode must be specified,
the other settings are used as keyword arguments with standard values (chosen by me).
"""
function queue_waveform end

function queue_waveform(ins::InsAWGM320XA, id::Integer, ch::Integer,
                        trigger_mode::Symbol; repetitions::Integer = 1,
                        delay::Integer = 0, prescaler::Integer = 0 )
    @KSerror_handler SD_AOU_AWGqueueWaveform(ins.ID, ch, id,
                            symbol_to_keysight(trigger_mode), delay,
                            repetitions, prescaler)
    waveform = ins.waveforms[id]
    waveform.ch_properties[ch][WavTrigMode] = trigger_mode
    waveform.ch_properties[ch][WavDelay] = delay
    waveform.ch_properties[ch][WavRepetitions] = repetitions
    waveform.ch_properties[ch][WavPrescaler] = prescaler
    push!(ins.channels[ch][Queue], id)
    nothing
end

function queue_waveform(ins::InsAWGM320XA, wav::Waveform, ch::Integer,
                        trigger_mode::Symbol; repetitions::Integer = 1,
                        delay::Integer = 0, prescaler::Integer = 0)
    #finding the id of the waveform object with which the waveform was loaded to RAM
    id = -1 #initializing id
    wav in values(ins.waveforms) || error("waveform not loaded")
    for key in keys(ins.waveforms)
        if ins.waveforms[key] == wav
            id = key
            break
        end
    end
    queue_waveform(ins, id, ch, trigger_mode; repetitions = repetitions,
                    delay = delay, prescaler = prescaler)
    nothing
end

"""
    queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                    wavsForQueue::Vector{Waveform})

    queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                    wavsForQueue::Vector{Waveform})

    queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                    wavsForQueue::Vector{Waveform})

    queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                    wavsForQueue::Vector{Waveform})

Queues a sequence of waveforms into the queue of channel `ch`. The sequence of
waveforms can either be a tuple or vector, of either waveform id's or waveform
objects. The waveforms are queued in the order that they are stored in the passed
collection object. `trigger_mode` only refers to the `WavTrigMode` of the first
waveform of the sequence; the subsequent waveforms have `WavTrigMode` equal to `:Auto`;
that is, once the first waveform is triggered, the subsequent waveforms are generated
automatically one after another without delay.
"""
function queue_sequence end

# I flesh out the method with wavsForQueue::Vector{Waveform}, rather than the other
# ones, because it is easier/convenient to convert other wavsForQueue types to this type
function queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                        wavsForQueue::Vector{Waveform})
    queue_waveform(ins, wavsForQueue[1], ch, trigger_mode)
    for i=2:size(wavsForQueue)[1]
        queue_waveform(ins, wavsForQueue[i], ch, :Auto)
    end
    nothing
end

function queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                        wavsForQueue::Vararg{Waveform})
    wavsForQueue = collect(wavsForQueue) #turn tuple of waveforms into vector of waveforms
    #calling upon wavsForQueue::Vector{Waveform} method
    queue_sequence(ins, ch, trigger_mode, wavsForQueue)
    nothing
end

function queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                        wavsForQueue::Vector{Int})
    wavsForQueue = map(x->ins.waveforms[x], wavsForQueue)
    #calling upon wavsForQueue::Vector{Waveform} method
    queue_sequence(ins, ch, trigger_mode, wavsForQueue)
    nothing
end

function queue_sequence(ins::InsAWGM320XA ,ch::Integer, trigger_mode::Symbol,
                        wavsForQueue::Vararg{Int})
    wavsForQueue = collect(wavsForQueue) #turn tuple of integers into vector of integers
    #calling upon wavsForQueue::Vector{Integer} method
    queue_sequence(ins, ch, trigger_mode, wavsForQueue)
    nothing
end

"""
    queue_flush(ins::InsAWGM320XA, ch::Integer)

Empties the queue of an AWG channel. This function both: uses the native C
`SD_AOU_AWGflush` function to empty the queue in the instrument, and it re-initializes
`ins.channels[ch][Queue]` vector as a blank vector, erasing the record of the
queue in the object as well.
"""
function queue_flush(ins::InsAWGM320XA, ch::Integer)
    @KSerror_handler SD_AOU_AWGflush(ins.ID, ch)
    ins.channels[ch][Queue] = Vector{Int}()
    for waveform in values(ins.waveforms)
        waveform.ch_properties[ch] = Dict{Any, Any}()
    end
    nothing
end

"""
    waveforms_flush(ins::InsAWGM320XA)

Erases all waveforms stored in the RAM of the AWG, and empties the queue of
all the channels. This function both: uses the native C `SD_AOU_waveformFlush`
function to empty the erase the RAM and empty the queues in the instrument,
it re-initializes `ins.channels[ch][Queue]` vector as a blank vector for
all channels, erasing the record of the queue in the `InsAWGM30XA` object as well,
and re-initializes `ins.waveforms` as a blank dictionary
"""
function waveforms_flush(ins::InsAWGM320XA)
    @KSerror_handler SD_AOU_waveformFlush(ins.ID)
    ins.waveforms = Dict{Int, Waveform}()
    for ch in keys(ins.channels)
        ins.channels[ch][Queue] = Vector{Int}()
    end
    nothing
end

"""
    memory_size(ins::InsAWGM320XA, wav::Waveform)
    memory_size(ins::InsAWGM320XA, id::Integer)
Obtain size of waveform in memory
"""
function memory_size end

memory_size(ins::InsAWGM320XA, id::Integer) = @KSerror_handler SD_AOU_waveformGetMemorySize(ins.ID, id)

function memory_size(ins::InsAWGM320XA, wav::Waveform)
    #finding the id of the waveform object with which the waveform was loaded to RAM
    id = -1 #initializing id
    for key in keys(ins.waveforms)
        if ins.waveforms[key] == wav
            id = key
            break
        end
    end
    return memory_size(ins, id)
end

#function that returns properties of queued waveform
function getindex(wav::Waveform, ::Type{T},
                  ch::Integer) where {T<:WaveChProperty}
    return wav.ch_properties[ch][T]
end
