@testset "concurrent eval serialization" begin
    @testset "concurrent ephemeral evals complete in parallel, not serial" begin
        handler = REPLy.build_handler()

        # Warmup: force JIT so timing is accurate
        handler(Dict("op" => "eval", "id" => "w0", "code" => "1+1"))

        n = 3
        sleep_s = 0.15

        start = time()
        tasks = map(1:n) do i
            @async handler(Dict("op" => "eval", "id" => "par-$i",
                                "code" => "sleep($sleep_s); $i"))
        end
        results = fetch.(tasks)
        elapsed = time() - start

        # Serial: n * sleep_s ≈ 0.45s. Concurrent: ~sleep_s ≈ 0.15s.
        # Accept anything under 2 * sleep_s as evidence of concurrency.
        @test elapsed < 2 * sleep_s

        for i in 1:n
            @test any(get(msg, "value", nothing) == string(i) for msg in results[i])
        end
    end

    @testset "per-task IO capture: each concurrent eval sees only its own output" begin
        handler = REPLy.build_handler()
        handler(Dict("op" => "eval", "id" => "w1", "code" => "1"))  # warmup

        tasks = map(1:3) do i
            @async handler(Dict("op" => "eval", "id" => "cap-$i",
                                "code" => "sleep(0.05); println(\"marker-$i\"); $i"))
        end
        results = fetch.(tasks)

        for i in 1:3
            out_msgs = filter(msg -> haskey(msg, "out"), results[i])
            captured = join(getindex.(out_msgs, "out"))
            @test occursin("marker-$i", captured)
            for j in 1:3
                j == i && continue
                @test !occursin("marker-$j", captured)
            end
        end
    end
end
