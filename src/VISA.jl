## Imports
import VISA
import Base: read, write, readavailable, reset, wait
import Base: cp, mkdir, readdir, rm

## Get the resource manager
"The default VISA resource manager."
const  resourcemanager = VISA.viOpenDefaultRM()
export resourcemanager

## InstrumentVISA type
export InstrumentVISA

## Finding and obtaining resources
export findresources
export gpib, tcpip_instr, tcpip_socket

## Reading and writing
export ask, read, write, readavailable
export binblockwrite, binblockreadavailable

## Common VISA commands
export tst, rst, idn, cls
export trg, abor, wait, errors

## Convenience
export quoted, unquoted

## Instrument directory manipulation
export cp
export mkdir
export readdir
export rm

"""
Abstract supertype of all Instruments addressable using a VISA library.
Concrete types are expected to have fields:

`vi::ViSession`

`writeTerminator::ASCIIString`
"""
abstract InstrumentVISA <: Instrument

## Finding and obtaining resources

"Finds VISA resources to which we can connect. Doesn't seem to find ethernet instruments."
findresources(expr::AbstractString="?*::INSTR") = VISA.viFindRsrc(resourcemanager, expr)

"""
Returns a `viSession` for the given GPIB primary address using board 0.
See VISA spec for details on what a `viSession` is.
"""
gpib(primary) = VISA.viOpen(resourcemanager, "GPIB::"*primary*"::0::INSTR")

"""
Returns a `viSession` for the given GPIB board and primary address.
See VISA spec for details on what a `viSession` is.
"""
gpib(board, primary) = VISA.viOpen(
    resourcemanager, "GPIB"*(board == 0 ? "" : board)+"::"*primary*"::0::INSTR")

"""
Returns a `viSession` for the given GPIB board, primary, and secondary address.
See VISA spec for details on what a `viSession` is.
"""
gpib(board, primary, secondary) = VISA.viOpen(resourcemanager,
    "GPIB"*(board == 0 ? "" : board)*"::"+primary+"::"+secondary+"::INSTR")

"Returns a INSTR `viSession` for the given IPv4 address string."
tcpip_instr(ip) = VISA.viOpen(resourcemanager, "TCPIP::"*ip*"::INSTR")

"Returns a raw socket `viSession` for the given IPv4 address string."
tcpip_socket(ip,port) = VISA.viOpen(resourcemanager,
    "TCPIP0::"*ip*"::"*string(port)*"::SOCKET")

## Reading and writing

"""Idiomatic "write and read available" function with optional delay."""
function ask(ins::InstrumentVISA, msg::ASCIIString, infixes...; delay::Real=0)
    write(ins, msg, infixes...)
    sleep(delay)
    readavailable(ins)
end

"""
Read from an instrument. Strips trailing carriage returns and new lines.
Note that this function will only read so many characters (buffered).
"""
read(ins::InstrumentVISA) =
    rstrip(bytestring(VISA.viRead(ins.vi)), ['\r', '\n'])

"""
Write to an instrument.
Replaces hash signs with infixes and appends the instrument's write terminator.
"""
function write(ins::InstrumentVISA, msg::ASCIIString, infixes...)
    for infix in infixes
        msg = replace(msg, "#", infix, 1)
    end
    msg == "" && return nothing
    VISA.viWrite(ins.vi, string(msg, ins.writeTerminator))
    return nothing
end

"Keep reading from an instrument until the instrument says we are done."
readavailable(ins::InstrumentVISA) =
    rstrip(bytestring(VISA.readAvailable(ins.vi)), ['\r','\n'])

"""
Write an IEEE header block followed by an arbitary sequency of bytes and the terminator.
"""
binblockwrite(ins::InstrumentVISA,
    message::Union{ASCIIString, Vector{UInt8}}, data::Vector{UInt8}) =
    VISA.binBlockWrite(ins.vi, message, data, ins.writeTerminator)

"Read an entire block of bytes with properly formatted IEEE header."
binblockreadavailable(ins::InstrumentVISA) = VISA.binBlockReadAvailable(ins.vi)

## IEEE standard commands

"Test with the *TST? command."
tst(ins::InstrumentVISA)        = write(ins, "*TST?")

"Reset with the *RST command."
rst(ins::InstrumentVISA)        = write(ins, "*RST")

"Ask the *IDN? command."
idn(ins::InstrumentVISA)        = ask(ins, "*IDN?")

"Clear registers with *CLS."
cls(ins::InstrumentVISA)        = write(ins, "*CLS")

"Bus trigger with *TRG."
trg(ins::InstrumentVISA)        = write(ins, "*TRG")

"Wait for completion of a sweep."
wait(ins::InstrumentVISA)       = write(ins, "*WAI")

# Useful common commands

"Abort triggering with ABOR."
abor(ins::InstrumentVISA)       = write(ins, "ABOR")

"""
Interrogate errors using `:SYST:ERR?` and raise an `InstrumentException`
if appropriate. Otherwise, return `nothing`.

The `maxerrors` optional argument prevents this function from querying
the instrument forever if there is some unexpected trouble.
"""
function errors(ins::InstrumentVISA, maxerrors=100)
    i, res = 0, split(ask(ins, ":SYST:ERR?"), ",")
    if parse(res[1])::Int != 0
        codes = Int64[]
        strings = UTF8String[]
        while (i < maxerrors && parse(res[1])::Int != 0)
            push!(codes, parse(res[1])::Int)
            push!(strings, res[2])
            res = split(ask(ins, ":SYST:ERR?"),",")
            i+=1
        end
        throw(InstrumentException(ins, codes, strings))
    end
    nothing
end

## Convenient functions for parsing and sending strings.

"Surround a string in quotation marks."
quoted(str::ASCIIString) = "\""*str*"\""

"Strip a string of enclosing quotation marks."
unquoted(str::ASCIIString) = strip(str,['"','\''])


## Convenient functions for querying arrays of numbers.

"Retreive and parse a delimited string into an `Array{Float64,1}`."
function getdata(ins::InstrumentVISA, ::Type{TransferFormat{ASCIIString}},
        cmd, infixes...; delim=",")
    for infix in infixes
        cmd = replace(cmd, "#", infix, 1)
    end
    data = ask(ins, cmd)
    [parse(x)::Float64 for x in split(data, delim)]
end

"""
Parse a binary block, taking care of float size and byte ordering.
Return type is always `Array{Float64,1}` regardless of transfer format.
"""
function getdata{T<:Number}(ins::InstrumentVISA,
        ::Type{TransferFormat{T}}, cmd, infixes...)
    for infix in infixes
        cmd = replace(cmd, "#", infix, 1)
    end
    write(ins, cmd)
    io = binblockreadavailable(ins)

    endian = inspect(ins, TransferByteOrder)
    _conv = (endian == LittleEndianTransfer ? ltoh : ntoh)

    bytes = sizeof(T)
    nsam = Int(floor((io.size-(io.ptr-1))/bytes))

    array = Vector{Float64}(nsam)
    for i=1:nsam
        array[i] = (_conv)(read(io, T))
    end

    array
end


## File management

"""
MMEMory:COPY
[E5071C](http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/memory/scpi_mmemory_copy.htm)
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_5/Content/d36e87048.htm)

Copy a file.
"""
function cp(ins::InstrumentVISA, src::AbstractString, dest::AbstractString)
    write(ins, "MMEMory:COPY "*quoted(src)*","*quoted(dest))
end

"""
MMEMory:MDIRectory
[E5071C](http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/memory/scpi_mmemory_mdirectory.htm)
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_5/Content/d36e89416.htm)

Make a directory.
"""
function mkdir(ins::InstrumentVISA, dir::AbstractString)
    write(ins, "MMEMory:MDIRectory "*quoted(dir))
end

"""
MMEMory:CATalog?
[E5071C](http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/memory/scpi_mmemory_catalog_dir.htm)
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_5/Content/7f7650b75a604b3d.htm)

Read the directory contents.
"""
function readdir(ins::InstrumentVISA, dir::AbstractString="")
    cmd = "MMEMory:CATalog?"
    if dir != ""
        cmd = cmd*" "*quoted(dir)
    end
    ask(ins, cmd)
end

"""
MMEMory:DELete
[E5071C](http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/memory/scpi_mmemory_delete.htm)
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_5/Content/d36e87202.htm)

Remove a file.
"""
function rm(ins::InstrumentVISA, file::AbstractString)
    write(ins, "MMEMory:DELete "*quoted(file))
end

## Data transfer formats
"""
FORMAT:BORDER
[E5071C][http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/format/scpi_format_border.htm]
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_6/Content/d36e85486.htm)

Configure the transfer byte order: `LittleEndianTransfer`, `BigEndianTransfer`.
"""
function configure{T<:TransferByteOrder}(ins::InstrumentVISA, ::Type{T})
    write(ins, "FORMat:BORDer "*code(ins, T))
end

"""
FORMAT:DATA
[E5071C][http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/format/scpi_format_data.htm]
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_6/Content/d36e85516.htm)

Configures the data transfer format:
`TransferFormat{ASCIIString}`, `TransferFormat{Float32}`,
`TransferFormat{Float64}`.
For the latter two the byte order should also be considered.
"""
function configure{T<:TransferFormat}(ins::InstrumentVISA, ::Type{T})
    write(ins, "FORMat:DATA "*code(ins, T))
end

"""
FORMAT:BORDER
[E5071C][http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/format/scpi_format_border.htm]
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_6/Content/d36e85486.htm)

Configure the transfer byte order: `LittleEndianTransfer`, `BigEndianTransfer`.
"""
function inspect(ins::InstrumentVISA, ::Type{TransferByteOrder})
    TransferByteOrder(ins, ask(ins, "FORMat:BORDer?"))
end

"""
FORMAT:DATA
[E5071C][http://ena.support.keysight.com/e5071c/manuals/webhelp/eng/programming/command_reference/format/scpi_format_data.htm]
[ZNB20](https://www.rohde-schwarz.com/webhelp/znb_znbt_webhelp_en_6/Content/d36e85516.htm)

Inspect the data transfer format. The byte order should also be considered.
"""
function inspect(ins::InstrumentVISA, ::Type{TransferFormat})
    TransferFormat(ins, ask(ins, "FORMat:DATA?"))
end
