defmodule PhoenixUiWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import PhoenixUiWeb.ChannelCase

      @endpoint PhoenixUiWeb.Endpoint
    end
  end

  setup _tags do
    :ok
  end
end
