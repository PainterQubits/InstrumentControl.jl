import Base: show, showerror

export Averaging
export AveragingFactor
export AveragingTrigger
export FrequencyStart, FrequencyStop
export SampleRate, SweepTime
export Timeout
export InstrumentException
export @KSerror_handler
export Amplitude

# Miscellaneous stuff
export VNA
export make, model

"How to display an instrument, e.g. in an error."
show(io::IO, x::Instrument) = print(io, make(x), " ", model(x))

"Returns the instrument's manufacturer."
function make end

"Returns the instrument's model."
function model end

abstract type Averaging <: InstrumentProperty end
abstract type AveragingFactor <: InstrumentProperty end
abstract type AveragingTrigger <: InstrumentProperty end

abstract type FrequencyStart <: InstrumentProperty end
abstract type FrequencyStop <: InstrumentProperty end

"The sample rate for digitizing, synthesizing, etc."
abstract type SampleRate <: InstrumentProperty end

abstract type SweepTime <: InstrumentProperty end

"Time to wait for an instrument to reply before bailing out."
abstract type Timeout <: InstrumentProperty end

"""
Amplitude for a given channel.
"""
abstract type Amplitude <: InstrumentProperty end

"""
Exception to be thrown by an instrument. Fields include the instrument in error
`ins::Instrument`, the error code `val::Int64`, and a `humanReadable` Unicode
string.
"""
mutable struct InstrumentException <: Exception
    ins::Instrument
    val::Array{Int,1}
    humanReadable::Array{AbstractString,1}
end

"Simple method for when there is just one error."
InstrumentException(ins::Instrument, val::Integer, hr::AbstractString) =
    InstrumentException(ins, Int[val], AbstractString[hr])

function showerror(io::IO, e::InstrumentException)
    if length(e.val) != length(e.humanReadable)
        print(io, "Error in determining the errors of $(e.ins).")
    else
        println(io,"Instrument $(e.ins) had errors:")
        for i in 1:length(e.val)
            println(io,"    $((e.val)[i]): $((e.humanReadable)[i])")
        end
    end
end


"""
    @KSerror_handler(expr)

Takes an KeysightInstruments API call and brackets it with some error checking.
Throws an InstrumentException if there is an error. This macro is compatible with
all SD_AOU functions, most but not all SD_Module functions, and it is NOT compatible
with SD_Wave functions
"""
macro KSerror_handler(expr) #Keysight Error Handler
    quote
        SD_call_result = $(esc(expr))
        if typeof(SD_call_result) <: Integer
            SD_call_result < 0 &&
            #the expression will be a call to a KeysightInstruments SD function,
            #where the function signature will be SD_name(ins.ID, args...);
            # expr.args[2] is ins.ID; expr.args[2].args[1] is ins
            throw(InstrumentException($(esc(expr.args[2].args[1])), SD_call_result))
        end
        SD_call_result
    end
end
