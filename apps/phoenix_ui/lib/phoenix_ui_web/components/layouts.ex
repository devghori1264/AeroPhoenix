defmodule PhoenixUiWeb.Layouts do
  use PhoenixUiWeb, :html
  embed_templates("layouts/*")
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 glass border-b border-[var(--border)] backdrop-blur-xl sticky top-0 z-40">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2 sm:gap-3 group">
          <img
            src={~p"/images/logo.svg"}
            width="36"
            class="transition-transform group-hover:scale-110"
          />
          <div class="flex flex-col">
            <span class="text-sm font-semibold gradient-text">
              Phoenix v{Application.spec(:phoenix, :vsn)}
            </span>
            <span class="text-xs text-[var(--text-muted)] hidden sm:inline">
              AeroPhoenix Platform
            </span>
          </div>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-row px-1 space-x-2 sm:space-x-4 items-center">
          <li class="hidden md:block">
            <a href="https://phoenixframework.org/" class="btn-demo text-sm px-3 py-2">Website</a>
          </li>
          <li class="hidden md:block">
            <a href="https://github.com/phoenixframework/phoenix" class="btn-demo text-sm px-3 py-2">
              GitHub
            </a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li class="hidden sm:block">
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn-demo text-sm px-4 py-2">
              Get Started <span aria-hidden="true" class="ml-1">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <label class="switch">
        <input id="theme-checkbox" type="checkbox" />
        <span class="slider"></span>
      </label>
    </div>
    """
  end
end
