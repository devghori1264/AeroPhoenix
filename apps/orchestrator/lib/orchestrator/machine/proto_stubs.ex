defmodule Orchestrator.Machine.Proto.DebugService.Stub do
  def connect(_endpoint, _opts), do: {:ok, :channel}
  def disconnect(_channel), do: :ok
  def attach_pty(_channel, _request), do: {:ok, :stream}
  def send_request(_stream, _request), do: :ok
  def recv(_stream), do: {:ok, :data}
end

defmodule Orchestrator.Machine.Proto.PTYRequest do
  defstruct [:command, :args, :env, :rows, :cols]
  def new(opts), do: struct(__MODULE__, opts)
end

defmodule Orchestrator.Machine.Proto.PTYInput do
  defstruct [:data]
  def new(opts), do: struct(__MODULE__, opts)
end

defmodule Orchestrator.Machine.Proto.PTYResize do
  defstruct [:rows, :cols]
  def new(opts), do: struct(__MODULE__, opts)
end
