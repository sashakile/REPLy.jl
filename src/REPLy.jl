module REPLy

using JSON3

export protocol_name, version_string
export AbstractTransport, JSONTransport, close, done_response, error_response,
    receive, response_message, send!, validate_request

include("protocol/message.jl")

"""Return the canonical protocol name for this package."""
protocol_name() = "REPLy"

"""Return a human-readable package version string."""
version_string() = string(pkgversion(REPLy))

end
