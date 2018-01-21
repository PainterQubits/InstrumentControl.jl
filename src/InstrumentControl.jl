__precompile__(true)
module InstrumentControl
importall ICCommon
import JSON, ZMQ
using ODBC, DataFrames, JuliaWebAPI
export Instrument, InstrumentProperty, Stimulus, Response
export source, measure

# Parse configuration file
include("config.jl")

# Define common types and shared functions
include("Definitions.jl")

# Define anything needed for a VISA instrument
include("VISA.jl")

# Parsing JSON files for easy VISA instrument onboarding
include("MetaprogrammingVISA.jl")

# Sweep and queueing functionality
include("Sweep.jl")

# Generate instrument properties based on template JSON files
# insjson parses the template files
# @generate_properties takes parsed information and makes InstrumentProperty types
# we generate the instrument property types in InstrumentControl so they are not
# module specific, and can be shared among different instrument modules
const dir = joinpath(dirname(dirname(@__FILE__)), "deps", "instruments") #directory of template files
const meta = Dict{String, Any}() #dictionary to hold parsed information of template files
for x in readdir(dir) #loop through all filenames in dir
    name = split(x, ".")[1] #get filename without extension: for use as key in meta
    meta[name] = insjson(joinpath(dir, x))
    @generate_properties meta[name]
end

# Various instrument modules
include(joinpath(dirname(@__FILE__), "instruments", "VNAs", "VNA.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "VNAs", "E5071C.jl"))
# include(joinpath("instruments","VNAs","ZNB20.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "SMB100A.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "E8257D.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "AWGs", "AWG5014C.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "AWGs", "M320XA", "AWGM320XA.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "GS200.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "Digitizers", "Alazar", "Alazar.jl"))
include(joinpath(dirname(@__FILE__), "instruments", "Digitizers", "M3102A", "DigitizerM3102A.jl"))

# Not required but you can uncomment this to look for conflicting function
# definitions that should be declared global and exported in InstrumentDefs.jl:

importall .AlazarModule
importall .AWG5014C
importall .E5071C
importall .E8257D
importall .GS200
importall .SMB100A
importall .AWGM320XA
importall .DigitizerM3102A
# importall .ZNB20Module

# Make Refs for objects that cannot be precompiled and must be instantiated on
# package load.

# ZeroMQ is used for communication between Julia processes, including the client process
# and the ICDataServer. See ZeroMQ documentation for further details.

const global ctx = Ref{ZMQ.Context}()
const global plotsock = Ref{ZMQ.Socket}()
const global api = Ref{APIInvoker{ZMQTransport,SerializedMsgFormat}}()
const global resourcemanager = Ref{UInt32}() #VISA instruments resource manager
const global sweepjobqueue = Ref{SweepJobQueue}() #default jobs queue

const global plotsockopened = Ref{Bool}(false)
const global apiopened = Ref{Bool}(false)

"""
    apiinvoker()
Opens a JuliaWebAPI.APIInvoker to communicate with the ICDataServer
"""
function apiinvoker()
    if !apiopened[]
        api[] = APIInvoker(
            ZMQTransport(confd["dbserver"], JuliaWebAPI.REQ, false, ctx[]),
            SerializedMsgFormat())
        apiopened[] = true
        # Now that the database server is connected, check that username is valid.
        validate_username(confd["username"])
    end
    return api[]
end

# Live plotting
function plotsocket()
    if !plotsockopened[]
        plotsock[] = ZMQ.Socket(ctx[], ZMQ.PUB)
        ZMQ.bind(plotsock[], "tcp://127.0.0.1:50002")
        plotsockopened[] = true
    end
    return plotsock[]
end

# Run at compile time. Initializes the ZMQ context for communication with ICDataServer,
# initializes a default SweepJobQueue object used for jobs queuing, and initializes
# a VISA instruments resource manager
function __init__()
    # ZeroMQ context for inter-process communication
    ctx[] = ZMQ.Context()

    # Set up and initialize a sweep queue.
    sweepjobqueue[] = SweepJobQueue()

    # Check for an environment variable ICTESTMODE. If it is set, then don't try to
    # use the VISA library. The purpose of this is simply that NI-VISA library cannot
    # be downloaded and installed with e.g. BinDeps, since it is behind a registration wall
    # on the National Instruments website only. Perhaps there is another VISA lib...
    if !haskey(ENV, "ICTESTMODE")
        # VISA resource manager
        resourcemanager[] = VISA.viOpenDefaultRM()
        apiinvoker()
    end
end

end
