defmodule SymphonyElixir.SettingsStoreTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Config, SecretStore, SettingsStore, Workflow, WorkflowGenerator}

  @endpoint SymphonyElixirWeb.Endpoint

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
    config_dir = Path.join(System.tmp_dir!(), "symphony-settings-test-#{System.unique_integer([:positive])}")

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
      File.rm_rf(config_dir)
    end)

    %{config_dir: config_dir}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  test "resolves platform-specific config directories" do
    assert SettingsStore.config_dir({:unix, :darwin}, fn _ -> nil end, "/Users/alex") ==
             "/Users/alex/Library/Application Support/Symphony"

    assert SettingsStore.config_dir({:unix, :linux}, fn "XDG_CONFIG_HOME" -> "/tmp/config" end, "/home/alex") ==
             "/tmp/config/symphony"

    assert SettingsStore.config_dir({:unix, :linux}, fn _ -> nil end, "/home/alex") ==
             "/home/alex/.config/symphony"
  end

  test "linux secret store returns unavailable when secret-tool is missing" do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "/tmp/symphony-missing-secret-tool")

    try do
      assert {:error, :unavailable} = SecretStore.Linux.get("Symphony", "linear_api_key")
      assert {:error, :unavailable} = SecretStore.Linux.put("Symphony", "linear_api_key", "secret")
    after
      restore_env("PATH", previous_path)
    end
  end

  test "saves nonsecret settings, stores Linear key in the secret store, and writes workflow", %{config_dir: config_dir} do
    assert {:ok, settings} =
             SettingsStore.save_setup(%{
               "linear_api_key" => "lin_test",
               "linear_project_slug" => "my-project",
               "repo_url" => "https://github.com/acme/app.git",
               "workspace_root" => "/tmp/workspaces",
               "codex_command" => "codex app-server",
               "active_states" => "Todo\nIn Progress",
               "terminal_states" => "Done\nCanceled",
               "server_port" => "7957"
             })

    assert settings["linear_project_slug"] == "my-project"
    assert {:ok, "lin_test"} = SecretStore.get(:linear_api_key)

    assert {:ok, persisted} = SettingsStore.load()
    refute Map.has_key?(persisted, "linear_api_key")
    assert File.regular?(Path.join(config_dir, "WORKFLOW.md"))

    Workflow.set_workflow_file_path(SettingsStore.workflow_path())
    assert {:ok, parsed} = Config.settings()
    assert parsed.tracker.api_key == "lin_test"
    assert parsed.tracker.project_slug == "my-project"
  end

  test "generated workflow includes deterministic runtime contract" do
    workflow =
      WorkflowGenerator.generate(%{
        "linear_project_slug" => "slug",
        "repo_url" => "git@github.com:acme/app.git",
        "workspace_root" => "/tmp/workspaces",
        "codex_command" => "codex app-server",
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "server_port" => 7957
      })

    assert workflow =~ "api_key: $LINEAR_API_KEY"
    assert workflow =~ "project_slug: \"slug\""
    assert workflow =~ "git clone --depth 1 'git@github.com:acme/app.git' ."
    assert workflow =~ "port: 7957"
  end

  test "setup LiveView saves settings and redacts stored secret" do
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/setup")

    assert html =~ "Connect your workspace"
    assert html =~ "Linear API key"

    html =
      view
      |> form("form", %{
        "settings" => %{
          "linear_api_key" => "lin_live",
          "linear_project_slug" => "live-project",
          "repo_url" => "https://github.com/acme/live.git",
          "workspace_root" => "/tmp/live-workspaces",
          "codex_command" => "codex app-server",
          "active_states" => "Todo\nIn Progress",
          "terminal_states" => "Done",
          "server_port" => "7957"
        }
      })
      |> render_submit()

    assert html =~ "Symphony is ready"
    assert html =~ "Stored in OS keychain"
    refute html =~ "lin_live"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

    unless Process.whereis(SymphonyElixirWeb.Endpoint) do
      start_supervised!({SymphonyElixirWeb.Endpoint, []})
    end
  end
end
