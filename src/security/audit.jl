const DEFAULT_AUDIT_MAX_ENTRIES = 100_000
const DEFAULT_AUDIT_EVICT_COUNT = 50_000
const DEFAULT_AUDIT_ROTATE_BYTES = 100_000_000

Base.@kwdef struct AuditLogEntry
    timestamp::DateTime
    client_id::UUID
    session_id::Union{Nothing, String} = nothing
    operation::String
    user::String = ""
    source_ip::String
    success::Bool
    error::Union{Nothing, String} = nothing
end

mutable struct AuditLog
    entries::Vector{AuditLogEntry}
    max_entries::Int
    evict_count::Int
    path::Union{Nothing, String}
    rotate_bytes::Int
    lock::ReentrantLock
end

function AuditLog(;
    max_entries::Int=DEFAULT_AUDIT_MAX_ENTRIES,
    evict_count::Int=DEFAULT_AUDIT_EVICT_COUNT,
    path::Union{Nothing, AbstractString}=nothing,
    rotate_bytes::Int=DEFAULT_AUDIT_ROTATE_BYTES,
)
    max_entries > 0 || throw(ArgumentError("max_entries must be positive, got $max_entries"))
    evict_count > 0 || throw(ArgumentError("evict_count must be positive, got $evict_count"))
    evict_count <= max_entries || throw(ArgumentError("evict_count must be ≤ max_entries"))
    rotate_bytes > 0 || throw(ArgumentError("rotate_bytes must be positive, got $rotate_bytes"))
    return AuditLog(AuditLogEntry[], max_entries, evict_count, isnothing(path) ? nothing : String(path), rotate_bytes, ReentrantLock())
end

function audit_entry_payload(entry::AuditLogEntry)
    return Dict(
        "timestamp" => Dates.format(entry.timestamp, dateformat"yyyy-mm-ddTHH:MM:SS.s"),
        "client_id" => string(entry.client_id),
        "session_id" => entry.session_id,
        "operation" => entry.operation,
        "user" => entry.user,
        "source_ip" => entry.source_ip,
        "success" => entry.success,
        "error" => entry.error,
    )
end

function maybe_rotate_audit_file!(path::AbstractString, next_entry_bytes::Int, rotate_bytes::Int)
    isfile(path) || return nothing
    filesize(path) + next_entry_bytes <= rotate_bytes && return nothing

    rotated = string(path, ".1")
    ispath(rotated) && rm(rotated; force=true)
    mv(path, rotated; force=true)
    return nothing
end

function append_audit_file!(path::AbstractString, entry::AuditLogEntry, rotate_bytes::Int)
    payload = audit_entry_payload(entry)
    serialized::String = JSON3.write(payload)
    line::String = serialized * "\n"
    mkpath(dirname(path))
    maybe_rotate_audit_file!(path, ncodeunits(line), rotate_bytes)
    open(path, "a") do io
        write(io, line)
    end
    return nothing
end

function evict_oldest_entries!(log::AuditLog)
    length(log.entries) <= log.max_entries && return nothing
    deleteat!(log.entries, 1:min(log.evict_count, length(log.entries)))
    return nothing
end

function record_audit!(log::AuditLog, entry::AuditLogEntry)
    lock(log.lock) do
        push!(log.entries, entry)
        evict_oldest_entries!(log)
        path = log.path
        if !isnothing(path)
            append_audit_file!(path, entry, log.rotate_bytes)
        end
    end
    return entry
end

audit_entries(log::AuditLog) = copy(log.entries)
