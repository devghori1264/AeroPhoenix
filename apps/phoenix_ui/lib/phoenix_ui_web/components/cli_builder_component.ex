defmodule PhoenixUiWeb.CliBuilderComponent do
  use PhoenixUiWeb, :live_component
  require Logger

  @command_templates [
    %{
      category: "Machine Management",
      commands: [
        %{
          name: "Create Machine",
          template: "aeropctl machine create --region {{region}} --size {{size}} --name {{name}}",
          description: "Create a new virtual machine in specified region",
          params: [
            %{
              key: "region",
              type: "select",
              options: ["us-east", "eu-west", "ap-south"],
              default: "us-east"
            },
            %{
              key: "size",
              type: "select",
              options: ["small", "medium", "large", "xlarge"],
              default: "medium"
            },
            %{key: "name", type: "text", default: "machine-${random}", placeholder: "my-machine"}
          ],
          examples: [
            "aeropctl machine create --region us-east --size small --name web-server-1",
            "aeropctl machine create --region eu-west --size large --name db-primary"
          ]
        },
        %{
          name: "Delete Machine",
          template: "aeropctl machine delete {{machine_id}} {{flags}}",
          description: "Delete a machine by ID with optional force flag",
          params: [
            %{key: "machine_id", type: "text", default: "", placeholder: "machine-abc-123"},
            %{key: "flags", type: "flags", options: ["--force", "--wait"], default: ""}
          ],
          examples: ["aeropctl machine delete machine-abc-123 --force"]
        },
        %{
          name: "List Machines",
          template: "aeropctl machine list {{filters}}",
          description: "List all machines with optional filters",
          params: [
            %{
              key: "filters",
              type: "text",
              default: "",
              placeholder: "--region us-east --status running"
            }
          ],
          examples: [
            "aeropctl machine list",
            "aeropctl machine list --region us-east",
            "aeropctl machine list --status running --format json"
          ]
        },
        %{
          name: "Migrate Machine",
          template:
            "aeropctl machine migrate {{machine_id}} --target-region {{target_region}} {{options}}",
          description: "Live migrate machine to different region with zero downtime",
          params: [
            %{key: "machine_id", type: "text", default: "", placeholder: "machine-abc-123"},
            %{
              key: "target_region",
              type: "select",
              options: ["us-east", "eu-west", "ap-south"],
              default: "us-east"
            },
            %{
              key: "options",
              type: "flags",
              options: ["--verify-checksum", "--rollback-on-error"],
              default: ""
            }
          ],
          examples: [
            "aeropctl machine migrate machine-abc-123 --target-region eu-west --verify-checksum"
          ]
        }
      ]
    },
    %{
      category: "Chaos Engineering",
      commands: [
        %{
          name: "Inject Latency",
          template:
            "aeropctl chaos inject latency --target {{target}} --delay {{delay}}ms --duration {{duration}}s",
          description: "Inject network latency into target machine",
          params: [
            %{key: "target", type: "text", default: "", placeholder: "machine-abc-123"},
            %{key: "delay", type: "number", default: "100", min: 10, max: 5000},
            %{key: "duration", type: "number", default: "30", min: 1, max: 3600}
          ],
          examples: [
            "aeropctl chaos inject latency --target machine-abc-123 --delay 200ms --duration 60s"
          ]
        },
        %{
          name: "Inject Packet Loss",
          template:
            "aeropctl chaos inject packet-loss --target {{target}} --rate {{rate}}% --duration {{duration}}s",
          description: "Simulate network packet loss",
          params: [
            %{key: "target", type: "text", default: "", placeholder: "machine-abc-123"},
            %{key: "rate", type: "number", default: "10", min: 1, max: 100},
            %{key: "duration", type: "number", default: "30", min: 1, max: 3600}
          ],
          examples: [
            "aeropctl chaos inject packet-loss --target machine-abc-123 --rate 15% --duration 45s"
          ]
        },
        %{
          name: "Stop Chaos",
          template: "aeropctl chaos stop {{chaos_id}}",
          description: "Stop active chaos experiment",
          params: [
            %{key: "chaos_id", type: "text", default: "", placeholder: "chaos-xyz-789"}
          ],
          examples: ["aeropctl chaos stop chaos-xyz-789"]
        }
      ]
    },
    %{
      category: "Debugging",
      commands: [
        %{
          name: "Attach Debugger",
          template: "aeropctl debug attach {{machine_id}} {{options}}",
          description: "Attach interactive debugger to running machine",
          params: [
            %{key: "machine_id", type: "text", default: "", placeholder: "machine-abc-123"},
            %{
              key: "options",
              type: "flags",
              options: ["--capture-network", "--trace-syscalls"],
              default: ""
            }
          ],
          examples: ["aeropctl debug attach machine-abc-123 --capture-network"]
        },
        %{
          name: "Stream Logs",
          template: "aeropctl logs stream {{machine_id}} {{filters}}",
          description: "Stream live logs from machine",
          params: [
            %{key: "machine_id", type: "text", default: "", placeholder: "machine-abc-123"},
            %{key: "filters", type: "text", default: "", placeholder: "--level error --tail 100"}
          ],
          examples: ["aeropctl logs stream machine-abc-123 --level error --follow"]
        }
      ]
    },
    %{
      category: "Fleet Management",
      commands: [
        %{
          name: "Scale Fleet",
          template: "aeropctl fleet scale --region {{region}} --count {{count}}",
          description: "Scale fleet to desired machine count",
          params: [
            %{
              key: "region",
              type: "select",
              options: ["us-east", "eu-west", "ap-south", "all"],
              default: "all"
            },
            %{key: "count", type: "number", default: "5", min: 0, max: 100}
          ],
          examples: ["aeropctl fleet scale --region us-east --count 10"]
        },
        %{
          name: "Optimize Placement",
          template: "aeropctl fleet optimize {{strategy}}",
          description: "Run ML-powered placement optimizer",
          params: [
            %{
              key: "strategy",
              type: "select",
              options: ["--cost", "--latency", "--balanced"],
              default: "--balanced"
            }
          ],
          examples: ["aeropctl fleet optimize --latency"]
        }
      ]
    }
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected_template, nil)
     |> assign(:current_command, "")
     |> assign(:command_params, %{})
     |> assign(:search_query, "")
     |> assign(:history_filter, "all")
     |> assign(:show_examples, false)
     |> assign(:copy_feedback, nil)
     |> assign(:favorites, [])
     |> assign(:user_typing, false)
     |> assign(:command_valid, false)
     |> assign(:execution_result, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:command_history, fn -> [] end)
      |> assign_new(:command_templates, fn -> @command_templates end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="w-12 h-12 rounded-xl bg-gradient-to-br from-amber-500/20 to-orange-500/20 border border-amber-500/30 dark:border-amber-500/30 flex items-center justify-center">
            <.icon name="hero-command-line" class="w-6 h-6 text-amber-600 dark:text-amber-400" />
          </div>
          <div>
            <h3 class="text-xl font-bold text-slate-900 dark:text-white">CLI Command Builder</h3>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {length(@command_templates |> Enum.flat_map(& &1.commands))} templates · {length(
                @command_history
              )} in history
            </p>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <button
            phx-click="export_history"
            phx-target={@myself}
            class="modern-btn btn-secondary"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
            <span>Export Script</span>
          </button>

          <button
            phx-click="clear_builder"
            phx-target={@myself}
            class="modern-btn btn-ghost"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
            <span>Clear</span>
          </button>
        </div>
      </div>

      <div class="rounded-lg bg-white dark:bg-base-200 shadow-lg p-6 border border-slate-200 dark:border-slate-700/50">
        <div class="flex items-center justify-between mb-6">
          <h4 class="text-lg font-bold text-slate-900 dark:text-white">Build Command</h4>
          <%= if @copy_feedback do %>
            <div class="modern-badge badge-success animate-fade-in-up">
              <.icon name="hero-check" class="w-4 h-4" />
              <span>{@copy_feedback}</span>
            </div>
          <% end %>
        </div>

        <div class="mb-6">
          <div class="relative">
            <div class="code-block bg-slate-900 dark:bg-slate-950 border-2 border-amber-500/30 rounded-xl p-6 font-mono text-sm">
              <div class="flex items-start gap-3">
                <span class="text-emerald-400 select-none shrink-0 mt-1">$</span>
                <div class="flex-1 min-w-0">
                  <input
                    type="text"
                    phx-change="type_command"
                    phx-target={@myself}
                    value={@current_command}
                    placeholder="Select a template or type a command..."
                    class="w-full bg-transparent border-none outline-none text-white placeholder-slate-600 font-mono text-sm focus:ring-0 p-0"
                    autocomplete="off"
                    spellcheck="false"
                  />
                </div>
              </div>
            </div>

            <%= if @current_command != "" do %>
              <div class="mt-3 flex items-center justify-between">
                <div class="flex items-center gap-2 text-sm">
                  <%= if @command_valid do %>
                    <.icon name="hero-check-circle" class="w-5 h-5 text-emerald-500" />
                    <span class="text-emerald-600 dark:text-emerald-400 font-medium">
                      Valid command syntax
                    </span>
                  <% else %>
                    <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-500" />
                    <span class="text-red-600 dark:text-red-400 font-medium">
                      Invalid command syntax
                    </span>
                  <% end %>
                </div>

                <button
                  phx-click="copy_command"
                  phx-target={@myself}
                  class="modern-btn btn-primary btn-sm"
                >
                  <.icon name="hero-clipboard-document" class="w-4 h-4" />
                  <span>Copy</span>
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-6">
          <%= for category <- @command_templates do %>
            <div>
              <h5 class="text-sm font-semibold text-slate-600 dark:text-slate-400 uppercase tracking-wider mb-3 flex items-center gap-2">
                <.icon name={category_icon(category.category)} class="w-4 h-4" />
                <span>{category.category}</span>
              </h5>

              <div class="space-y-2">
                <%= for cmd <- category.commands do %>
                  <button
                    phx-click="select_template"
                    phx-value-category={category.category}
                    phx-value-name={cmd.name}
                    phx-target={@myself}
                    class={[
                      "w-full text-left p-4 rounded-xl border transition-all duration-200 group",
                      if(@selected_template && @selected_template.name == cmd.name,
                        do:
                          "bg-amber-50 dark:bg-amber-500/10 border-amber-500/50 shadow-lg shadow-amber-500/10",
                        else:
                          "bg-slate-50 dark:bg-slate-800/30 border-slate-200 dark:border-slate-700/50 hover:border-amber-500/30 hover:bg-slate-100 dark:hover:bg-slate-800/50"
                      )
                    ]}
                  >
                    <div class="flex items-start justify-between mb-2">
                      <span class="text-sm font-semibold text-slate-900 dark:text-white group-hover:text-amber-600 dark:group-hover:text-amber-400 transition-colors">
                        {cmd.name}
                      </span>
                      <%= if Enum.member?(@favorites, cmd.name) do %>
                        <.icon name="hero-star-solid" class="w-4 h-4 text-amber-500" />
                      <% end %>
                    </div>
                    <p class="text-xs text-slate-600 dark:text-slate-400 mb-2">
                      {cmd.description}
                    </p>
                    <div class="font-mono text-xs text-slate-500 dark:text-slate-500 truncate">
                      {cmd.template}
                    </div>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @selected_template do %>
        <div class="rounded-lg bg-white dark:bg-base-200 shadow-lg p-6 border border-slate-200 dark:border-slate-700/50 animate-fade-in-up">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h4 class="text-lg font-bold text-slate-900 dark:text-white mb-1">
                {@selected_template.name}
              </h4>
              <p class="text-sm text-slate-600 dark:text-slate-400">
                {@selected_template.description}
              </p>
            </div>
            <button
              phx-click="toggle_examples"
              phx-target={@myself}
              class="modern-btn btn-secondary btn-sm"
            >
              <.icon name="hero-light-bulb" class="w-4 h-4" />
              <span>Examples</span>
            </button>
          </div>

          <div class="grid grid-cols-2 gap-4 mb-6">
            <%= for param <- @selected_template.params do %>
              <div>
                <label class="block text-sm font-semibold text-slate-700 dark:text-slate-300 mb-2">
                  {humanize_param(param.key)}
                  <%= if param.type == "number" do %>
                    <span class="text-xs text-slate-500 font-normal ml-2">
                      ({param.min} - {param.max})
                    </span>
                  <% end %>
                </label>

                <%= case param.type do %>
                  <% "select" -> %>
                    <select
                      phx-change="update_param"
                      phx-value-key={param.key}
                      phx-target={@myself}
                      class="w-full px-4 py-3 rounded-xl bg-slate-50 dark:bg-slate-800/50 border border-slate-300 dark:border-slate-700/50 text-slate-900 dark:text-white focus:border-amber-500/50 focus:ring-2 focus:ring-amber-500/20 transition-all"
                    >
                      <%= for option <- param.options do %>
                        <option
                          value={option}
                          selected={Map.get(@command_params, param.key, param.default) == option}
                        >
                          {option}
                        </option>
                      <% end %>
                    </select>
                  <% "number" -> %>
                    <input
                      type="number"
                      phx-change="update_param"
                      phx-value-key={param.key}
                      phx-target={@myself}
                      value={Map.get(@command_params, param.key, param.default)}
                      min={param.min}
                      max={param.max}
                      class="w-full px-4 py-3 rounded-xl bg-slate-50 dark:bg-slate-800/50 border border-slate-300 dark:border-slate-700/50 text-slate-900 dark:text-white focus:border-amber-500/50 focus:ring-2 focus:ring-amber-500/20 transition-all"
                    />
                  <% "flags" -> %>
                    <div class="flex flex-wrap gap-2">
                      <%= for flag <- param.options do %>
                        <button
                          phx-click="toggle_flag"
                          phx-value-key={param.key}
                          phx-value-flag={flag}
                          phx-target={@myself}
                          class={[
                            "px-3 py-2 rounded-lg text-sm font-medium border transition-all",
                            if(String.contains?(Map.get(@command_params, param.key, ""), flag),
                              do:
                                "bg-amber-500/20 border-amber-500/50 text-amber-700 dark:text-amber-400",
                              else:
                                "bg-slate-50 dark:bg-slate-800/50 border-slate-300 dark:border-slate-700/50 text-slate-600 dark:text-slate-400 hover:border-amber-500/30"
                            )
                          ]}
                        >
                          {flag}
                        </button>
                      <% end %>
                    </div>
                  <% _ -> %>
                    <input
                      type="text"
                      phx-change="update_param"
                      phx-value-key={param.key}
                      phx-target={@myself}
                      value={Map.get(@command_params, param.key, param.default)}
                      placeholder={param.placeholder}
                      class="w-full px-4 py-3 rounded-xl bg-slate-50 dark:bg-slate-800/50 border border-slate-300 dark:border-slate-700/50 text-slate-900 dark:text-white placeholder-slate-400 dark:placeholder-slate-500 focus:border-amber-500/50 focus:ring-2 focus:ring-amber-500/20 transition-all font-mono"
                    />
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @show_examples && @selected_template.examples do %>
            <div class="border-t border-slate-200 dark:border-slate-800/50 pt-6 animate-fade-in-up">
              <h5 class="text-sm font-semibold text-slate-600 dark:text-slate-400 uppercase tracking-wider mb-3">
                Example Commands
              </h5>
              <div class="space-y-2">
                <%= for example <- @selected_template.examples do %>
                  <div class="group flex items-center gap-3 p-3 rounded-lg bg-slate-50 dark:bg-slate-800/30 border border-slate-200 dark:border-slate-700/50 hover:border-amber-500/30 transition-all">
                    <code class="flex-1 text-xs font-mono text-slate-700 dark:text-slate-300 group-hover:text-slate-900 dark:group-hover:text-white transition-colors">
                      {example}
                    </code>
                    <button
                      phx-click="use_example"
                      phx-value-command={example}
                      phx-target={@myself}
                      class="opacity-0 group-hover:opacity-100 transition-opacity modern-btn btn-ghost btn-sm"
                    >
                      <.icon name="hero-arrow-right" class="w-4 h-4" />
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <div class="flex items-center gap-3 pt-6 border-t border-slate-200 dark:border-slate-800/50">
            <button
              phx-click="execute_command"
              phx-target={@myself}
              disabled={!@command_valid}
              class={[
                "modern-btn btn-primary",
                if(!@command_valid, do: "opacity-50 cursor-not-allowed", else: "")
              ]}
            >
              <.icon name="hero-play" class="w-4 h-4" />
              <span>Execute Command</span>
            </button>

            <button
              phx-click="toggle_favorite"
              phx-target={@myself}
              class="modern-btn btn-secondary"
            >
              <%= if Enum.member?(@favorites, @selected_template.name) do %>
                <.icon name="hero-star-solid" class="w-4 h-4 text-amber-500" />
                <span>Remove from Favorites</span>
              <% else %>
                <.icon name="hero-star" class="w-4 h-4" />
                <span>Add to Favorites</span>
              <% end %>
            </button>

            <button
              phx-click="save_to_history"
              phx-target={@myself}
              disabled={!@command_valid}
              class={[
                "modern-btn btn-ghost",
                if(!@command_valid, do: "opacity-50 cursor-not-allowed", else: "")
              ]}
            >
              <.icon name="hero-bookmark" class="w-4 h-4" />
              <span>Save to History</span>
            </button>
          </div>

          <%= if @execution_result do %>
            <div class="mt-6 p-4 rounded-lg border animate-fade-in-up">
              <%= case @execution_result.status do %>
                <% :success -> %>
                  <div class="bg-emerald-50 dark:bg-emerald-500/10 border-emerald-200 dark:border-emerald-500/30">
                    <div class="flex items-start gap-3">
                      <.icon
                        name="hero-check-circle"
                        class="w-5 h-5 text-emerald-600 dark:text-emerald-400 shrink-0 mt-0.5"
                      />
                      <div class="flex-1">
                        <h5 class="font-semibold text-emerald-900 dark:text-emerald-300 mb-1">
                          Command Executed Successfully
                        </h5>
                        <p class="text-sm text-emerald-700 dark:text-emerald-400 font-mono">
                          {@execution_result.output}
                        </p>
                      </div>
                    </div>
                  </div>
                <% :error -> %>
                  <div class="bg-red-50 dark:bg-red-500/10 border-red-200 dark:border-red-500/30">
                    <div class="flex items-start gap-3">
                      <.icon
                        name="hero-exclamation-circle"
                        class="w-5 h-5 text-red-600 dark:text-red-400 shrink-0 mt-0.5"
                      />
                      <div class="flex-1">
                        <h5 class="font-semibold text-red-900 dark:text-red-300 mb-1">
                          Command Failed
                        </h5>
                        <p class="text-sm text-red-700 dark:text-red-400 font-mono">
                          {@execution_result.output}
                        </p>
                      </div>
                    </div>
                  </div>
                <% :warning -> %>
                  <div class="bg-yellow-50 dark:bg-yellow-500/10 border-yellow-200 dark:border-yellow-500/30">
                    <div class="flex items-start gap-3">
                      <.icon
                        name="hero-exclamation-triangle"
                        class="w-5 h-5 text-yellow-600 dark:text-yellow-400 shrink-0 mt-0.5"
                      />
                      <div class="flex-1">
                        <h5 class="font-semibold text-yellow-900 dark:text-yellow-300 mb-1">
                          Command Completed with Warnings
                        </h5>
                        <p class="text-sm text-yellow-700 dark:text-yellow-400 font-mono">
                          {@execution_result.output}
                        </p>
                      </div>
                    </div>
                  </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <div class="rounded-lg bg-white dark:bg-base-200 shadow-lg p-6 border border-slate-200 dark:border-slate-700/50">
        <div class="flex items-center justify-between mb-6">
          <h4 class="text-lg font-bold text-slate-900 dark:text-white">Command History</h4>

          <div class="flex items-center gap-3">
            <div class="relative">
              <input
                type="text"
                placeholder="Search history..."
                phx-keyup="search_history"
                phx-target={@myself}
                phx-debounce="300"
                value={@search_query}
                class="w-64 px-4 py-2 pl-10 rounded-lg bg-slate-50 dark:bg-slate-800/50 border border-slate-300 dark:border-slate-700/50 text-slate-900 dark:text-white placeholder-slate-500 dark:placeholder-slate-500 focus:border-amber-500/50 focus:ring-2 focus:ring-amber-500/20 transition-all text-sm"
              />
              <.icon
                name="hero-magnifying-glass"
                class="w-4 h-4 text-slate-500 absolute left-3 top-1/2 -translate-y-1/2"
              />
            </div>

            <select
              phx-change="filter_history"
              phx-target={@myself}
              class="px-3 py-2 rounded-lg bg-slate-50 dark:bg-slate-800/50 border border-slate-300 dark:border-slate-700/50 text-slate-900 dark:text-white text-sm"
            >
              <option value="all" selected={@history_filter == "all"}>All Commands</option>
              <option value="successful" selected={@history_filter == "successful"}>
                Successful Only
              </option>
              <option value="failed" selected={@history_filter == "failed"}>Failed Only</option>
              <option value="favorites" selected={@history_filter == "favorites"}>Favorites</option>
            </select>
          </div>
        </div>

        <%= if length(@command_history) > 0 do %>
          <div class="space-y-0 divide-y divide-slate-200 dark:divide-slate-800/50">
            <%= for {cmd, index} <- Enum.with_index(filtered_history(@command_history, @search_query, @history_filter)) do %>
              <div class="py-4 first:pt-0 last:pb-0 group">
                <div class="flex items-start gap-4">
                  <div class="flex flex-col items-center pt-1">
                    <div class={[
                      "w-8 h-8 rounded-lg flex items-center justify-center border",
                      case cmd.status do
                        "success" ->
                          "bg-emerald-100 dark:bg-emerald-500/20 border-emerald-300 dark:border-emerald-500/30"

                        "failed" ->
                          "bg-red-100 dark:bg-rose-500/20 border-red-300 dark:border-rose-500/30"

                        _ ->
                          "bg-slate-100 dark:bg-slate-500/20 border-slate-300 dark:border-slate-500/30"
                      end
                    ]}>
                      <%= case cmd.status do %>
                        <% "success" -> %>
                          <.icon
                            name="hero-check"
                            class="w-4 h-4 text-emerald-600 dark:text-emerald-400"
                          />
                        <% "failed" -> %>
                          <.icon name="hero-x-mark" class="w-4 h-4 text-red-600 dark:text-rose-400" />
                        <% _ -> %>
                          <.icon name="hero-clock" class="w-4 h-4 text-slate-600 dark:text-slate-400" />
                      <% end %>
                    </div>
                  </div>

                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-3 mb-2">
                      <span class="text-xs text-slate-500 dark:text-slate-500 font-mono">
                        #{index + 1}
                      </span>
                      <%= if cmd.template_name do %>
                        <div class="modern-badge badge-info text-xs">
                          {cmd.template_name}
                        </div>
                      <% end %>
                      <%= if cmd[:favorite] do %>
                        <.icon name="hero-star-solid" class="w-3 h-3 text-amber-500" />
                      <% end %>
                      <span class="text-xs text-slate-500 dark:text-slate-500">
                        {format_relative_time(cmd.timestamp)}
                      </span>
                    </div>

                    <div class="code-block bg-slate-100 dark:bg-slate-950/50 border border-slate-200 dark:border-slate-800/50 rounded-lg p-3 mb-2">
                      <code class="text-xs font-mono text-slate-700 dark:text-slate-300">
                        {cmd.command}
                      </code>
                    </div>

                    <%= if cmd.output do %>
                      <details class="text-xs text-slate-600 dark:text-slate-500">
                        <summary class="cursor-pointer hover:text-slate-800 dark:hover:text-slate-400 font-medium">
                          View output
                        </summary>
                        <div class={[
                          "mt-2 p-3 rounded border font-mono text-xs",
                          case cmd.status do
                            "success" ->
                              "bg-emerald-50 dark:bg-emerald-950/30 border-emerald-200 dark:border-emerald-800/50 text-emerald-800 dark:text-emerald-300"

                            "failed" ->
                              "bg-red-50 dark:bg-red-950/30 border-red-200 dark:border-red-800/50 text-red-800 dark:text-red-300"

                            _ ->
                              "bg-yellow-50 dark:bg-yellow-950/30 border-yellow-200 dark:border-yellow-800/50 text-yellow-800 dark:text-yellow-300"
                          end
                        ]}>
                          {cmd.output}
                        </div>
                      </details>
                    <% end %>
                  </div>

                  <div class="flex items-center gap-2 opacity-0 group-hover:opacity-100 transition-opacity">
                    <button
                      phx-click="reuse_command"
                      phx-value-index={index}
                      phx-target={@myself}
                      class="modern-btn btn-ghost btn-sm"
                      title="Reuse command"
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                    </button>
                    <button
                      phx-click="copy_history_command"
                      phx-value-command={cmd.command}
                      phx-target={@myself}
                      class="modern-btn btn-ghost btn-sm"
                      title="Copy to clipboard"
                    >
                      <.icon name="hero-clipboard-document" class="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="empty-state">
            <div class="w-20 h-20 rounded-2xl bg-gradient-to-br from-amber-100 to-orange-100 dark:from-amber-500/10 dark:to-orange-500/10 border border-amber-200 dark:border-amber-500/20 flex items-center justify-center mb-6">
              <.icon name="hero-command-line" class="w-10 h-10 text-amber-600 dark:text-amber-400/50" />
            </div>
            <h3 class="text-xl font-bold text-slate-900 dark:text-white mb-2">No Command History</h3>
            <p class="text-slate-600 dark:text-slate-400 mb-6">
              Build and execute commands to populate your history
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("type_command", %{"value" => command}, socket) do
    socket =
      socket
      |> assign(:current_command, command)
      |> assign(:user_typing, true)
      |> assign(:command_valid, validate_command(command))
      |> assign(:selected_template, nil)
      |> assign(:execution_result, nil)

    {:noreply, socket}
  end

  def handle_event("select_template", %{"category" => category, "name" => name}, socket) do
    template =
      socket.assigns.command_templates
      |> Enum.find(fn c -> c.category == category end)
      |> then(fn cat -> cat && Enum.find(cat.commands, &(&1.name == name)) end)

    socket =
      socket
      |> assign(:selected_template, template)
      |> assign(:command_params, build_default_params(template))
      |> assign(:show_examples, false)
      |> assign(:user_typing, false)
      |> assign(:execution_result, nil)
      |> update_current_command()

    {:noreply, socket}
  end

  def handle_event("update_param", %{"key" => key, "value" => value}, socket) do
    params = Map.put(socket.assigns.command_params, key, value)

    socket =
      socket
      |> assign(:command_params, params)
      |> assign(:execution_result, nil)
      |> update_current_command()

    {:noreply, socket}
  end

  def handle_event("toggle_flag", %{"key" => key, "flag" => flag}, socket) do
    current_flags = Map.get(socket.assigns.command_params, key, "")

    new_flags =
      if String.contains?(current_flags, flag) do
        current_flags
        |> String.split(" ")
        |> Enum.reject(&(&1 == flag))
        |> Enum.join(" ")
      else
        "#{current_flags} #{flag}" |> String.trim()
      end

    params = Map.put(socket.assigns.command_params, key, new_flags)

    socket =
      socket
      |> assign(:command_params, params)
      |> assign(:execution_result, nil)
      |> update_current_command()

    {:noreply, socket}
  end

  def handle_event("copy_command", _params, socket) do
    send(
      self(),
      {:push_event, "copy-cli", %{cmd: socket.assigns.current_command}}
    )

    socket =
      socket
      |> assign(:copy_feedback, "Copied to clipboard!")
      |> schedule_clear_feedback()

    {:noreply, socket}
  end

  def handle_event("toggle_examples", _params, socket) do
    {:noreply, assign(socket, show_examples: !socket.assigns.show_examples)}
  end

  def handle_event("use_example", %{"command" => command}, socket) do
    socket =
      socket
      |> assign(:current_command, command)
      |> assign(:command_valid, validate_command(command))
      |> assign(:user_typing, true)
      |> assign(:execution_result, nil)

    {:noreply, socket}
  end

  def handle_event("execute_command", _params, socket) do
    if socket.assigns.command_valid do
      command = socket.assigns.current_command
      parent_pid = self()

      Task.start(fn ->
        result = execute_aeropctl_command(command)
        send(parent_pid, {:command_executed, result})
      end)

      Logger.info("Executing command: #{command}")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_favorite", _params, socket) do
    template_name = socket.assigns.selected_template && socket.assigns.selected_template.name

    favorites =
      if template_name do
        if Enum.member?(socket.assigns.favorites, template_name) do
          Enum.reject(socket.assigns.favorites, &(&1 == template_name))
        else
          [template_name | socket.assigns.favorites]
        end
      else
        socket.assigns.favorites
      end

    {:noreply, assign(socket, favorites: favorites)}
  end

  def handle_event("save_to_history", _params, socket) do
    if socket.assigns.command_valid && socket.assigns.current_command != "" do
      history_entry = %{
        id: "cmd-#{System.unique_integer([:positive])}",
        command: socket.assigns.current_command,
        template_name: socket.assigns.selected_template && socket.assigns.selected_template.name,
        timestamp: DateTime.utc_now(),
        status: "pending",
        output: nil,
        favorite:
          socket.assigns.selected_template &&
            Enum.member?(socket.assigns.favorites, socket.assigns.selected_template.name)
      }

      command_history = [history_entry | socket.assigns.command_history]

      send(self(), {:update_command_history, command_history})

      socket =
        socket
        |> assign(:command_history, command_history)
        |> assign(:copy_feedback, "Saved to history!")
        |> schedule_clear_feedback()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_history", %{"value" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  def handle_event("filter_history", %{"value" => filter}, socket) do
    {:noreply, assign(socket, history_filter: filter)}
  end

  def handle_event("reuse_command", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    history =
      filtered_history(
        socket.assigns.command_history,
        socket.assigns.search_query,
        socket.assigns.history_filter
      )

    case Enum.at(history, index) do
      nil ->
        {:noreply, socket}

      command_entry ->
        socket =
          socket
          |> assign(:current_command, command_entry.command)
          |> assign(:command_valid, validate_command(command_entry.command))
          |> assign(:user_typing, true)
          |> assign(:selected_template, nil)
          |> assign(:execution_result, nil)

        {:noreply, socket}
    end
  end

  def handle_event("copy_history_command", %{"command" => command}, socket) do
    send(
      self(),
      {:push_event, "copy-cli", %{cmd: command}}
    )

    socket =
      socket
      |> assign(:copy_feedback, "Command copied!")
      |> schedule_clear_feedback()

    {:noreply, socket}
  end

  def handle_event("clear_builder", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_template, nil)
     |> assign(:current_command, "")
     |> assign(:command_params, %{})
     |> assign(:user_typing, false)
     |> assign(:command_valid, false)
     |> assign(:execution_result, nil)}
  end

  def handle_event("export_history", _params, socket) do
    script_content = generate_shell_script(socket.assigns.command_history)

    send(self(), {:download_script, script_content})

    Logger.info("Exporting command history as shell script")
    {:noreply, socket}
  end

  def handle_info({:command_executed, result}, socket) do
    command_history =
      case List.first(socket.assigns.command_history) do
        %{status: "pending", command: cmd} when cmd == socket.assigns.current_command ->
          updated_entry = %{
            List.first(socket.assigns.command_history)
            | status: result.status,
              output: result.output
          }

          [updated_entry | tl(socket.assigns.command_history)]

        _ ->
          history_entry = %{
            id: "cmd-#{System.unique_integer([:positive])}",
            command: socket.assigns.current_command,
            template_name:
              socket.assigns.selected_template && socket.assigns.selected_template.name,
            timestamp: DateTime.utc_now(),
            status: result.status,
            output: result.output,
            favorite:
              socket.assigns.selected_template &&
                Enum.member?(socket.assigns.favorites, socket.assigns.selected_template.name)
          }

          [history_entry | socket.assigns.command_history]
      end

    send(self(), {:update_command_history, command_history})

    socket =
      socket
      |> assign(:execution_result, result)
      |> assign(:command_history, command_history)

    {:noreply, socket}
  end

  def handle_info({:clear_copy_feedback, component_id}, socket) do
    if socket.assigns.myself == component_id do
      {:noreply, assign(socket, copy_feedback: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp build_default_params(nil), do: %{}

  defp build_default_params(template) do
    template.params
    |> Enum.map(fn param -> {param.key, param.default} end)
    |> Map.new()
  end

  defp update_current_command(socket) do
    command =
      if socket.assigns.selected_template do
        template = socket.assigns.selected_template.template
        params = socket.assigns.command_params

        Enum.reduce(params, template, fn {key, value}, acc ->
          String.replace(acc, "{{#{key}}}", to_string(value))
        end)
        |> String.trim()
      else
        socket.assigns.current_command
      end

    socket
    |> assign(:current_command, command)
    |> assign(:command_valid, validate_command(command))
  end

  defp schedule_clear_feedback(socket) do
    Process.send_after(self(), {:clear_copy_feedback, socket.assigns.myself}, 3000)
    socket
  end

  defp validate_command(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        false

      !String.starts_with?(command, "aeropctl") ->
        false

      length(String.split(command, " ")) < 2 ->
        false

      true ->
        valid_subcommands = ["machine", "chaos", "debug", "logs", "fleet"]
        parts = String.split(command, " ")
        subcommand = Enum.at(parts, 1)

        subcommand in valid_subcommands || String.starts_with?(subcommand || "", "--") ||
          String.length(command) > 10
    end
  end

  defp validate_command(_), do: false

  defp execute_aeropctl_command(command) do
    parts = String.split(command, " ", trim: true)

    case parts do
      ["aeropctl" | rest] ->
        simulate_command_execution(rest, command)

      _ ->
        %{
          status: "failed",
          output: "Invalid command format. Commands must start with 'aeropctl'."
        }
    end
  end

  defp simulate_command_execution(["machine", "create" | _rest], _full_command) do
    machine_id = "machine-#{:rand.uniform(999_999)}"

    %{
      status: "success",
      output: "Machine created successfully: #{machine_id}"
    }
  end

  defp simulate_command_execution(["machine", "delete" | rest], _full_command) do
    machine_id = Enum.find(rest, &(!String.starts_with?(&1, "--"))) || "unknown"

    %{
      status: "success",
      output: "Machine #{machine_id} deleted successfully"
    }
  end

  defp simulate_command_execution(["machine", "list" | _rest], _full_command) do
    %{
      status: "success",
      output:
        "Found 12 machines across 3 regions\n" <>
          "  - machine-us-east-001 (running)\n" <>
          "  - machine-eu-west-002 (running)\n" <>
          "  - machine-ap-south-003 (stopped)"
    }
  end

  defp simulate_command_execution(["machine", "migrate" | rest], _full_command) do
    if :rand.uniform(10) > 8 do
      %{
        status: "failed",
        output: "Migration failed: Target region not available"
      }
    else
      machine_id = Enum.find(rest, &(!String.starts_with?(&1, "--"))) || "unknown"

      %{
        status: "success",
        output:
          "Migration started for #{machine_id}. Track progress with: aeropctl machine status #{machine_id}"
      }
    end
  end

  defp simulate_command_execution(["chaos", "inject" | rest], _full_command) do
    chaos_id = "chaos-#{:rand.uniform(999_999)}"
    chaos_type = Enum.at(rest, 0, "latency")

    %{
      status: "success",
      output: "Chaos experiment #{chaos_id} started (type: #{chaos_type})"
    }
  end

  defp simulate_command_execution(["chaos", "stop" | rest], _full_command) do
    chaos_id = Enum.at(rest, 0, "unknown")

    %{
      status: "success",
      output: "Stopped chaos experiment: #{chaos_id}"
    }
  end

  defp simulate_command_execution(["debug", "attach" | rest], _full_command) do
    machine_id = Enum.find(rest, &(!String.starts_with?(&1, "--"))) || "unknown"

    %{
      status: "success",
      output: "Debugger attached to #{machine_id}. Use 'aeropctl debug detach' to disconnect."
    }
  end

  defp simulate_command_execution(["logs", "stream" | rest], _full_command) do
    machine_id = Enum.find(rest, &(!String.starts_with?(&1, "--"))) || "unknown"

    %{
      status: "success",
      output:
        "Streaming logs from #{machine_id}...\n[2024-01-15 10:30:45] INFO: Application started\n[2024-01-15 10:30:46] INFO: Connected to database"
    }
  end

  defp simulate_command_execution(["fleet", "scale" | _rest], _full_command) do
    %{
      status: "success",
      output: "Fleet scaling initiated. Target: 10 machines. Current: 7 machines."
    }
  end

  defp simulate_command_execution(["fleet", "optimize" | rest], _full_command) do
    strategy = Enum.find(rest, &String.starts_with?(&1, "--")) || "--balanced"

    %{
      status: "warning",
      output:
        "Optimization complete using #{strategy} strategy.\nWarning: 2 machines flagged for rebalancing."
    }
  end

  defp simulate_command_execution(_command_parts, full_command) do
    %{
      status: "failed",
      output: "Unknown command: #{full_command}\nRun 'aeropctl --help' for available commands."
    }
  end

  defp generate_shell_script(history) do
    header = """
    #!/bin/bash
    # AeroPhoenix CLI Command History
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    # Total commands: #{length(history)}

    set -e  # Exit on error

    """

    commands =
      history
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {cmd, index} ->
        """
        # Command ##{index} - #{cmd.template_name || "Custom"}
        # Executed: #{format_timestamp(cmd.timestamp)}
        # Status: #{cmd.status}
        #{cmd.command}
        """
      end)
      |> Enum.join("\n")

    header <> commands
  end

  defp format_timestamp(timestamp) when is_struct(timestamp, DateTime) do
    DateTime.to_iso8601(timestamp)
  end

  defp format_timestamp(_), do: "Unknown"

  defp category_icon("Machine Management"), do: "hero-server"
  defp category_icon("Chaos Engineering"), do: "hero-bolt"
  defp category_icon("Debugging"), do: "hero-bug-ant"
  defp category_icon("Fleet Management"), do: "hero-squares-2x2"
  defp category_icon(_), do: "hero-command-line"

  defp humanize_param(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp filtered_history(history, search_query, filter) do
    history
    |> filter_by_status(filter)
    |> filter_by_search(search_query)
  end

  defp filter_by_status(history, "all"), do: history

  defp filter_by_status(history, "successful"),
    do: Enum.filter(history, &(&1.status == "success"))

  defp filter_by_status(history, "failed"), do: Enum.filter(history, &(&1.status == "failed"))
  defp filter_by_status(history, "favorites"), do: Enum.filter(history, & &1[:favorite])
  defp filter_by_status(history, _), do: history

  defp filter_by_search(history, ""), do: history

  defp filter_by_search(history, query) do
    query_lower = String.downcase(query)

    Enum.filter(history, fn cmd ->
      String.contains?(String.downcase(cmd.command), query_lower) ||
        (cmd.template_name && String.contains?(String.downcase(cmd.template_name), query_lower)) ||
        (cmd.output && String.contains?(String.downcase(cmd.output), query_lower))
    end)
  end

  defp format_relative_time(timestamp) when is_struct(timestamp, DateTime) do
    diff = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp format_relative_time(_), do: "Just now"
end
