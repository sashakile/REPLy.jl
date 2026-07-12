# TaskCapturingIO — global IO multiplexer that routes Julia-level writes to
# per-task IOBuffers. Set Base.stdout/Base.stderr to instances of this type
# once (via ensure_io_capture_installed!) and then register/unregister buffers
# per eval task to capture stdout and stderr concurrently without dup2.
#
# The capture buffer for the running task is kept in that task's
# `task_local_storage`, keyed by `io.key`. Because each task has its own storage,
# writes from concurrent eval tasks never collide and there is no shared registry
# or lock on the write path — a write is a single task-local dictionary lookup.
#
# Limitation: only intercepts Julia-level IO (println, print, etc.). C-level
# writes to fd 1/2 via ccall are not captured. Writes from child tasks spawned
# inside an eval fall through to the fallback stream (they have their own,
# empty, task-local storage), matching the previous per-task registry behavior.

struct TaskCapturingIO <: IO
    key::Symbol
    fallback::IO
end

function _task_buf(io::TaskCapturingIO)::Union{IOBuffer, Nothing}
    return get(task_local_storage(), io.key, nothing)
end

function Base.write(io::TaskCapturingIO, b::UInt8)
    buf = _task_buf(io)
    isnothing(buf) ? write(io.fallback, b) : write(buf, b)
end

function Base.unsafe_write(io::TaskCapturingIO, p::Ptr{UInt8}, n::UInt)
    buf = _task_buf(io)
    isnothing(buf) ? unsafe_write(io.fallback, p, n) : unsafe_write(buf, p, n)
end

Base.isopen(::TaskCapturingIO) = true
Base.iswritable(::TaskCapturingIO) = true
Base.flush(::TaskCapturingIO) = nothing

# Register `buf` as the capture target for the running task. `task` must be the
# current task (its own task-local storage is used); it is accepted explicitly to
# document the contract at call sites.
function register_task_capture!(io::TaskCapturingIO, task::Task, buf::IOBuffer)
    @assert task === current_task() "register_task_capture! must run on the task being captured"
    task_local_storage(io.key, buf)
    return nothing
end

function unregister_task_capture!(io::TaskCapturingIO, task::Task)
    @assert task === current_task() "unregister_task_capture! must run on the task being captured"
    delete!(task_local_storage(), io.key)
    return nothing
end

const _STDOUT_CAPTURER = Ref{Union{TaskCapturingIO, Nothing}}(nothing)
const _STDERR_CAPTURER = Ref{Union{TaskCapturingIO, Nothing}}(nothing)
const _CAPTURER_INSTALL_LOCK = ReentrantLock()

function ensure_io_capture_installed!()
    isnothing(_STDOUT_CAPTURER[]) || return  # fast path
    lock(_CAPTURER_INSTALL_LOCK) do
        isnothing(_STDOUT_CAPTURER[]) || return  # double-checked under lock
        stdout_cap = TaskCapturingIO(:__reply_capture_stdout, Base.stdout)
        stderr_cap = TaskCapturingIO(:__reply_capture_stderr, Base.stderr)
        Base.stdout = stdout_cap
        Base.stderr = stderr_cap
        _STDOUT_CAPTURER[] = stdout_cap
        _STDERR_CAPTURER[] = stderr_cap
    end
end
