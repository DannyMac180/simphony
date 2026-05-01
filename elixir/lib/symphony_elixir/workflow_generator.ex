defmodule SymphonyElixir.WorkflowGenerator do
  @moduledoc """
  Generates the managed `WORKFLOW.md` used by packaged Symphony installs.
  """

  @spec generate(map()) :: String.t()
  def generate(settings) when is_map(settings) do
    repo_url = Map.fetch!(settings, "repo_url")

    front_matter = [
      "---",
      "tracker:",
      "  kind: linear",
      "  api_key: $LINEAR_API_KEY",
      "  project_slug: #{yaml(Map.fetch!(settings, "linear_project_slug"))}",
      "  active_states: #{yaml(Map.fetch!(settings, "active_states"))}",
      "  terminal_states: #{yaml(Map.fetch!(settings, "terminal_states"))}",
      "polling:",
      "  interval_ms: 30000",
      "workspace:",
      "  root: #{yaml(Map.fetch!(settings, "workspace_root"))}",
      "hooks:",
      "  after_create: |",
      "    git clone --depth 1 #{shell_arg(repo_url)} .",
      "agent:",
      "  max_concurrent_agents: 10",
      "  max_turns: 20",
      "codex:",
      "  command: #{yaml(Map.fetch!(settings, "codex_command"))}",
      "  approval_policy:",
      "    reject:",
      "      sandbox_approval: true",
      "      rules: true",
      "      mcp_elicitations: true",
      "  thread_sandbox: workspace-write",
      "server:",
      "  port: #{Map.fetch!(settings, "server_port")}",
      "---"
    ]

    Enum.join(front_matter, "\n") <> "\n\n" <> prompt_template() <> "\n"
  end

  defp prompt_template do
    """
    You are working on a Linear issue {{ issue.identifier }}.

    Title: {{ issue.title }}
    Current status: {{ issue.state }}
    URL: {{ issue.url }}

    Body:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}

    Work in the provided repository copy. Keep the issue and pull request current, run the relevant validation, and stop only when the work is complete or genuinely blocked.
    """
    |> String.trim()
  end

  defp yaml(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml(value) when is_integer(value), do: Integer.to_string(value)

  defp yaml(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml/1) <> "]"
  end

  defp shell_arg(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
