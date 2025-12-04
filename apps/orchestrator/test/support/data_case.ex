defmodule Orchestrator.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Orchestrator.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Orchestrator.DataCase
    end
  end

  setup tags do
    Orchestrator.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    shared = not tags[:async] or tags[:integration]
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Orchestrator.Repo, shared: shared)

    if shared do
      Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})
    end

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
