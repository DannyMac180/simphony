defmodule SymphonyElixir.SettingsStore do
  @moduledoc """
  Persists first-run setup settings outside the repository checkout.
  """

  alias SymphonyElixir.{SecretStore, Workflow, WorkflowGenerator}

  @settings_file "settings.json"
  @workflow_file "WORKFLOW.md"
  @default_port 7957
  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type settings :: map()

  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @spec config_dir() :: Path.t()
  def config_dir do
    Application.get_env(:symphony_elixir, :settings_config_dir) ||
      config_dir(:os.type(), &System.get_env/1, System.user_home!())
  end

  @spec config_dir({atom(), atom()}, (String.t() -> String.t() | nil), Path.t()) :: Path.t()
  def config_dir({:unix, :darwin}, _env, home) do
    Path.join([home, "Library", "Application Support", "Symphony"])
  end

  def config_dir({:unix, _name}, env, home) do
    case env.("XDG_CONFIG_HOME") do
      value when is_binary(value) and value != "" -> Path.join(value, "symphony")
      _ -> Path.join([home, ".config", "symphony"])
    end
  end

  def config_dir(_os_type, _env, home), do: Path.join([home, ".symphony"])

  @spec settings_path() :: Path.t()
  def settings_path, do: Path.join(config_dir(), @settings_file)

  @spec workflow_path() :: Path.t()
  def workflow_path, do: Path.join(config_dir(), @workflow_file)

  @spec load() :: {:ok, settings()} | {:error, term()}
  def load do
    case File.read(settings_path()) do
      {:ok, content} ->
        Jason.decode(content)

      {:error, :enoent} ->
        {:error, :not_configured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec form_values() :: settings()
  def form_values do
    base = default_settings()

    case load() do
      {:ok, settings} -> Map.merge(base, settings)
      {:error, _reason} -> base
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    with {:ok, settings} <- load(),
         :ok <- validate_nonsecret_settings(settings),
         {:ok, secret} when secret != "" <- SecretStore.get(:linear_api_key),
         true <- File.regular?(workflow_path()) do
      true
    else
      _ -> false
    end
  end

  @spec apply_workflow_path() :: :ok
  def apply_workflow_path do
    Workflow.set_workflow_file_path(workflow_path())
  end

  @spec save_setup(map()) :: {:ok, settings()} | {:error, term()} | {:error, term(), String.t()}
  def save_setup(params) when is_map(params) do
    params = normalize_setup_params(params)

    with :ok <- ensure_secret_store_available(),
         :ok <- save_secret(params),
         settings <- nonsecret_settings(params),
         :ok <- validate_nonsecret_settings(settings),
         :ok <- write_settings(settings),
         :ok <- write_workflow(settings) do
      {:ok, settings}
    end
  end

  @spec default_settings() :: settings()
  def default_settings do
    %{
      "linear_project_slug" => "",
      "repo_url" => "",
      "workspace_root" => Path.join(System.user_home!(), "code/symphony-workspaces"),
      "codex_command" => "codex app-server",
      "active_states" => @default_active_states,
      "terminal_states" => @default_terminal_states,
      "server_port" => @default_port
    }
  end

  defp ensure_secret_store_available do
    if SecretStore.available?() do
      :ok
    else
      {:error, :secret_store_unavailable, "OS keychain access is unavailable. On Linux, install and unlock Secret Service/libsecret so `secret-tool` is available."}
    end
  end

  defp save_secret(%{"linear_api_key" => value}) when is_binary(value) and value != "" do
    SecretStore.put(:linear_api_key, value)
  end

  defp save_secret(_params) do
    case SecretStore.get(:linear_api_key) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      _ -> {:error, :missing_linear_api_key, "Linear API key is required."}
    end
  end

  defp write_settings(settings) do
    with :ok <- File.mkdir_p(config_dir()) do
      File.write(settings_path(), Jason.encode!(settings, pretty: true) <> "\n")
    end
  end

  defp write_workflow(settings) do
    with :ok <- File.mkdir_p(config_dir()) do
      File.write(workflow_path(), WorkflowGenerator.generate(settings))
    end
  end

  defp validate_nonsecret_settings(settings) do
    missing =
      ["linear_project_slug", "repo_url", "workspace_root", "codex_command"]
      |> Enum.filter(&blank?(Map.get(settings, &1)))

    cond do
      missing != [] ->
        {:error, {:missing_settings, missing}, "Missing required settings: #{Enum.join(missing, ", ")}"}

      not is_integer(Map.get(settings, "server_port")) or settings["server_port"] < 0 ->
        {:error, :invalid_server_port, "Server port must be a non-negative integer."}

      true ->
        :ok
    end
  end

  defp normalize_setup_params(params) do
    %{
      "linear_api_key" => normalize_string(Map.get(params, "linear_api_key")),
      "linear_project_slug" => normalize_string(Map.get(params, "linear_project_slug")),
      "repo_url" => normalize_string(Map.get(params, "repo_url")),
      "workspace_root" => normalize_string(Map.get(params, "workspace_root")),
      "codex_command" => normalize_string(Map.get(params, "codex_command", "codex app-server")),
      "active_states" => normalize_states(Map.get(params, "active_states")),
      "terminal_states" => normalize_states(Map.get(params, "terminal_states")),
      "server_port" => normalize_port(Map.get(params, "server_port"))
    }
  end

  defp nonsecret_settings(params) do
    params
    |> Map.drop(["linear_api_key"])
    |> Map.update!("active_states", &default_if_empty(&1, @default_active_states))
    |> Map.update!("terminal_states", &default_if_empty(&1, @default_terminal_states))
    |> Map.update!("codex_command", &default_if_blank(&1, "codex app-server"))
    |> Map.update!("workspace_root", &default_if_blank(&1, Path.join(System.user_home!(), "code/symphony-workspaces")))
    |> Map.update!("server_port", &(&1 || @default_port))
  end

  defp normalize_states(values) when is_list(values), do: Enum.map(values, &normalize_string/1) |> Enum.reject(&blank?/1)

  defp normalize_states(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  defp normalize_states(_value), do: []

  defp normalize_port(value) when is_integer(value), do: value

  defp normalize_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> port
      _ -> nil
    end
  end

  defp normalize_port(_value), do: nil

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""

  defp default_if_empty([], fallback), do: fallback
  defp default_if_empty(value, _fallback), do: value

  defp default_if_blank(value, fallback) when is_binary(value) do
    if blank?(value), do: fallback, else: value
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
