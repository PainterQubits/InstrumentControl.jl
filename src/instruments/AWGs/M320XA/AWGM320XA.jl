module AWGM320XA

using KeysightInstruments
KSI = KeysightInstruments

import Base: getindex, setindex!, show
importall InstrumentControl
import ICCommon: Stimulus,
    Response,
    source,
    measure,
    axisname,
    axislabel

export InsAWGM320XA


include("Core.jl")
include("Waveform.jl")
include("Properties.jl")
include("Configure.jl")
include("Inspect.jl")

awg_start(ins::InsAWGM320XA) = @KSerror_handler SD_AOU_AWGstart(ins.ID)
awg_is_run(ins::InsAWGM320XA) = @KSerror_handler SD_AOU_AWGisRunning(ins.ID)

#InstrumentException type defined in src/Definitions.jl in InstrumentControl
InstrumentException(ins::InsAWGM320XA, error_code::Integer) =
    InstrumentException(ins, error_code, keysight_error(error_code))

make(ins::InsAWGM320XA) = "Keysight"
model(ins::InsAWGM320XA) = ins.product_name

#Miscallenous
"""
    nums_to_mask(chs...)

Function that takes in integers which signify either: AWG channels to start/stop/etc,
or PXI trigger lines to send markers to, and outputs the integer mask that holds
that information. This integer mask, when converted to binary format, has 1's for
the passed integers, and 0 otherwise.
"""
function nums_to_mask(chs...)
    chs_vec = collect(chs)
    chs_vec = sort(chs_vec)
    length = size(chs_vec)[1]
    mask = "0b01"
    for i=0:(length-2)
        zeros_num = chs_vec[length-i]-chs_vec[length-i-1]-1
        if zeros_num>0
            zeros = repeat("0",zeros_num)
            mask = mask*zeros*"1"
        else
            mask = mask*"1"
        end
    end
    mask = mask*repeat("0",chs_vec[1]-1)
    mask = Int(parse(mask))
    return mask
end

end #module
