files_to_fix = [
  "lib/orchestrator/placement/latency_optimizer.ex",
  "lib/orchestrator/cost/policy_engine.ex",
  "lib/orchestrator/deployments/canary_analyzer.ex",
  "lib/orchestrator/scaling/predictor.ex"
]

for file <- files_to_fix do
  if File.exists?(file) do
    content = File.read!(file)

    unless String.contains?(content, "import Ecto.Query") do
      updated =
        String.replace(content, ~r/(alias|require) .*\n/, "\\0  import Ecto.Query\n",
          global: false
        )

      if updated != content do
        File.write!(file, updated)
        IO.puts("Fixed: #{file}")
      end
    end
  end
end
