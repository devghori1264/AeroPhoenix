defmodule TestGenServer do

  def call(pid, request, timeout \\ 1000) do
    GenServer.call(pid, request, timeout)
  end

  def cast(pid, request) do
    GenServer.cast(pid, request)
  end
end
