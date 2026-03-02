# Sykli CI pipeline configuration
# Run with: mix run sykli.exs
#
# Steps: deps → compile → format check → test

steps = [
  {"deps.get", "mix deps.get"},
  {"compile", "mix compile --warnings-as-errors"},
  {"format", "mix format --check-formatted"},
  {"test", "mix test"}
]

for {name, cmd} <- steps do
  IO.puts("==> #{name}")
  {_, code} = System.cmd("sh", ["-c", cmd], into: IO.stream())

  if code != 0 do
    IO.puts("FAILED: #{name}")
    System.halt(code)
  end
end

IO.puts("==> All steps passed")
