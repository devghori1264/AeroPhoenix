defp insert_machine(attrs \\ %{}) do
  default_attrs = %{
    id: Ecto.UUID.generate(),
    name: "test-machine-#{:rand.uniform(1000)}",
    region: "us-east-1",
    status: "running",
    machine_type: "standard",
    image: "test-image:latest",
    metadata: %{},
    user_id: "user_test",
    version: 1,
    inserted_at: DateTime.utc_now(),
    updated_at: DateTime.utc_now()
  }

  attrs = Map.merge(default_attrs, attrs)

  %Orchestrator.Machines.Machine{}
  |> Ecto.Changeset.change(attrs)
  |> Orchestrator.Repo.insert!()
end
