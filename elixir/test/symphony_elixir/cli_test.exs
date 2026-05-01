defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{CLI, SecretStore, SettingsStore}

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defmodule FakeSecretStore do
    @behaviour SecretStore

    def available?, do: true

    def get(_service, account) do
      case Agent.get(__MODULE__, &Map.get(&1, account)) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end

    def put(_service, account, value) do
      Agent.update(__MODULE__, &Map.put(&1, account, value))
    end
  end

  setup do
    config_dir = Path.join(System.tmp_dir!(), "symphony-cli-test-#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: FakeSecretStore,
      start: {Agent, :start_link, [fn -> %{} end, [name: FakeSecretStore]]}
    })

    Application.put_env(:symphony_elixir, :settings_config_dir, config_dir)
    Application.put_env(:symphony_elixir, :secret_store_module, FakeSecretStore)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      Application.delete_env(:symphony_elixir, :settings_config_dir)
      Application.delete_env(:symphony_elixir, :secret_store_module)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      Application.delete_env(:symphony_elixir, :server_port_override)
      Application.delete_env(:symphony_elixir, :runtime_mode)
      File.rm_rf(config_dir)
    end)

    %{config_dir: config_dir}
  end

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps =
      deps(%{
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        set_workflow_file_path: fn _path ->
          send(parent, :workflow_set)
          :ok
        end,
        set_logs_root: fn _path ->
          send(parent, :logs_root_set)
          :ok
        end,
        set_server_port_override: fn _port ->
          send(parent, :port_set)
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps =
      deps(%{
        file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps =
      deps(%{
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          path == expanded_path
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps =
      deps(%{
        file_regular?: fn _path -> false end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:error, :boom} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "managed start uses app settings workflow and default port without acknowledgement" do
    parent = self()

    deps =
      deps(%{
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_path, path})
          :ok
        end,
        set_server_port_override: fn port ->
          send(parent, {:port, port})
          :ok
        end,
        set_runtime_mode: fn mode ->
          send(parent, {:mode, mode})
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.evaluate(["start", "--no-open"], deps)
    assert_received {:workflow_path, workflow_path}
    assert workflow_path =~ "WORKFLOW.md"
    assert_received {:port, 7957}
    assert_received {:mode, :managed}
    assert_received :started
  end

  test "status prints and exits without starting the app" do
    parent = self()

    deps =
      deps(%{
        print: fn message ->
          send(parent, {:printed, message})
          :ok
        end
      })

    assert {:ok, :halt} = CLI.evaluate(["status"], deps)
    assert_received {:printed, message}
    assert message =~ "Symphony status:"
  end

  test "setup schema prints the agent-readable setup contract" do
    parent = self()

    deps =
      deps(%{
        print: fn message ->
          send(parent, {:printed, Jason.decode!(message)})
          :ok
        end
      })

    assert {:ok, :halt} = CLI.evaluate(["setup", "schema", "--json"], deps)
    assert_received {:printed, schema}
    assert schema["version"] == 1
    assert Enum.any?(schema["fields"], &(&1["key"] == "linear_api_key" and &1["secret"]))
    assert Enum.find(schema["fields"], &(&1["key"] == "active_states"))["default"] == ["Todo", "In Progress", "Rework"]
  end

  test "managed start opens setup before configuration" do
    parent = self()

    deps =
      deps(%{
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        open_browser: fn url ->
          send(parent, {:opened, url})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["start"], deps)
    assert_received {:opened, "http://127.0.0.1:7957/setup"}
  end

  test "managed start opens dashboard after configuration" do
    parent = self()

    assert {:ok, _settings} =
             SettingsStore.save_setup(%{
               "linear_api_key" => "lin_agent",
               "linear_project_slug" => "agent-project",
               "repo_url" => "https://github.com/acme/agent.git",
               "workspace_root" => "/tmp/agent-workspaces",
               "codex_command" => "codex app-server",
               "active_states" => ["Todo"],
               "terminal_states" => ["Done"],
               "server_port" => 8057
             })

    deps =
      deps(%{
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        open_browser: fn url ->
          send(parent, {:opened, url})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["start"], deps)
    assert_received {:opened, "http://127.0.0.1:8057/"}
  end

  test "managed start does not open browser with no-open" do
    parent = self()

    deps =
      deps(%{
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        open_browser: fn url ->
          send(parent, {:opened, url})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["start", "--no-open"], deps)
    refute_received {:opened, _url}
  end

  test "setup apply saves JSON setup from stdin and writes workflow", %{config_dir: config_dir} do
    payload =
      Jason.encode!(%{
        "linear_api_key" => "lin_agent",
        "linear_project_slug" => "agent-project",
        "repo_url" => "https://github.com/acme/agent.git",
        "workspace_root" => "/tmp/agent-workspaces",
        "codex_command" => "codex app-server",
        "active_states" => ["Todo"],
        "terminal_states" => ["Done"],
        "server_port" => 8057
      })

    parent = self()

    deps =
      deps(%{
        read_stdin: fn -> payload end,
        print: fn message ->
          send(parent, {:printed, Jason.decode!(message)})
          :ok
        end
      })

    assert {:ok, :halt} = CLI.evaluate(["setup", "apply", "--json"], deps)
    assert_received {:printed, %{"ok" => true, "settings" => %{"linear_project_slug" => "agent-project"}}}
    assert {:ok, "lin_agent"} = SecretStore.get(:linear_api_key)
    assert File.regular?(Path.join(config_dir, "WORKFLOW.md"))
  end

  test "config get redacts stored secrets" do
    assert {:ok, _settings} =
             SettingsStore.save_setup(%{
               "linear_api_key" => "lin_agent",
               "linear_project_slug" => "agent-project",
               "repo_url" => "https://github.com/acme/agent.git",
               "workspace_root" => "/tmp/agent-workspaces",
               "codex_command" => "codex app-server",
               "active_states" => ["Todo"],
               "terminal_states" => ["Done"],
               "server_port" => 8057
             })

    parent = self()

    deps =
      deps(%{
        print: fn message ->
          send(parent, {:printed, Jason.decode!(message)})
          :ok
        end
      })

    assert {:ok, :halt} = CLI.evaluate(["config", "get", "--json"], deps)
    assert_received {:printed, config}
    assert config["secrets"]["linear_api_key"] == "stored"
    refute inspect(config) =~ "lin_agent"
  end

  test "config set merges a JSON patch and regenerates workflow" do
    assert {:ok, _settings} =
             SettingsStore.save_setup(%{
               "linear_api_key" => "lin_agent",
               "linear_project_slug" => "old-project",
               "repo_url" => "https://github.com/acme/agent.git",
               "workspace_root" => "/tmp/agent-workspaces",
               "codex_command" => "codex app-server",
               "active_states" => ["Todo"],
               "terminal_states" => ["Done"],
               "server_port" => 8057
             })

    parent = self()

    deps =
      deps(%{
        read_stdin: fn -> Jason.encode!(%{"linear_project_slug" => "new-project"}) end,
        print: fn message ->
          send(parent, {:printed, Jason.decode!(message)})
          :ok
        end
      })

    assert {:ok, :halt} = CLI.evaluate(["config", "set", "--json"], deps)
    assert_received {:printed, %{"ok" => true, "settings" => %{"linear_project_slug" => "new-project"}}}
    assert File.read!(SettingsStore.workflow_path()) =~ ~s(project_slug: "new-project")
  end

  defp deps(overrides) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        set_runtime_mode: fn _mode -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        open_browser: fn _url -> :ok end,
        read_stdin: fn -> "{}" end,
        print: fn _message -> :ok end
      },
      overrides
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
