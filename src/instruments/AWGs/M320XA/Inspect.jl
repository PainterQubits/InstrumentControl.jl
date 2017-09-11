import Base: getindex

# overloaded getindex method for each channel-specific instrument property:
# acesses ins.channels for current configuration information
function getindex(ins::InsAWGM320XA, ::Type{T},
                  ch::Integer) where {T<:InstrumentProperty}
    return ins.channels[ch][T]
end

# overloaded getindex method for either non-channel specific properties, or a
# query for the channel specific properties of ALL channels (returned as an array)
# depending on the passed type T
function getindex(ins::InsAWGM320XA,
                  ::Type{T}) where {T<:InstrumentProperty}
    if T == SampleRate
        return @KSerror_handler SD_AOU_clockGetFrequency(ins.ID)
    else
        channels_list=[]
        for ch in keys(ins.channels)
            push!(channels_list, ins.channels[ch][T])
        end
        return channels_list
    end
end
