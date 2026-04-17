# REPLy.jl

!!! warning "LLM-generated code"
    This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.

REPLy.jl is a network REPL server for Julia — think [nREPL](https://nrepl.org/) for Clojure, but for Julia. It exposes a Julia REPL over a socket-based protocol so that editors and tooling can connect, evaluate code, and inspect results interactively.

## Getting Started

```julia
using REPLy

protocol_name()   # "REPLy"
version_string()  # "0.1.0"
```
