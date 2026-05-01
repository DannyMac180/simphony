defmodule SymphonyElixir.SecretStore do
  @moduledoc """
  Facade for storing Symphony secrets in the operating system keychain.
  """

  @service "Symphony"

  @callback available?() :: boolean()
  @callback get(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback put(String.t(), String.t(), String.t()) :: :ok | {:error, term()}

  @spec available?() :: boolean()
  def available? do
    provider().available?()
  end

  @spec get(atom() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(key) do
    provider().get(@service, normalize_key(key))
  end

  @spec get_value(atom() | String.t()) :: String.t() | nil
  def get_value(key) do
    case get(key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @spec put(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def put(key, value) when is_binary(value) do
    provider().put(@service, normalize_key(key), value)
  end

  @spec provider() :: module()
  def provider do
    Application.get_env(:symphony_elixir, :secret_store_module) || default_provider()
  end

  defp default_provider do
    case :os.type() do
      {:unix, :darwin} -> SymphonyElixir.SecretStore.MacOS
      {:unix, _name} -> SymphonyElixir.SecretStore.Linux
      _other -> SymphonyElixir.SecretStore.Unsupported
    end
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end

defmodule SymphonyElixir.SecretStore.MacOS do
  @moduledoc false

  @behaviour SymphonyElixir.SecretStore

  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable("security"))

  @spec get(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(service, account) do
    case System.find_executable("security") do
      nil ->
        {:error, :unavailable}

      executable ->
        case System.cmd(executable, ["find-generic-password", "-s", service, "-a", account, "-w"], stderr_to_stdout: true) do
          {value, 0} -> {:ok, String.trim_trailing(value)}
          {message, status} -> {:error, {:security, status, String.trim(message)}}
        end
    end
  end

  @spec put(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put(service, account, value) do
    case System.find_executable("security") do
      nil ->
        {:error, :unavailable}

      executable ->
        case System.cmd(executable, ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value], stderr_to_stdout: true) do
          {_message, 0} -> :ok
          {message, status} -> {:error, {:security, status, String.trim(message)}}
        end
    end
  end
end

defmodule SymphonyElixir.SecretStore.Linux do
  @moduledoc false

  @behaviour SymphonyElixir.SecretStore

  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable("secret-tool"))

  @spec get(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(service, account) do
    case System.find_executable("secret-tool") do
      nil ->
        {:error, :unavailable}

      executable ->
        case System.cmd(executable, ["lookup", "service", service, "account", account], stderr_to_stdout: true) do
          {value, 0} -> {:ok, String.trim_trailing(value)}
          {message, status} -> {:error, {:secret_tool, status, String.trim(message)}}
        end
    end
  end

  @spec put(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put(service, account, value) do
    case System.find_executable("secret-tool") do
      nil ->
        {:error, :unavailable}

      executable ->
        env = [
          {"SYMPHONY_SECRET_TOOL", executable},
          {"SYMPHONY_SECRET_VALUE", value},
          {"SYMPHONY_SECRET_LABEL", "#{service} #{account}"},
          {"SYMPHONY_SECRET_SERVICE", service},
          {"SYMPHONY_SECRET_ACCOUNT", account}
        ]

        script =
          "printf '%s' \"$SYMPHONY_SECRET_VALUE\" | \"$SYMPHONY_SECRET_TOOL\" store --label \"$SYMPHONY_SECRET_LABEL\" service \"$SYMPHONY_SECRET_SERVICE\" account \"$SYMPHONY_SECRET_ACCOUNT\""

        case System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: true) do
          {_message, 0} -> :ok
          {message, status} -> {:error, {:secret_tool, status, String.trim(message)}}
        end
    end
  end
end

defmodule SymphonyElixir.SecretStore.Unsupported do
  @moduledoc false

  @behaviour SymphonyElixir.SecretStore

  @spec available?() :: boolean()
  def available?, do: false

  @spec get(String.t(), String.t()) :: {:error, :unsupported}
  def get(_service, _account), do: {:error, :unsupported}

  @spec put(String.t(), String.t(), String.t()) :: {:error, :unsupported}
  def put(_service, _account, _value), do: {:error, :unsupported}
end
