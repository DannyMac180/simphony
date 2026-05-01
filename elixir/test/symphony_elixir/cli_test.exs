defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

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
    assert_received {:printed, "Symphony status: setup required"}
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
        print: fn _message -> :ok end
      },
      overrides
    )
  end
end
