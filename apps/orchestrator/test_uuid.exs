uuid_string = "f8f02d58-d222-4ad4-a289-9c1d50b0cb44"
IO.puts("Input: #{uuid_string}")
IO.inspect(uuid_string, label: "String")

case Ecto.UUID.cast(uuid_string) do
  {:ok, uuid} ->
    IO.puts("Cast succeeded")
    IO.inspect(uuid, label: "Cast result")
    IO.inspect(is_binary(uuid), label: "Is binary")

  :error ->
    IO.puts("Cast failed")
end
