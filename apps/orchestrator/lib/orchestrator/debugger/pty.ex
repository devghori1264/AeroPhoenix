defmodule Orchestrator.Debugger.PTY do
  use GenServer
  require Logger

  @type t :: %__MODULE__{
          machine_id: String.t(),
          port: port() | nil,
          session_pid: pid(),
          shell: String.t(),
          env: map(),
          cwd: String.t(),
          size: {rows :: integer(), cols :: integer()},
          buffer: binary(),
          created_at: DateTime.t()
        }
  defstruct [
    :machine_id,
    :port,
    :session_pid,
    shell: "/bin/bash",
    env: %{},
    cwd: "/root",
    size: {24, 80},
    buffer: "",
    created_at: nil
  ]

  @spec start_link(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(machine_id, session_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {machine_id, session_pid, opts})
  end

  @spec send_input(pid(), binary()) :: :ok | {:error, term()}
  def send_input(pty_pid, data) when is_binary(data) do
    GenServer.call(pty_pid, {:send_input, data})
  end

  @spec resize(pid(), integer(), integer()) :: :ok | {:error, term()}
  def resize(pty_pid, rows, cols) when is_integer(rows) and is_integer(cols) do
    GenServer.call(pty_pid, {:resize, rows, cols})
  end

  @spec send_signal(pid(), atom()) :: :ok | {:error, term()}
  def send_signal(pty_pid, signal) when is_atom(signal) do
    GenServer.call(pty_pid, {:send_signal, signal})
  end

  @spec get_state(pid()) :: {:ok, map()}
  def get_state(pty_pid) do
    GenServer.call(pty_pid, :get_state)
  end

  @spec stop(pid()) :: :ok
  def stop(pty_pid) do
    GenServer.stop(pty_pid, :normal)
  end

  @impl true
  def init({machine_id, session_pid, opts}) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      machine_id: machine_id,
      session_pid: session_pid,
      shell: Keyword.get(opts, :shell, "/bin/bash"),
      env: Keyword.get(opts, :env, %{}),
      cwd: Keyword.get(opts, :cwd, "/root"),
      size: Keyword.get(opts, :size, {24, 80}),
      created_at: DateTime.utc_now()
    }

    {:ok, state, {:continue, :spawn_shell}}
  end

  @impl true
  def handle_continue(:spawn_shell, state) do
    case spawn_pty_process(state) do
      {:ok, port} ->
        Logger.info("PTY session spawned",
          machine_id: state.machine_id,
          shell: state.shell
        )

        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.error("Failed to spawn PTY",
          machine_id: state.machine_id,
          reason: inspect(reason)
        )

        {:stop, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_input, data}, _from, %{port: port} = state) when is_port(port) do
    try do
      processed_data = process_control_chars(data)
      Port.command(port, processed_data)
      {:reply, :ok, state}
    rescue
      e ->
        Logger.error("Failed to send input to PTY",
          machine_id: state.machine_id,
          error: Exception.message(e)
        )

        {:reply, {:error, :send_failed}, state}
    end
  end

  @impl true
  def handle_call({:resize, rows, cols}, _from, %{port: port} = state) when is_port(port) do
    resize_cmd =
      Jason.encode!(%{
        type: "resize",
        rows: rows,
        cols: cols
      }) <> "\n"

    try do
      Port.command(port, resize_cmd)
      new_state = %{state | size: {rows, cols}}

      Logger.debug("Terminal resized",
        machine_id: state.machine_id,
        rows: rows,
        cols: cols
      )

      {:reply, :ok, new_state}
    rescue
      e ->
        Logger.error("Failed to resize terminal",
          machine_id: state.machine_id,
          error: Exception.message(e)
        )

        {:reply, {:error, :resize_failed}, state}
    end
  end

  @impl true
  def handle_call({:send_signal, signal}, _from, %{port: port} = state) when is_port(port) do
    signal_num = signal_to_number(signal)

    signal_cmd =
      Jason.encode!(%{
        type: "signal",
        signal: signal_num
      }) <> "\n"

    try do
      Port.command(port, signal_cmd)

      Logger.debug("Signal sent to PTY",
        machine_id: state.machine_id,
        signal: signal
      )

      {:reply, :ok, state}
    rescue
      e ->
        Logger.error("Failed to send signal",
          machine_id: state.machine_id,
          signal: signal,
          error: Exception.message(e)
        )

        {:reply, {:error, :signal_failed}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state_info = %{
      machine_id: state.machine_id,
      shell: state.shell,
      cwd: state.cwd,
      size: state.size,
      created_at: state.created_at,
      active: is_port(state.port)
    }

    {:reply, {:ok, state_info}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    send(state.session_pid, {:pty_output, data})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("PTY process exited",
      machine_id: state.machine_id,
      exit_status: status
    )

    send(state.session_pid, {:pty_exited, status})
    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warn("PTY port exited unexpectedly",
      machine_id: state.machine_id,
      reason: inspect(reason)
    )

    send(state.session_pid, {:pty_crashed, reason})
    {:stop, {:port_terminated, reason}, %{state | port: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message in PTY",
      machine_id: state.machine_id,
      message: inspect(msg)
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = state) when is_port(port) do
    signal_cmd = Jason.encode!(%{type: "shutdown"}) <> "\n"

    try do
      Port.command(port, signal_cmd)
      Process.sleep(100)
    catch
      _, _ -> :ok
    end

    Port.close(port)
    Logger.info("PTY session terminated", machine_id: state.machine_id)
    :ok
  end

  def terminate(_reason, state) do
    Logger.info("PTY session terminated (no active port)",
      machine_id: state.machine_id
    )

    :ok
  end

  defp spawn_pty_process(state) do
    env_list = build_env_list(state.env, state.size)
    {rows, cols} = state.size

    args = [
      "--machine-id",
      state.machine_id,
      "--shell",
      state.shell,
      "--cwd",
      state.cwd,
      "--rows",
      Integer.to_string(rows),
      "--cols",
      Integer.to_string(cols)
    ]

    wrapper_path = Application.app_dir(:orchestrator, "priv/pty_wrapper")

    try do
      port =
        Port.open(
          {:spawn_executable, wrapper_path},
          [
            :binary,
            :exit_status,
            {:args, args},
            {:env, env_list},
            {:packet, 4}
          ]
        )

      {:ok, port}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp build_env_list(custom_env, {rows, cols}) do
    base_env = %{
      "TERM" => "xterm-256color",
      "LINES" => Integer.to_string(rows),
      "COLUMNS" => Integer.to_string(cols),
      "LANG" => "en_US.UTF-8",
      "LC_ALL" => "en_US.UTF-8"
    }

    Map.merge(base_env, custom_env)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp process_control_chars(data) do
    data
    |> handle_ctrl_c()
    |> handle_ctrl_d()
  end

  defp handle_ctrl_c(<<3>> <> rest) do
    <<3>> <> rest
  end

  defp handle_ctrl_c(data), do: data

  defp handle_ctrl_d(<<4>> <> _rest = data) do
    data
  end

  defp handle_ctrl_d(data), do: data
  defp signal_to_number(:int), do: 2
  defp signal_to_number(:quit), do: 3
  defp signal_to_number(:kill), do: 9
  defp signal_to_number(:term), do: 15
  defp signal_to_number(:tstp), do: 20
  defp signal_to_number(_), do: 15
end
