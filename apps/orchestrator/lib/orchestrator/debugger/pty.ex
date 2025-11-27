defmodule Orchestrator.Debugger.PTY do
  use GenServer
  require Logger

  @type t :: %__MODULE__{
          machine_id: String.t(),
          session_pid: pid(),
          shell: String.t(),
          env: map(),
          cwd: String.t(),
          size: {rows :: integer(), cols :: integer()},
          buffer: binary(),
          created_at: DateTime.t(),
          history: [String.t()]
        }

  defstruct [
    :machine_id,
    :session_pid,
    shell: "/bin/bash",
    env: %{},
    cwd: "/root",
    size: {24, 80},
    buffer: "",
    created_at: nil,
    history: []
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
    state = %__MODULE__{
      machine_id: machine_id,
      session_pid: session_pid,
      shell: Keyword.get(opts, :shell, "/bin/bash"),
      env: Keyword.get(opts, :env, %{}),
      cwd: Keyword.get(opts, :cwd, "/root"),
      size: Keyword.get(opts, :size, {24, 80}),
      created_at: DateTime.utc_now()
    }

    {:ok, state, {:continue, :init_shell}}
  end

  @impl true
  def handle_continue(:init_shell, state) do
    welcome_msg = """
    \r\n\e[1;32mWelcome to AeroPhoenix Debugger Shell\e[0m
    \r\nConnected to machine: \e[1;36m#{state.machine_id}\e[0m
    \r\nType 'help' for available commands.\r\n
    """

    send_output(state, welcome_msg)
    send_prompt(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:send_input, input}, _from, state) do
    new_buffer = state.buffer <> input

    if String.contains?(new_buffer, "\r") or String.contains?(new_buffer, "\n") do
      {lines, remaining} = split_lines(new_buffer)

      new_state =
        Enum.reduce(lines, state, fn line, acc ->
          process_command(acc, String.trim(line))
        end)

      {:reply, :ok, %{new_state | buffer: remaining}}
    else
      {:reply, :ok, %{state | buffer: new_buffer}}
    end
  end

  @impl true
  def handle_call({:resize, rows, cols}, _from, state) do
    Logger.debug("Simulated terminal resized to #{rows}x#{cols}")
    {:reply, :ok, %{state | size: {rows, cols}}}
  end

  @impl true
  def handle_call({:send_signal, signal}, _from, state) do
    Logger.debug("Simulated signal received: #{signal}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply,
     {:ok,
      %{
        machine_id: state.machine_id,
        shell: state.shell,
        cwd: state.cwd,
        active: true
      }}, state}
  end

  defp send_output(state, data) do
    send(state.session_pid, {:pty_output, data})
  end

  defp send_prompt(state) do
    prompt = "\r\n\e[1;32mroot@#{state.machine_id}\e[0m:\e[1;34m#{state.cwd}\e[0m# "
    send_output(state, prompt)
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, ~r/\r\n|\r|\n/)

    if String.ends_with?(buffer, "\r") or String.ends_with?(buffer, "\n") do
      {parts, ""}
    else
      {List.delete_at(parts, -1), List.last(parts)}
    end
  end

  defp process_command(state, "") do
    send_prompt(state)
    state
  end

  defp process_command(state, command) do
    parts = String.split(command, " ", trim: true)
    cmd = List.first(parts)
    args = List.delete_at(parts, 0)

    new_state =
      case cmd do
        "help" ->
          output = """
          \r\nAvailable commands:
          \r\n  \e[1mhelp\e[0m      Show this help message
          \r\n  \e[1mls\e[0m        List files
          \r\n  \e[1mps\e[0m        List processes
          \r\n  \e[1mtop\e[0m       Show system stats
          \r\n  \e[1mclear\e[0m     Clear screen
          \r\n  \e[1mwhoami\e[0m    Show current user
          \r\n  \e[1mdate\e[0m      Show current date
          \r\n  \e[1mecho\e[0m      Echo arguments
          \r\n  \e[1mexit\e[0m      Close session
          """

          send_output(state, output)
          state

        "ls" ->
          output =
            "\r\nbin  boot  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var"

          send_output(state, output)
          state

        "ps" ->
          output = """
          \r\n  PID TTY          TIME CMD
          \r\n    1 ?        00:00:01 init
          \r\n   12 ?        00:00:00 erl_child_setup
          \r\n   45 ?        00:00:05 beam.smp
          \r\n   88 pts/0    00:00:00 bash
          \r\n   92 pts/0    00:00:00 ps
          """

          send_output(state, output)
          state

        "top" ->
          output = """
          \r\ntop - #{Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")} up 1 day,  2:30,  1 user,  load average: 0.05, 0.03, 0.01
          \r\nTasks:  12 total,   1 running,  11 sleeping,   0 stopped,   0 zombie
          \r\n%Cpu(s):  2.5 us,  1.2 sy,  0.0 ni, 96.3 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
          \r\nMiB Mem :   1024.0 total,    450.2 free,    250.5 used,    323.3 buff/cache
          """

          send_output(state, output)
          state

        "clear" ->
          send_output(state, "\e[2J\e[H")
          state

        "whoami" ->
          send_output(state, "\r\nroot")
          state

        "date" ->
          send_output(state, "\r\n#{DateTime.utc_now() |> DateTime.to_string()}")
          state

        "echo" ->
          send_output(state, "\r\n#{Enum.join(args, " ")}")
          state

        "exit" ->
          send_output(state, "\r\nLogout\r\n")
          Process.send_after(self(), :stop, 100)
          state

        _ ->
          send_output(state, "\r\n#{cmd}: command not found")
          state
      end

    send_prompt(new_state)
    new_state
  end

  @impl true
  def handle_info(:stop, state) do
    {:stop, :normal, state}
  end
end
