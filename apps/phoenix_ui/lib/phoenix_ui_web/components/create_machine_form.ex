defmodule PhoenixUiWeb.CreateMachineForm do
  use Phoenix.Component
  import PhoenixUiWeb.CoreComponents

  attr(:regions, :list, required: true)

  def render(assigns) do
    assigns = assign(assigns, :expanded_regions, expand_regions(assigns.regions))

    ~H"""
    <div class="card card-hover-lift p-4 sm:p-6">
      <h3 class="text-title text-[var(--text)] mb-6 flex items-center gap-2">
        <.icon name="hero-plus-circle" class="w-5 h-5 sm:w-6 sm:h-6 text-emerald-500" />
        <span class="gradient-text">Deploy New Machine</span>
      </h3>

      <form
        phx-submit="create"
        phx-change="update-cost"
        phx-hook="MachineFormCost"
        id="machine-form"
        class="space-y-5"
      >
        <div>
          <label class="text-sm font-medium text-[var(--text)] mb-2 flex items-center gap-2">
            <.icon name="hero-server" class="w-4 h-4 text-violet-500" /> Machine Name
          </label>
          <input
            name="name"
            type="text"
            placeholder="e.g., web-server-01"
            class="w-full px-4 py-2.5 rounded-xl glass border border-[var(--border)] text-[var(--text)] placeholder-[var(--text-muted)] focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent transition-all"
            required
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label class="text-sm font-medium text-[var(--text)] mb-2 flex items-center gap-2">
              <.icon name="hero-globe-americas" class="w-4 h-4 text-cyan-500" /> Region
            </label>
            <select
              name="region"
              id="region-select"
              class="w-full px-4 py-2.5 rounded-xl glass border border-[var(--border)] text-[var(--text)] focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent transition-all"
              required
            >
              <%= for r <- @expanded_regions do %>
                <% region_name = r[:name] || r["name"] || "unknown"
                region_count = r[:count] || r["count"] || 0 %>
                <option value={region_name}>
                  {region_name} ({region_count} machines)
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label class="text-sm font-medium text-[var(--text)] mb-2 flex items-center gap-2">
              <.icon name="hero-cpu-chip" class="w-4 h-4 text-amber-500" /> CPU
            </label>
            <select
              name="cpu_size"
              id="cpu-select"
              class="w-full px-4 py-2.5 rounded-xl glass border border-[var(--border)] text-[var(--text)] focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent transition-all"
              required
            >
              <option value="shared-cpu-1x">Shared 1x (0.5 vCPU)</option>
              <option value="shared-cpu-2x">Shared 2x (1 vCPU)</option>
              <option value="dedicated-cpu-1x" selected>Dedicated 1x (1 vCPU)</option>
              <option value="dedicated-cpu-2x">Dedicated 2x (2 vCPU)</option>
              <option value="dedicated-cpu-4x">Dedicated 4x (4 vCPU)</option>
              <option value="dedicated-cpu-8x">Dedicated 8x (8 vCPU)</option>
            </select>
          </div>

          <div>
            <label class="text-sm font-medium text-[var(--text)] mb-2 flex items-center gap-2">
              <.icon name="hero-circle-stack" class="w-4 h-4 text-emerald-500" /> Memory
            </label>
            <select
              name="memory_mb"
              id="memory-select"
              class="w-full px-4 py-2.5 rounded-xl glass border border-[var(--border)] text-[var(--text)] focus:outline-none focus:ring-2 focus:ring-violet-500 focus:border-transparent transition-all"
              required
            >
              <option value="256">256 MB</option>
              <option value="512" selected>512 MB</option>
              <option value="1024">1 GB</option>
              <option value="2048">2 GB</option>
              <option value="4096">4 GB</option>
              <option value="8192">8 GB</option>
              <option value="16384">16 GB</option>
              <option value="32768">32 GB</option>
            </select>
          </div>
        </div>

        <div class="grid grid-cols-2 sm:grid-cols-5 gap-2">
          <%= for r <- @expanded_regions do %>
            <% region_name = r[:name] || r["name"] || "unknown"
            region_count = r[:count] || r["count"] || 0
            _region_latency = (r[:avg_latency] || r["avg_latency"] || 0) |> Float.round(1)
            traffic_level = if region_count > 5, do: "High", else: "Low"
            traffic_color = if region_count > 5, do: "text-amber-500", else: "text-emerald-500"
            region_emoji = get_region_emoji(region_name) %>
            <div class="p-3 rounded-lg glass border border-[var(--border)] hover:border-violet-500/50 transition-all group cursor-pointer">
              <div class="text-xs font-medium text-[var(--text)] mb-1 flex items-center gap-1">
                <span class="group-hover:scale-110 transition-transform">{region_emoji}</span>
                <span class="truncate">{region_name}</span>
              </div>
              <div class="flex items-center justify-between text-xs">
                <span class="text-[var(--text-muted)]">{region_count} machines</span>
                <span class={"font-semibold #{traffic_color}"}>{traffic_level}</span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="p-4 rounded-xl glass border-2 border-violet-500/30 bg-gradient-to-br from-violet-500/10 via-cyan-500/10 to-emerald-500/10 backdrop-blur-sm">
          <div class="flex items-center justify-between mb-2">
            <span class="text-sm font-medium text-[var(--text)] flex items-center gap-2">
              <.icon name="hero-currency-dollar" class="w-4 h-4 text-emerald-500" /> Estimated Cost
            </span>
            <div class="text-right">
              <span id="cost-hourly" class="text-xl font-bold gradient-text">$0.0078</span>
              <span class="text-xs text-[var(--text-muted)]">/hour</span>
            </div>
          </div>
          <div class="flex items-center justify-between text-xs text-[var(--text-muted)]">
            <span>Monthly estimate</span>
            <span id="cost-monthly" class="font-semibold text-violet-500">~$5.62</span>
          </div>
          <div class="mt-2 pt-2 border-t border-[var(--border)] text-xs text-[var(--text-muted)]">
            💡 Scales automatically • Pay only for usage
          </div>
        </div>

        <button
          type="submit"
          class="mx-auto max-w-md btn-demo py-3 text-base flex items-center justify-center gap-2 font-semibold group"
        >
          <.icon name="hero-rocket-launch" class="w-5 h-5 group-hover:scale-110 transition-transform" />
          <span>Deploy Machine</span>
        </button>
      </form>
    </div>
    """
  end

  defp expand_regions(regions) when is_list(regions) do
    base_regions = [
      %{name: "us-east", count: 0, avg_latency: 45.0},
      %{name: "eu-west", count: 0, avg_latency: 85.0},
      %{name: "ap-south", count: 0, avg_latency: 120.0},
      %{name: "us-west", count: 0, avg_latency: 65.0},
      %{name: "ap-northeast", count: 0, avg_latency: 135.0}
    ]

    _existing_names = Enum.map(regions, fn r -> r[:name] || r["name"] end)

    updated_base =
      Enum.map(base_regions, fn base ->
        existing =
          Enum.find(regions, fn r ->
            (r[:name] || r["name"]) == base.name
          end)

        if existing do
          %{
            name: base.name,
            count: existing[:count] || existing["count"] || 0,
            avg_latency: existing[:avg_latency] || existing["avg_latency"] || base.avg_latency
          }
        else
          base
        end
      end)

    updated_base
  end

  defp expand_regions(_),
    do: [
      %{name: "us-east", count: 0, avg_latency: 45.0},
      %{name: "eu-west", count: 0, avg_latency: 85.0},
      %{name: "ap-south", count: 0, avg_latency: 120.0},
      %{name: "us-west", count: 0, avg_latency: 65.0},
      %{name: "ap-northeast", count: 0, avg_latency: 135.0}
    ]

  defp get_region_emoji(region_name) do
    case region_name do
      "us-east" -> "🇺🇸"
      "us-west" -> "🌉"
      "eu-west" -> "🇪🇺"
      "ap-south" -> "🇮🇳"
      "ap-northeast" -> "🇯🇵"
      _ -> "🌍"
    end
  end
end
