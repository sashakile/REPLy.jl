# TaskCapturingIO — global IO multiplexer that routes Julia-level writes to
# per-task IOBuffers. Set Base.stdout/Base.stderr to instances of this type
# once (via ensure_io_capture_installed!) and then register/unregister buffers
# per eval task to capture stdout and stderr concurrently without dup2 or any
# per-eval global lock.
#
# Limitation: only intercepts Julia-level IO (println, print, etc.). C-level
# writes to fd 1/2 via ccall are not captured.

struct TaskCapturingIO <: IO
    buffers::IdDict{Task, IOBuffer}
    fallback::IO
    lock::ReentrantLock
end

TaskCapturingIO(fallback::IO) = TaskCapturingIO(IdDict{Task, IOBuffer}(), fallback, ReentrantLock())

function _task_buf(io::TaskCapturingIO)::Union{IOBuffer, Nothing}
    lock(io.lock) do
        get(io.buffers, current_task(), nothing)
    end
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

function register_task_capture!(io::TaskCapturingIO, task::Task, buf::IOBuffer)
    lock(io.lock) do; io.buffers[task] = buf; end
end

function unregister_task_capture!(io::TaskCapturingIO, task::Task)
    lock(io.lock) do; delete!(io.buffers, task); end
end

const _STDOUT_CAPTURER = Ref{Union{TaskCapturingIO, Nothing}}(nothing)
const _STDERR_CAPTURER = Ref{Union{TaskCapturingIO, Nothing}}(nothing)
const _CAPTURER_INSTALL_LOCK = ReentrantLock()

function ensure_io_capture_installed!()
    isnothing(_STDOUT_CAPTURER[]) || return  # fast path
    lock(_CAPTURER_INSTALL_LOCK) do
        isnothing(_STDOUT_CAPTURER[]) || return  # double-checked under lock
        stdout_cap = TaskCapturingIO(Base.stdout)
        stderr_cap = TaskCapturingIO(Base.stderr)
        Base.stdout = stdout_cap
        Base.stderr = stderr_cap
        _STDOUT_CAPTURER[] = stdout_cap
        _STDERR_CAPTURER[] = stderr_cap
    end
end
