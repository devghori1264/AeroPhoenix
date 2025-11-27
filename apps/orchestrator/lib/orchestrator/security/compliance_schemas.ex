defmodule Orchestrator.Security.ComplianceFramework do
  use Ecto.Schema
  import Ecto.Changeset

  schema "compliance_frameworks" do
    field(:name, :string)
    field(:version, :string)
    field(:enabled, :boolean, default: true)
    field(:metadata, :map)
    timestamps()
  end

  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :version, :enabled, :metadata])
    |> validate_required([:name])
  end

  def list_enabled do
    import Ecto.Query
    Orchestrator.Repo.all(from(f in __MODULE__, where: f.enabled == true))
  end

  def get_by_framework(name) do
    Orchestrator.Repo.get_by(__MODULE__, name: name)
  end

  def update(framework, attrs) do
    framework
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end
end

defmodule Orchestrator.Security.ComplianceRequirement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "compliance_requirements" do
    field(:framework_id, :id)
    field(:control_id, :string)
    field(:description, :string)
    field(:status, :string)
    timestamps()
  end

  def changeset(requirement, attrs) do
    requirement
    |> cast(attrs, [:framework_id, :control_id, :description, :status])
    |> validate_required([:control_id])
  end

  def list_by_framework(framework_id) do
    import Ecto.Query
    Orchestrator.Repo.all(from(r in __MODULE__, where: r.framework_id == ^framework_id))
  end

  def update(requirement, attrs) do
    requirement
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end
end

defmodule Orchestrator.Security.ComplianceEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  schema "compliance_evidence" do
    field(:requirement_id, :id)
    field(:evidence_type, :string)
    field(:data, :map)
    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:requirement_id, :evidence_type, :data])
    |> validate_required([:evidence_type])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end
end

defmodule Orchestrator.Security.SecurityAuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "security_audit_logs" do
    field(:action, :string)
    field(:actor, :string)
    field(:resource, :string)
    field(:details, :map)
    timestamps()
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :actor, :resource, :details])
    |> validate_required([:action])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end
end

defmodule Orchestrator.Security.EncryptionKey do
  use Ecto.Schema

  schema "encryption_keys" do
    field(:key_id, :string)
    field(:algorithm, :string)
    field(:status, :string)
    timestamps()
  end
end

defmodule Orchestrator.Security.Vulnerability do
  use Ecto.Schema

  schema "vulnerabilities" do
    field(:cve_id, :string)
    field(:severity, :string)
    field(:status, :string)
    timestamps()
  end
end
