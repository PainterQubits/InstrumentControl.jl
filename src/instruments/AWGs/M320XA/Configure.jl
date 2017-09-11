import Base: setindex!


"""
    configure_channels!(ins::InsAWGM320XA , num_of_channels::Integer = 4)

This function configures all channel properties to default settings (NOTE:
chosen by me Vinicius, eventually this will change to allow more initialization
flexibility for each user) and records them in the `ins.channels` dictionary. First,
the function sets `num_of_channels`, the number of channels on the AWG, as a global
constant of the module. Then, by looping through a list of channel numbers, the
function configures each channnel and populates the `ins.channels` dictionary with
the standard configuration settings: either through the instrument setindex! methods,
or by manually manipulating the dictionary itself for recording and using the instrument
native C functions to configure.
"""
function configure_channels!(ins::InsAWGM320XA , num_channels::Integer)
    for ch = 1:num_channels
        ins.channels[ch] = Dict{Any, Any}()
        ins.channels[ch][Queue] = Vector{Int}()
        #I configure these settings and populate ins.channels manually, instead of
        #using the overloaded setindex! methods, because some of these functions
        #only set two or more properties at once, so you can't just set one setting
        #individually without first having a record of the other setting
        @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch, 4000,
                        symbol_to_keysight(:Falling), symbol_to_keysight(:CLKsys))
        ins.channels[ch][TrigSource] = 0
        ins.channels[ch][TrigBehavior] = :Falling
        ins.channels[ch][TrigSync] = :CLKsys
        ins.channels[ch][AmpModGain] = 0
        ins.channels[ch][AngModGain] = 0
        ins.channels[ch][AmpModMode] = :NoMod
        ins.channels[ch][AngModMode] = :NoMod
    end
    ins[Amplitude] = 0
    ins[DCOffset] = 0
    ins[OutputMode] = :Off
    ins[FGFrequency] = 1e8
    ins[FGPhase] = 0
    ins[QueueCycleMode] = :Cyclic
    ins[QueueSyncMode] = :CLK10
    nothing
end


#Below are overloaded setindex! methods for each instrument property
function setindex!(ins::InsAWGM320XA, amplitude::Real,
                  ::Type{Amplitude}, ch::Integer)
    @KSerror_handler SD_AOU_channelAmplitude(ins.ID, ch, amplitude)
    ins.channels[ch][Amplitude] = amplitude
    nothing
end

function setindex!(ins::InsAWGM320XA, offset::Real,
                  ::Type{DCOffset}, ch::Integer)
    @KSerror_handler SD_AOU_channelOffset(ins.ID, ch, offset)
    ins.channels[ch][DCOffset] = offset
    nothing
end

function setindex!(ins::InsAWGM320XA, wav_type::Symbol,
                  ::Type{OutputMode}, ch::Integer)
    @KSerror_handler SD_AOU_channelWaveShape(ins.ID, ch, symbol_to_keysight(wav_type))
    ins.channels[ch][OutputMode] = wav_type
    nothing
end

function setindex!(ins::InsAWGM320XA, frequency::Real,
                  ::Type{FGFrequency}, ch::Integer)
    @KSerror_handler SD_AOU_channelFrequency(ins.ID, ch, frequency)
    ins.channels[ch][FGFrequency] = frequency
    nothing
end

function setindex!(ins::InsAWGM320XA, phase::Real,
                  ::Type{FGPhase}, ch::Integer)
    @KSerror_handler SD_AOU_channelPhase(ins.ID, ch, phase)
    ins.channels[ch][FGPhase] = phase
    nothing
end

function setindex!(ins::InsAWGM320XA, mode::Symbol, ::Type{AmpModMode},
                  ch::Integer)
    amp_gain = ins.channels[ch][AmpModGain]
    @KSerror_handler SD_AOU_modulationAmplitudeConfig(ins.ID, ch, symbol_to_keysight(mode),
                                                amp_gain)
    ins.channels[ch][AmpModMode] =  mode
    nothing
end

function setindex!(ins::InsAWGM320XA, amp_gain::Real, ::Type{AmpModGain},
                  ch::Integer)
    mode = ins.channels[ch][AmpModMode]
    @KSerror_handler SD_AOU_modulationAmplitudeConfig(ins.ID, ch, symbol_to_keysight(mode),
                                                amp_gain)
    ins.channels[ch][AmpModGain] =  amp_gain
    nothing
end

function setindex!(ins::InsAWGM320XA, mode::Symbol, ::Type{AngModMode},
                  ch::Integer)
    ang_gain = ins.channels[ch][AngModGain]
    @KSerror_handler SD_AOU_modulationAngleConfig(ins.ID, ch, symbol_to_keysight(mode),
                                                ang_gain)
    ins.channels[ch][AngModMode] =  mode
    nothing
end

function setindex!(ins::InsAWGM320XA, ang_gain::Real, ::Type{AngModGain},
                  ch::Integer)
    mode = ins.channels[ch][AngModMode]
    @KSerror_handler SD_AOU_modulationAmplitudeConfig(ins.ID, ch, symbol_to_keysight(mode),
                                                ang_gain)
    ins.channels[ch][AngModGain] =  ang_gain
    nothing
end

function setindex!(ins::InsAWGM320XA, PXI_trig_num::Integer,
                  ::Type{TrigSource}, ch::Integer)
    behavior = ins.channels[ch][TrigBehavior]
    sync = ins.channels[ch][TrigSync]
    @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch,
                                                PXI_trig_num + KSI.TRIG_PXI_AWG,
                            symbol_to_keysight(behavior), symbol_to_keysight(sync))
    ins.channels[ch][TrigSource] = PXI_trig_num
    nothing
end

function setindex!(ins::InsAWGM320XA, source::Symbol, ::Type{TrigSource}, ch::Integer)
    behavior = ins.channels[ch][TrigBehavior]
    sync = ins.channels[ch][TrigSync]
    @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch,
        symbol_to_keysight(source), symbol_to_keysight(behavior), symbol_to_keysight(sync))
    ins.channels[ch][TrigSource] = source
    nothing
end

function setindex!(ins::InsAWGM320XA, behavior::Symbol, ::Type{TrigBehavior}, ch::Integer)
    source = ins.channels[ch][TrigSource]
    sync = ins.channels[ch][TrigSync]
    if typeof(source) == Symbol
        @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch,
            symbol_to_keysight(source), symbol_to_keysight(behavior), symbol_to_keysight(sync))
    else
        @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch, source + 4000,
            symbol_to_keysight(behavior), symbol_to_keysight(sync))
    end
    ins.channels[ch][TrigBehavior] = behavior
    nothing
end

function setindex!(ins::InsAWGM320XA, sync::Symbol, ::Type{TrigSync}, ch::Integer)
    source = ins.channels[ch][TrigSource]
    behavior = ins.channels[ch][TrigBehavior]
    if typeof(source) == Symbol
        @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch,
            symbol_to_keysight(source), symbol_to_keysight(behavior), symbol_to_keysight(sync))
    else
        @KSerror_handler SD_AOU_AWGtriggerExternalConfig(ins.ID, ch, source + 4000,
            symbol_to_keysight(behavior), symbol_to_keysight(sync))
    end
    ins.channels[ch][TrigSync] = sync
    nothing
end

function setindex!(ins::InsAWGM320XA, cycle_mode::Symbol,
                  ::Type{QueueCycleMode}, ch::Integer)
    @KSerror_handler SD_AOU_AWGqueueConfig(ins.ID, ch, symbol_to_keysight(cycle_mode))
    ins.channels[ch][QueueCycleMode] = cycle_mode
    nothing
end

function setindex!(ins::InsAWGM320XA, sync_mode::Symbol,
                  ::Type{QueueSyncMode}, ch::Integer)
    @KSerror_handler SD_AOU_AWGqueueSyncMode(ins.ID, ch,
                                           symbol_to_keysight(sync_mode))
    ins.channels[ch][QueueSyncMode] = sync_mode
    nothing
end

#this method configures T for some channels passed
function setindex!(ins::InsAWGM320XA, property_val::Any,
                  ::Type{T}, chs::Vararg{Integer}) where {T<:InstrumentProperty}
    for ch in chs
        setindex!(ins,property_val,T,ch)
    end
    nothing
end

# method configures T for all channels to be the passed property_val argument
function setindex!(ins::InsAWGM320XA, property_val::Any,
                  ::Type{T}) where {T<:InstrumentProperty}
    for ch in keys(ins.channels)
        setindex!(ins,property_val,T,ch)
    end
    nothing
end
