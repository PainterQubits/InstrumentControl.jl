## Auxiliary IO

auxmode(m::U32, b::Bool) = begin
    if b
        m | Alazar.AUX_OUT_TRIGGER_ENABLE
    else
        m & ~Alazar.AUX_OUT_TRIGGER_ENABLE
    end
end

function configure(a::InstrumentAlazar, aux::Type{AuxOutputTrigger})
    val = code(a,aux)
    val = auxmode(val, a.auxOutTriggerEnable)

    @eh2 AlazarConfigureAuxIO(a.handle, val, U32(0))
    a.auxIOMode = val
    nothing
end

function configure(a::InstrumentAlazar, aux::Type{AuxDigitalInput})
    val = code(a,aux)

    @eh2 AlazarConfigureAuxIO(a.handle, val, U32(0))
    a.auxIOMode = val
    nothing
end

function configure{T<:TriggerSlope}(a::InstrumentAlazar,
        aux::Type{AuxInputTriggerEnable}, trigSlope::Type{T})
    val = code(a,aux)
    val2 = code(a,trigSlope)

    @eh2 AlazarConfigureAuxIO(a.handle, val, val2)
    a.auxIOMode = val
    a.auxInTriggerSlope = val2
    nothing
end

function configure(a::InstrumentAlazar,
        aux::Type{AuxOutputPacer}, divider::Integer)
    val = code(a,aux)
    val = auxmode(val, a.auxOutTriggerEnable)

    @assert divider > 2 "Divider needs to be > 2."
    @eh2 AlazarConfigureAuxIO(a.handle, val, U32(divider))
    a.auxIOMode = val
    a.auxOutDivider = divider
    nothing
end

function configure(a::InstrumentAlazar,
        aux::Type{AuxDigitalOutput}, level::Integer)
    val = code(a,aux)
    val = auxmode(val, a.auxOutTriggerEnable)
    @eh2 AlazarConfigureAuxIO(a.handle, val, U32(level))
    a.auxIOMode = val
    a.auxOutTTLLevel = level
    nothing
end

function configure(a::InstrumentAlazar,
                    ::Type{AuxSoftwareTriggerEnabled}, b::Bool)
    m = auxmode(a.auxIOMode,b)
    a.auxOutTriggerEnable = b

    if a.auxIOMode == AUX_OUT_TRIGGER
        p = U32(0)
    elseif a.auxIOMode == AUX_OUT_PACER
        p = a.auxOutDivider
    elseif a.auxIOMode == AUX_OUT_SERIAL_DATA
        p = a.auxOutTTLLevel
    else
        warn("Inoperative unless an aux output mode is configured.")
        return nothing
    end

    @eh2 AlazarConfigureAuxIO(a.handle, m, p)
    nothing
end

## Buffers ##########

function configure(a::InstrumentAlazar, ::Type{RecordCount}, count)
    @eh2 AlazarSetRecordCount(a.handle, count)
    nothing
end

## Channels ##########

# Some logic for the following is a bit specialized to the ATS9360
function configure{T<:AlazarChannel}(a::InstrumentAlazar, ch::Type{T})
    ch == AlazarChannel && error("You must choose a channel.")
    a.acquisitionChannel = U32(code(a,ch))
    a.channelCount = 1
    nothing
end

function configure(a::InstrumentAlazar, ch::Type{BothChannels})
    a.acquisitionChannel = U32(code(a,ch))
    a.channelCount = 2
    nothing
end

## Clocks ############

function configure{T<:SampleRate}(a::InstrumentAlazar, rate::Type{T})
    rate == SampleRate && error("Choose a sample rate.")

    val = code(a,rate)

    @eh2 AlazarSetCaptureClock(a.handle,
                               Alazar.INTERNAL_CLOCK, val, a.clockSlope, 0)

    a.clockSource = Alazar.INTERNAL_CLOCK
    a.sampleRate = val
    a.decimation = 0
    nothing
end

function configure{T<:ClockSlope}(a::InstrumentAlazar, slope::Type{T})
    slope == ClockSlope && error("Choose a clock slope.")

    val = code(a,slope)

    @eh2 AlazarSetCaptureClock(a.handle,
                               a.clockSource,
                               a.sampleRate,
                               val,
                               a.decimation)
    a.clockSlope = val
    nothing
end

## Data packing #########

function configure{S<:AlazarDataPacking}(
        a::InstrumentAlazar, ::Type{AlazarDataPacking},
        pack::Type{S}, ch::Type{ChannelA})

    chcode = Alazar.CHANNEL_A

    pk = code(a,pack)

    @eh2 AlazarSetParameter(a.handle, chcode, Alazar.PACK_MODE, pk)
    a.packingA = pk
    nothing
end

function configure{S<:AlazarDataPacking}(
        a::InstrumentAlazar, ::Type{AlazarDataPacking},
        pack::Type{S}, ch::Type{ChannelB})

    chcode = Alazar.CHANNEL_B

    pk = code(a,pack)

    @eh2 AlazarSetParameter(a.handle, chcode, Alazar.PACK_MODE, pk)
    a.packingB = pk
    nothing
end

function configure{S<:AlazarDataPacking}(
        a::InstrumentAlazar, ::Type{AlazarDataPacking},
        pack::Type{S}, ch::Type{BothChannels})

    map((c)->configure(a,AlazarDataPacking,pack,c), (ChannelA, ChannelB))
    nothing
end

## Miscellaneous ######

function configure(a::InstrumentAlazar, ::Type{LED}, ledState::Bool)
    @eh2 AlazarSetLED(a.handle, ledState)
    nothing
end

function configure(a::InstrumentAlazar, ::Type{Sleep}, sleepState)
    @eh2 AlazarSleepDevice(a.handle, sleepState)
    nothing
end

# not supported by ATS310, 330, 850.
function configure{T<:AlazarTimestampReset}(a::InstrumentAlazar, t::Type{T})
    (t == AlazarTimestampReset) && error("Choose TimestampReset[Once|Always]")
    option = code(a,t)
    @eh2 AlazarResetTimeStamp(a.handle, option)
    nothing
end

## Trigger engine ###########

function configure{T<:AlazarTriggerEngine}(a::InstrumentAlazar, engine::Type{T})
    eng = code(a,engine)
    set_triggeroperation(a, eng,
        a.channelJ, a.slopeJ, a.levelJ,
        a.channelK, a.slopeK, a.levelK)
    nothing
end

function configure{S<:TriggerSlope,T<:TriggerSlope}(
    a::InstrumentAlazar, slopeJ::Type{S}, slopeK::Type{T})

    sJ = code(a,slopeJ)
    sK = code(a,slopeK)
    set_triggeroperation(a, a.engine,
        a.channelJ, sJ, a.levelJ,
        a.channelK, sK, a.levelK)
    nothing
end

function configure{S<:TriggerSource,T<:TriggerSource}(a::InstrumentAlazar,
        sourceJ::Type{S}, sourceK::Type{T})

    sJ = code(a,sourceJ)
    sK = code(a,sourceK)
    set_triggeroperation(a, a.engine,
        sJ, a.slopeJ, a.levelJ,
        sK, a.slopeK, a.levelK)
    nothing
end

function configure(a::InstrumentAlazar, ::Type{TriggerLevel}, levelJ, levelK)
    set_triggeroperation(a.handle, a.engine,
        a.channelJ, a.slopeJ, levelJ,
        a.channelK, a.slopeK, levelK)
    nothing
end

function configure{T<:Coupling}(a::InstrumentAlazar, coupling::Type{T})
    coup = code(a,coupling)
    @eh2 AlazarSetExternalTrigger(a.handle, coup, a.triggerRange)
    nothing
end

function configure{T<:AlazarTriggerRange}(a::InstrumentAlazar, range::Type{T})
    rang = code(a,range)
    @eh2 AlazarSetExternalTrigger(a.handle, a.coupling, rang)
    nothing
end

function configure(a::InstrumentAlazar, ::Type{TriggerDelaySamples}, delay_samples)
    @eh2 AlazarSetTriggerDelay(a.handle, delay_samples)
    a.triggerDelaySamples = delay_samples
    nothing
end

function configure(a::InstrumentAlazar, ::Type{TriggerTimeoutTicks}, ticks)
    @eh2 AlazarSetTriggerTimeOut(a.handle, ticks)
    a.triggerTimeoutTicks = ticks
    nothing
end

function configure(a::InstrumentAlazar, ::Type{TriggerTimeoutS}, timeout_s)
    configure(a, TriggerTimeoutTicks, ceil(timeout_s * 1.e5))
end
