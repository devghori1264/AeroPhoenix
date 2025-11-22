defmodule Orchestrator.Placement.ComplianceRules do
  @type rule :: %{
          name: String.t(),
          type: atom(),
          requirements: map()
        }
  def load do
    %{
      data_residency: %{
        "US" => ["us-east-1", "us-west-1", "us-west-2"],
        "EU" => ["eu-west-1", "eu-central-1"],
        "APAC" => ["ap-south-1", "ap-southeast-1"]
      },
      gdpr_compliant: ["eu-west-1", "eu-central-1"],
      hipaa_compliant: ["us-east-1", "us-west-2"],
      soc2_certified: ["us-east-1", "us-west-1", "eu-west-1"]
    }
  end

  def check_compliance(rules, region, compliance_requirements) do
    Enum.all?(compliance_requirements, fn {requirement, value} ->
      case requirement do
        :data_residency ->
          allowed_regions = get_in(rules, [:data_residency, value]) || []
          region in allowed_regions

        :gdpr ->
          if value, do: region in rules.gdpr_compliant, else: true

        :hipaa ->
          if value, do: region in rules.hipaa_compliant, else: true

        :soc2 ->
          if value, do: region in rules.soc2_certified, else: true

        _ ->
          true
      end
    end)
  end
end
