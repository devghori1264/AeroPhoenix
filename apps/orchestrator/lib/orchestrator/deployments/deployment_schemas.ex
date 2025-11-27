defmodule Orchestrator.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployments" do
    field(:service_name, :string)
    field(:strategy, :string)
    field(:status, :string)
    field(:current_phase, :string)
    field(:metadata, :map)
    timestamps()
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:service_name, :strategy, :status, :current_phase, :metadata])
    |> validate_required([:service_name, :strategy])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def update(deployment, attrs) do
    deployment
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end

  def update_status(deployment, status) do
    update(deployment, %{status: status})
  end

  def list_active do
    import Ecto.Query
    Orchestrator.Repo.all(from(d in __MODULE__, where: d.status == "in_progress"))
  end
end

defmodule Orchestrator.Deployments.DeploymentReplica do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployment_replicas" do
    field(:deployment_id, :id)
    field(:machine_id, :string)
    field(:status, :string)
    field(:version, :string)
    timestamps()
  end

  def changeset(replica, attrs) do
    replica
    |> cast(attrs, [:deployment_id, :machine_id, :status, :version])
    |> validate_required([:deployment_id, :machine_id])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def update(replica, attrs) do
    replica
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end

  def list_by_deployment(deployment_id) do
    import Ecto.Query
    Orchestrator.Repo.all(from(r in __MODULE__, where: r.deployment_id == ^deployment_id))
  end

  def list_active do
    import Ecto.Query
    Orchestrator.Repo.all(from(r in __MODULE__, where: r.status == "running"))
  end
end

defmodule Orchestrator.Deployments.TrafficRoute do
  use Ecto.Schema
  import Ecto.Changeset

  schema "traffic_routes" do
    field(:deployment_id, :id)
    field(:weight, :integer)
    field(:target, :string)
    timestamps()
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [:deployment_id, :weight, :target])
    |> validate_required([:deployment_id, :weight])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def update(route, attrs) do
    route
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end
end

defmodule Orchestrator.Deployments.DeploymentRevision do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployment_revisions" do
    field(:deployment_id, :id)
    field(:version, :string)
    field(:config, :map)
    field(:active, :boolean)
    timestamps()
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:deployment_id, :version, :config, :active])
    |> validate_required([:deployment_id, :version])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def get_latest(deployment_id) do
    import Ecto.Query

    from(r in __MODULE__,
      where: r.deployment_id == ^deployment_id,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Orchestrator.Repo.one()
  end

  def get_previous_active(deployment_id) do
    import Ecto.Query

    from(r in __MODULE__,
      where: r.deployment_id == ^deployment_id and r.active == true,
      order_by: [desc: r.inserted_at],
      offset: 1,
      limit: 1
    )
    |> Orchestrator.Repo.one()
  end
end

defmodule Orchestrator.Deployments.CanaryAnalysisResult do
  use Ecto.Schema
  import Ecto.Changeset

  schema "canary_analysis_results" do
    field(:deployment_id, :id)
    field(:score, :float)
    field(:passed, :boolean)
    field(:details, :map)
    timestamps()
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [:deployment_id, :score, :passed, :details])
    |> validate_required([:deployment_id])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end
end

defmodule Orchestrator.Deployments.DeploymentHook do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployment_hooks" do
    field(:deployment_id, :id)
    field(:hook_type, :string)
    field(:command, :string)
    field(:status, :string)
    timestamps()
  end

  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [:deployment_id, :hook_type, :command, :status])
    |> validate_required([:deployment_id, :hook_type])
  end

  def list_by_type(deployment_id, type) do
    import Ecto.Query

    Orchestrator.Repo.all(
      from(h in __MODULE__, where: h.deployment_id == ^deployment_id and h.hook_type == ^type)
    )
  end

  def update(hook, attrs) do
    hook
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end
end

defmodule Orchestrator.Deployments.DeploymentEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployment_events" do
    field(:deployment_id, :id)
    field(:event_type, :string)
    field(:message, :string)
    field(:metadata, :map)
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:deployment_id, :event_type, :message, :metadata])
    |> validate_required([:deployment_id, :event_type])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end
end
