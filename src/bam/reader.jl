# BAM Reader
# ==========

type BAMReader <: Bio.IO.AbstractParser
    filepath::String
    stream::BGZFStream
    header::BAMHeader
    index::Nullable{BAI}
end

function header(reader::BAMReader)
    return reader.header
end

function Base.eof(reader::BAMReader)
    return eof(reader.stream)
end

function Base.close(reader::BAMReader)
    close(reader.stream)
end

function Base.seek(reader::BAMReader, voffset::VirtualOffset)
    seek(reader.stream, voffset)
end

function Base.open(filename::AbstractString, ::Type{BAM})
    stream = BGZFStream(filename)

    # magic bytes
    B = read(stream, UInt8)
    A = read(stream, UInt8)
    M = read(stream, UInt8)
    x = read(stream, UInt8)
    if B != UInt8('B') || A != UInt8('A') || M != UInt8('M') || x != 0x01
        error("input was not a valid BAM file")
    end

    # SAM header
    textlen = read(stream, Int32)
    samheader = parse_samheader(read(stream, UInt8, textlen))

    # reference sequences
    refseqnames = String[]
    refseqlens = Int[]
    n_refs = read(stream, Int32)
    for _ in 1:n_refs
        namelen = read(stream, Int32)
        data = read(stream, UInt8, namelen)
        seqname = unsafe_string(pointer(data))
        seqlen = read(stream, Int32)
        push!(refseqnames, seqname)
        push!(refseqlens, seqlen)
    end

    reader = BAMReader(
        filename,
        stream,
        BAMHeader(samheader, refseqnames, refseqlens),
        Nullable())

    index_filepath = reader.filepath * ".bai"
    if isfile(index_filepath)
        loadindex!(reader, index_filepath)
    end

    return reader
end

function Base.read!(reader::BAMReader, aln::BAMRecord)
    datasize = read(reader.stream, Int32) - BAM_FIXED_FIELDS_BYTES
    unsafe_read(reader.stream, pointer_from_objref(aln), BAM_FIXED_FIELDS_BYTES)
    if length(aln.data) < datasize
        resize!(aln.data, datasize)
    end
    unsafe_read(reader.stream, pointer(aln.data), datasize)
    aln.datasize = datasize
    aln.header = reader.header
    return aln
end

type BAMIntersectionIterator
    reader::BAMReader
    chunks::Vector{Chunk}
    refid::Int
    interval::UnitRange{Int}
end

function Base.start(iter::BAMIntersectionIterator)
    rec = BAMRecord()
    return advance!(iter, rec, 1)
end

function Base.done(iter::BAMIntersectionIterator, i_rec)
    i, _ = i_rec
    return i > endof(iter.chunks)
end

function Base.next(iter::BAMIntersectionIterator, i_rec)
    i, rec = i_rec
    retrec = deepcopy(rec)
    return retrec, advance!(iter, rec, i)
end

function advance!(iter, rec, i)
    while i ≤ endof(iter.chunks)
        chunk = iter.chunks[i]
        while virtualoffset(iter.reader.stream) < chunk.stop
            read!(iter.reader, rec)
            if isoverlap(rec, iter.refid, iter.interval)
                return i, rec
            end
        end
        i += 1
        if i ≤ endof(iter.chunks)
            seek(iter.reader, iter.chunks[i].start)
        end
    end
    return i, rec
end

function isoverlap(rec, refid_, interval)
    leftmost = position(rec)

    if !ismapped(rec) || refid(rec) != refid_ || leftmost > last(interval) || isempty(interval)
        return false
    end

    # TODO: this might be slow because allocations are needed.
    rightmost = leftmost
    ops, lens = cigar_rle(rec)
    for (op, len) in zip(ops, lens)
        if Bio.Align.ismatchop(op)
            rightmost += len
        end
    end

    return rightmost ≥ first(interval)
end

function Base.intersect(reader::BAMReader, refid::Integer, interval::UnitRange)
    if isnull(reader.index)
        error("no index")
    end
    chunks = overlap_chunks(get(reader.index), refid, interval)
    return BAMIntersectionIterator(reader, chunks, refid, interval)
end

function Base.intersect(reader::BAMReader, refname::AbstractString, interval::UnitRange)
    refid = findfirst(reader.header.refseqnames, refname)
    if refid == 0
        error("sequence name $refname is not in the header")
    end
    return intersect(reader, refid, interval)
end

function loadindex!(reader, filepath)
    open(filepath) do input
        reader.index = read(input, BAI)
    end
    return reader
end
