import Base: setindex!


"""
    configure_channels!(ins::InsDigitizerM3102A , num_of_channels::Integer)

This function configures all channel properties to default settings (NOTE:
chosen by me Vinicius, eventually this will change to allow more initialization
flexibility for each user) and records them in the `ins.channels` dictionary. First,
the function sets `num_of_channels`, the number of channels on the digitizer, as a global
constant of the module. Then, by looping through a list of channel numbers, the
function configures each channnel and populates the `ins.channels` dictionary with
the standard configuration settings: either through the instrument setindex! methods,
or by manually manipulating the dictionary itself for recording and using the instrument
native C functions to configure.
"""
function configure_channels!(ins::InsDigitizerM3102A, num_channels::Integer)
    for ch = 1:num_channels
        ins.channels[ch] = Dict{Any, Any}()
        #I configure these settings and populate ins.channels manually, instead of
        #using the overloaded setindex! methods, because some of these functions
        #only set two or more properties at once, so you can't just set one setting
        #individually without first having a record of the other setting
        @KSerror_handler SD_AIN_channelInputConfig(ins.ID, ch, 0.2,  #NEEDS TO BE CHANGED!!
            symbol_to_keysight(:Ohm_50), symbol_to_keysight(:AC))
        ins.channels[ch][ChInputMode] = :AC
        ins.channels[ch][ChScale] = 0.2
        ins.channels[ch][ChImpedance] = :Ohm_50
        @KSerror_handler SD_AIN_channelTriggerConfig(ins.ID, ch,
                                            symbol_to_keysight(:RisingAnalog), 2)
        ins.channels[ch][ChAnalogTrigBehavior] = :RisingAnalog
        ins.channels[ch][ChAnalogTrigThreshold] = 2
        @KSerror_handler SD_AIN_DAQconfig(ins.ID, ch, 1000, 0, 0, symbol_to_keysight(:Analog))
        ins.channels[ch][DAQTrigMode] = :Analog
        ins.channels[ch][DAQCycles] = 0
        ins.channels[ch][DAQTrigDelay] = 0
        ins.channels[ch][DAQPointsPerCycle] = 1000
        @KSerror_handler SD_AIN_DAQtriggerExternalConfig(ins.ID, ch, 0, symbol_to_keysight(:Rising))
        ins.channels[ch][DAQTrigSource] = :PXI
        ins.channels[ch][DAQTrigBehavior] = :Rising
    end
    ins[ChPrescaler] = 0
    ins[DAQAnalogTrigSource] = 1
    nothing
end

#Below are overloaded setindex! methods for each instrument property
function setindex!(ins::InsDigitizerM3102A, fullscale::Real,
                  ::Type{ChScale}, ch::Integer)
    mode = ins.channels[ch][ChInputMode]
    impedance = ins.channels[ch][ChImpedance]
    @KSerror_handler SD_AIN_channelInputConfig(ins.ID, ch, fullscale,
                        symbol_to_keysight(impedance), symbol_to_keysight(mode))
    ins.channels[ch][ChScale] = fullscale
    nothing
end

function setindex!(ins::InsDigitizerM3102A, mode::Symbol,
                  ::Type{ChInputMode}, ch::Integer)
    fullscale = ins.channels[ch][ChScale]
    impedance = ins.channels[ch][ChImpedance]
    @KSerror_handler SD_AIN_channelInputConfig(ins.ID, ch, fullscale,
                        symbol_to_keysight(impedance), symbol_to_keysight(mode))
    ins.channels[ch][ChInputMode] = mode
    nothing
end

function setindex!(ins::InsDigitizerM3102A, impedance::Symbol,
                  ::Type{ChImpedance}, ch::Integer)
    fullscale = ins.channels[ch][ChScale]
    mode = ins.channels[ch][ChInputMode]
    @KSerror_handler SD_AIN_channelInputConfig(ins.ID, ch, fullscale,
                        symbol_to_keysight(impedance), symbol_to_keysight(mode))
    ins.channels[ch][ChImpedance] = impedance
    nothing
end

function setindex!(ins::InsDigitizerM3102A, prescaler::Integer,
                  ::Type{ChPrescaler}, ch::Integer)
    @KSerror_handler SD_AIN_channelPrescalerConfig(ins.ID, ch, prescaler)
    ins.channels[ch][ChPrescaler] = prescaler
    nothing
end

function setindex!(ins::InsDigitizerM3102A, trig_mode::Symbol,
                  ::Type{ChAnalogTrigBehavior}, ch::Integer)
    threshold = ins.channels[ch][ChAnalogTrigThreshold]
    @KSerror_handler SD_AIN_channelTriggerConfig(ins.ID, ch,
                                        symbol_to_keysight(trig_mode), threshold)
    ins.channels[ch][ChAnalogTrigBehavior] = trig_mode
    nothing
end

function setindex!(ins::InsDigitizerM3102A, threshold::Real,
                  ::Type{ChAnalogTrigThreshold}, ch::Integer)
    trig_mode = ins.channels[ch][ChAnalogTrigBehavior]
    @KSerror_handler SD_AIN_channelTriggerConfig(ins.ID, ch,
                                        symbol_to_keysight(trig_mode), threshold)
    ins.channels[ch][ChAnalogTrigThreshold] = threshold
    nothing
end

function setindex!(ins::InsDigitizerM3102A, daq_mode::Symbol,
                  ::Type{DAQTrigMode}, ch::Integer)
    daq_delay = ins.channels[ch][DAQTrigDelay]
    cycle_points = ins.channels[ch][DAQPointsPerCycle]
    daq_cycles = ins.channels[ch][DAQCycles]
    @KSerror_handler SD_AIN_DAQconfig(ins.ID, ch, cycle_points, daq_cycles, daq_delay,
                                    symbol_to_keysight(daq_mode))
    ins.channels[ch][DAQTrigMode] = daq_mode
    nothing
end

function setindex!(ins::InsDigitizerM3102A, daq_delay::Integer,
                  ::Type{DAQTrigDelay}, ch::Integer)
    daq_mode = ins.channels[ch][DAQTrigMode]
    cycle_points = ins.channels[ch][DAQPointsPerCycle]
    daq_cycles = ins.channels[ch][DAQCycles]
    @KSerror_handler SD_AIN_DAQconfig(ins.ID, ch, cycle_points, daq_cycles, daq_delay,
                                    symbol_to_keysight(daq_mode))
    ins.channels[ch][DAQTrigDelay] = daq_delay
    nothing
end

function setindex!(ins::InsDigitizerM3102A, cycle_points::Integer,
                  ::Type{DAQPointsPerCycle}, ch::Integer)
    daq_mode = ins.channels[ch][DAQTrigMode]
    daq_delay = ins.channels[ch][DAQTrigDelay]
    daq_cycles = ins.channels[ch][DAQCycles]
    @KSerror_handler SD_AIN_DAQconfig(ins.ID, ch, cycle_points, daq_cycles, daq_delay,
                                    symbol_to_keysight(daq_mode))
    ins.channels[ch][DAQPointsPerCycle] = cycle_points
    nothing
end

function setindex!(ins::InsDigitizerM3102A, daq_cycles::Integer,
                  ::Type{DAQCycles}, ch::Integer)
    daq_mode = ins.channels[ch][DAQTrigMode]
    daq_delay = ins.channels[ch][DAQTrigDelay]
    cycle_points = ins.channels[ch][DAQPointsPerCycle]
    @KSerror_handler SD_AIN_DAQconfig(ins.ID, ch, cycle_points, daq_cycles, daq_delay,
                                    symbol_to_keysight(daq_mode))
    ins.channels[ch][DAQCycles] = daq_cycles
    nothing
end

function setindex!(ins::InsDigitizerM3102A, source::Symbol,
                  ::Type{DAQTrigSource}, ch::Integer)
    behavior = ins.channels[ch][DAQTrigBehavior]
    @KSerror_handler SD_AIN_DAQtriggerExternalConfig(ins.ID, ch,
            symbol_to_keysight(source), symbol_to_keysight(behavior))
    ins.channels[ch][DAQTrigSource] = source
    nothing
end

function setindex!(ins::InsDigitizerM3102A, PXI_trig_num::Integer,
                  ::Type{DAQTrigSource}, ch::Integer)
    behavior = ins.channels[ch][DAQTrigBehavior]
    @KSerror_handler SD_AIN_DAQtriggerExternalConfig(ins.ID, ch, PXI_trig_num, #+4000?
                                                   symbol_to_keysight(behavior))
    ins.channels[ch][DAQTrigSource] = source
    nothing
end

# function setindex!(ins::InsDigitizerM3102A, number::Integer,
#                   ::Type{DAQTrigPXINumber}, ch::Integer)
#     source = ins.channels[ch][DAQTrigSource]
#     behavior = ins.channels[ch][DAQTrigBehavior]
#     @KSerror_handler SD_AIN_DAQdigitalTriggerConfig(ins.ID, ch, symbol_to_keysight(source),
#                                    number, symbol_to_keysight(behavior))
#     ins.channels[ch][DAQTrigPXINumber] = number
#     nothing
# end

#fix fix fix fix
function setindex!(ins::InsDigitizerM3102A, behavior::Symbol,
                  ::Type{DAQTrigBehavior}, ch::Integer)
    source= ins.channels[ch][DAQTrigSource]
    if typeof(source) == Symbol
        @KSerror_handler SD_AIN_DAQtriggerExternalConfig(ins.ID, ch,
            symbol_to_keysight(source), symbol_to_keysight(behavior))
    else
        @KSerror_handler SD_AIN_DAQtriggerExternalConfig(ins.ID, ch, source, # + 4000?
            symbol_to_keysight(behavior))
    end
    ins.channels[ch][DAQTrigBehavior] = behavior
    nothing
end

function setindex!(ins::InsDigitizerM3102A, number::Integer,
                  ::Type{DAQAnalogTrigSource}, ch::Integer)
    @KSerror_handler SD_AIN_DAQanalogTriggerConfig(ins.ID,ch,number)
    ins.channels[ch][DAQAnalogTrigSource] = number
    nothing
end

# method configures T for all channels to be the passed property_val argument
function setindex!(ins::InsDigitizerM3102A, property_val::Any,
                  ::Type{T}) where {T<:InstrumentProperty}
    for ch in keys(ins.channels)
        setindex!(ins,property_val,T,ch)
    end
    nothing
end
