defmodule SymphonyElixir.OrchestratorManager do
  @moduledoc """
  Starts and restarts runtime workers after managed setup is complete.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, SettingsStore}

  @runtime_children [SymphonyElixir.Orchestrator, SymphonyElixir.StatusDashboard]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec restart_runtime() :: :ok | {:error, term()}
  def restart_runtime do
    GenServer.call(__MODULE__, :restart_runtime)
  end

  @spec stop_runtime() :: :ok
  def stop_runtime do
    GenServer.call(__MODULE__, :stop_runtime)
  end

  @spec status() :: :running | :setup_required | {:error, term()}
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> :setup_required
    end
  end

  @impl true
  def init(_opts) do
    maybe_start_runtime()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:restart_runtime, _from, state) do
    stop_runtime_children()
    reply = maybe_start_runtime()
    {:reply, reply, state}
  end

  def handle_call(:stop_runtime, _from, state) do
    stop_runtime_children()
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, runtime_status(), state}
  end

  defp maybe_start_runtime do
    if runtime_enabled?() do
      with :ok <- ensure_runtime_supervisor(),
           :ok <- ensure_workflow_ready() do
        start_runtime_children()
      end
    else
      :ok
    end
  end

  defp runtime_enabled? do
    case Application.get_env(:symphony_elixir, :runtime_mode, :managed) do
      :workflow -> true
      :managed -> SettingsStore.configured?()
      _ -> false
    end
  end

  defp ensure_runtime_supervisor do
    case Process.whereis(SymphonyElixir.RuntimeSupervisor) do
      pid when is_pid(pid) -> :ok
      _ -> {:error, :runtime_supervisor_unavailable}
    end
  end

  defp ensure_workflow_ready do
    case Config.settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_runtime_children do
    Enum.reduce_while(@runtime_children, :ok, fn child, :ok ->
      case start_child(child) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_child(child) do
    case DynamicSupervisor.start_child(SymphonyElixir.RuntimeSupervisor, child) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start #{inspect(child)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stop_runtime_children do
    Enum.each(@runtime_children, fn child ->
      case Process.whereis(child) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(SymphonyElixir.RuntimeSupervisor, pid)

        _ ->
          :ok
      end
    end)
  end

  defp runtime_status do
    if Process.whereis(SymphonyElixir.Orchestrator) do
      :running
    else
      :setup_required
    end
  end
end
