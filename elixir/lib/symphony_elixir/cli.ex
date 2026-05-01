defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.{Config, LogFile, OrchestratorManager, SettingsStore, WorkflowGenerator}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @managed_switches [logs_root: :string, port: :integer, no_open: :boolean]
  @json_switches [json: :boolean]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          set_runtime_mode: (atom() -> :ok),
          ensure_all_started: (-> ensure_started_result()),
          open_browser: (String.t() -> :ok),
          read_stdin: (-> String.t()),
          print: (String.t() -> term())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, :halt} ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, :halt} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      ["start" | rest] ->
        run_managed(:start, rest, deps)

      ["setup" | rest] ->
        run_setup(rest, deps)

      ["config" | rest] ->
        run_config(rest, deps)

      ["workflow" | rest] ->
        run_workflow_command(rest, deps)

      ["status" | rest] ->
        run_status(rest, deps)

      ["stop" | rest] ->
        run_stop(rest, deps)

      _ ->
        run_workflow(args, deps)
    end
  end

  defp run_workflow(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- deps.set_runtime_mode.(:workflow) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- deps.set_runtime_mode.(:workflow) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony start [--port <port>] [--no-open] | symphony setup [--port <port>] [--no-open] | symphony setup schema --json | symphony setup status --json | symphony setup apply --json < setup.json | symphony config get --json | symphony config set --json < patch.json | symphony workflow render | symphony workflow validate | symphony status [--json] | symphony stop | symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_runtime_mode: &set_runtime_mode/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      open_browser: &open_browser/1,
      read_stdin: fn -> IO.read(:stdio, :eof) end,
      print: &IO.puts/1
    }
  end

  defp run_setup(["schema" | rest], deps) do
    with :ok <- require_json_flag(rest) do
      print_json(SettingsStore.setup_schema(), deps)
      {:ok, :halt}
    end
  end

  defp run_setup(["status" | rest], deps) do
    with :ok <- require_json_flag(rest) do
      print_json(SettingsStore.setup_status(), deps)
      {:ok, :halt}
    end
  end

  defp run_setup(["apply" | rest], deps) do
    with :ok <- require_json_flag(rest),
         {:ok, params} <- read_json_stdin(deps),
         {:ok, settings} <- SettingsStore.save_setup(params) do
      print_json(%{"ok" => true, "settings" => settings, "workflow_path" => SettingsStore.workflow_path()}, deps)
      {:ok, :halt}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _reason, message} -> {:error, message}
      {:error, reason} -> {:error, "Failed to apply setup: #{inspect(reason)}"}
    end
  end

  defp run_setup(rest, deps), do: run_managed(:setup, rest, deps)

  defp run_config(["get" | rest], deps) do
    with :ok <- require_json_flag(rest) do
      print_json(SettingsStore.redacted_config(), deps)
      {:ok, :halt}
    end
  end

  defp run_config(["set" | rest], deps) do
    with :ok <- require_json_flag(rest),
         {:ok, patch} <- read_json_stdin(deps),
         {:ok, settings} <- SettingsStore.update_setup(patch) do
      print_json(%{"ok" => true, "settings" => settings, "workflow_path" => SettingsStore.workflow_path()}, deps)
      {:ok, :halt}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _reason, message} -> {:error, message}
      {:error, reason} -> {:error, "Failed to update config: #{inspect(reason)}"}
    end
  end

  defp run_config(_args, _deps), do: {:error, usage_message()}

  defp run_workflow_command(["render"], deps) do
    SettingsStore.form_values()
    |> WorkflowGenerator.generate()
    |> deps.print.()

    {:ok, :halt}
  rescue
    error -> {:error, "Failed to render workflow: #{Exception.message(error)}"}
  end

  defp run_workflow_command(["validate"], deps) do
    with :ok <- SettingsStore.apply_workflow_path(),
         :ok <- Config.validate!() do
      deps.print.("Workflow is valid: #{SettingsStore.workflow_path()}")
      {:ok, :halt}
    else
      {:error, reason} -> {:error, "Workflow is invalid: #{inspect(reason)}"}
    end
  end

  defp run_workflow_command(_args, _deps), do: {:error, usage_message()}

  defp run_managed(kind, args, deps) when kind in [:start, :setup] do
    case OptionParser.parse(args, strict: @managed_switches) do
      {opts, [], []} ->
        start_managed(kind, opts, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp start_managed(kind, opts, deps) do
    with :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_managed_port(opts, deps),
         :ok <- deps.set_runtime_mode.(:managed),
         :ok <- deps.set_workflow_file_path.(SettingsStore.workflow_path()),
         {:ok, _started_apps} <- deps.ensure_all_started.() do
      announce_managed_start(kind, opts, deps)
    else
      {:error, reason} -> {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  defp announce_managed_start(kind, opts, deps) do
    path = if kind == :setup, do: "/setup", else: default_managed_path()
    url = "http://127.0.0.1:#{managed_port(opts)}#{path}"
    deps.print.("Symphony is running at #{url}")

    maybe_open_browser(url, opts, deps)
    :ok
  end

  defp maybe_open_browser(url, opts, deps) do
    unless Keyword.get(opts, :no_open, false) do
      deps.open_browser.(url)
    end
  end

  defp run_status(["--json"], deps) do
    status =
      case OrchestratorManager.status() do
        :running -> %{"runtime" => "running"}
        :setup_required -> %{"runtime" => "setup_required"}
        {:error, reason} -> %{"runtime" => "error", "reason" => inspect(reason)}
      end

    print_json(Map.merge(status, SettingsStore.setup_status()), deps)
    {:ok, :halt}
  end

  defp run_status([], deps) do
    status =
      case OrchestratorManager.status() do
        :running -> "running"
        :setup_required -> "setup required"
        {:error, reason} -> "error: #{inspect(reason)}"
      end

    deps.print.("Symphony status: #{status}")
    {:ok, :halt}
  end

  defp run_status(_args, _deps), do: {:error, usage_message()}

  defp require_json_flag(args) do
    case OptionParser.parse(args, strict: @json_switches) do
      {[json: true], [], []} -> :ok
      {[], [], []} -> {:error, "This command requires --json."}
      _ -> {:error, usage_message()}
    end
  end

  defp read_json_stdin(deps) do
    case deps.read_stdin.() |> Jason.decode() do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, "Expected a JSON object on stdin."}
      {:error, reason} -> {:error, "Failed to parse JSON from stdin: #{Exception.message(reason)}"}
    end
  end

  defp print_json(value, deps) do
    deps.print.(Jason.encode!(value, pretty: true))
  end

  defp run_stop([], deps) do
    _ = OrchestratorManager.stop_runtime()
    deps.print.("Symphony runtime stopped for the current BEAM node.")
    {:ok, :halt}
  catch
    :exit, _reason ->
      deps.print.("No Symphony runtime is running in this BEAM node.")
      {:ok, :halt}
  end

  defp run_stop(_args, _deps), do: {:error, usage_message()}

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_set_managed_port(opts, deps) do
    port = managed_port(opts)
    :ok = deps.set_server_port_override.(port)
  end

  defp managed_port(opts) do
    case Keyword.get_values(opts, :port) do
      [] -> SettingsStore.form_values()["server_port"] || SettingsStore.default_port()
      values -> List.last(values)
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp set_runtime_mode(mode) when mode in [:managed, :workflow] do
    Application.put_env(:symphony_elixir, :runtime_mode, mode)
    :ok
  end

  defp default_managed_path do
    if SettingsStore.configured?(), do: "/", else: "/setup"
  end

  defp open_browser(url) do
    opener =
      case :os.type() do
        {:unix, :darwin} -> System.find_executable("open")
        {:unix, _} -> System.find_executable("xdg-open")
        _ -> nil
      end

    if opener do
      _ = System.cmd(opener, [url], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
