module REPLy

using JSON3

export protocol_name, version_string
export AbstractTransport, JSONTransport, close, done_response, error_response,
    receive, response_message, send!, validate_request
export build_handler

include("errors.jl")
include("protocol/message.jl")
include("session/module_session.jl")
include("session/manager.jl")
include("middleware/core.jl")
include("middleware/session.jl")
include("middleware/unknown_op.jl")

"""Return the canonical protocol name for this package."""
protocol_name() = "REPLy"

"""Return a human-readable package version string."""
version_string() = string(pkgversion(REPLy))

end
