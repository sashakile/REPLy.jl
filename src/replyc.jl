const REPLYC_DEFAULT_HOST = "127.0.0.1"
const REPLYC_DEFAULT_PORT = 5555

const REPLYC_USAGE = """
replyc — minimal REPLy client

Usage:
  replyc eval    [--host H] [--port N] [--session NAME] 'CODE'
  replyc session new [--host H] [--port N] [NAME]
  replyc session ls  [--host H] [--port N]
  replyc session rm  [--host H] [--port N] NAME

Defaults: --host $(REPLYC_DEFAULT_HOST)  --port $(REPLYC_DEFAULT_PORT)
"""

function replyc_extract_options(args::Vector{String}, flags::Vector{String})
    opts = Dict{String, String}()
    positionals = String[]
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in flags
            i + 1 <= length(args) || error("option $arg requires a value")
            opts[arg] = args[i + 1]
            i += 2
        else
            push!(positionals, arg)
            i += 1
        end
    end
    return opts, positionals
end

replyc_host(opts) = get(opts, "--host", REPLYC_DEFAULT_HOST)
replyc_port(opts) = parse(Int, get(opts, "--port", string(REPLYC_DEFAULT_PORT)))

function replyc_send_and_collect(host::String, port::Int, request::Dict)
    conn = connect(host, port)
    try
        JSON3.write(conn, request)
        write(conn, '\n')
        flush(conn)
        responses = Dict{String, Any}[]
        while isopen(conn)
            line = readline(conn)
            if isempty(line)
                eof(conn) && break
                continue
            end
            msg = JSON3.read(line, Dict{String, Any})
            get(msg, "id", "") == request["id"] || continue
            push!(responses, msg)
            "done" in get(msg, "status", String[]) && break
        end
        return responses
    finally
        close(conn)
    end
end

replyc_next_id() = "replyc-$(getpid())-$(time_ns())"

function replyc_print_eval_responses(responses)
    exit_code = 0
    for msg in responses
        haskey(msg, "out") && print(msg["out"])
        haskey(msg, "err") && !haskey(msg, "status") && print(stderr, msg["err"])
        if haskey(msg, "value") && !isnothing(msg["value"])
            println(msg["value"])
        elseif haskey(msg, "repr-error")
            println("<repr failed: $(msg["repr-error"])>")
        end
        status = get(msg, "status", String[])
        if "error" in status
            exit_code = 1
            haskey(msg, "err") && println(stderr, msg["err"])
        end
    end
    return exit_code
end

function replyc_eval(args::Vector{String})
    opts, rest = replyc_extract_options(args, ["--host", "--port", "--session"])
    isempty(rest) && error("eval requires a CODE argument")
    length(rest) == 1 || error("eval takes exactly one CODE argument (quote it)")
    request = Dict{String, Any}("op" => "eval", "id" => replyc_next_id(), "code" => rest[1])
    haskey(opts, "--session") && (request["session"] = opts["--session"])
    responses = replyc_send_and_collect(replyc_host(opts), replyc_port(opts), request)
    return replyc_print_eval_responses(responses)
end

function replyc_terminal_status(responses)
    isempty(responses) && return String[]
    return String.(get(responses[end], "status", String[]))
end

function replyc_session(args::Vector{String})
    isempty(args) && error("session requires a subcommand: new | ls | rm")
    sub = args[1]
    opts, rest = replyc_extract_options(args[2:end], ["--host", "--port"])
    host, port = replyc_host(opts), replyc_port(opts)
    if sub == "new"
        request = Dict{String, Any}("op" => "new-session", "id" => replyc_next_id())
        isempty(rest) || (request["name"] = rest[1])
        responses = replyc_send_and_collect(host, port, request)
        sessions = filter(msg -> haskey(msg, "session"), responses)
        isempty(sessions) || println(sessions[1]["session"])
        return "error" in replyc_terminal_status(responses) ? 1 : 0
    elseif sub == "ls"
        request = Dict{String, Any}("op" => "ls-sessions", "id" => replyc_next_id())
        responses = replyc_send_and_collect(host, port, request)
        for msg in responses
            haskey(msg, "sessions") || continue
            for session in msg["sessions"]
                name = get(session, "name", nothing)
                println(get(session, "session", ""), isnothing(name) ? "" : "\t$(name)")
            end
        end
        return "error" in replyc_terminal_status(responses) ? 1 : 0
    elseif sub == "rm"
        isempty(rest) && error("session rm requires a NAME or UUID")
        request = Dict{String, Any}("op" => "close", "id" => replyc_next_id(), "session" => rest[1])
        responses = replyc_send_and_collect(host, port, request)
        status = replyc_terminal_status(responses)
        if "error" in status
            !isempty(responses) && haskey(responses[end], "err") && println(stderr, responses[end]["err"])
            return 1
        end
        return 0
    else
        error("unknown session subcommand: $(sub)")
    end
end

"""Run the `replyc` command-line client and return its process exit code."""
function replyc(args::Vector{String}=collect(ARGS))
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print(REPLYC_USAGE)
        return 0
    end
    command, rest = args[1], args[2:end]
    try
        if command == "eval"
            return replyc_eval(rest)
        elseif command == "session"
            return replyc_session(rest)
        else
            println(stderr, "unknown command: $(command)\n")
            print(stderr, REPLYC_USAGE)
            return 2
        end
    catch ex
        if ex isa Base.IOError || ex isa Sockets.DNSError
            println(stderr, "connection failed: $(sprint(showerror, ex))")
            return 1
        end
        println(stderr, "error: $(sprint(showerror, ex))")
        return 2
    end
end
