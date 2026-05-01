defmodule SymphonyElixirWeb.SetupLive do
  @moduledoc """
  First-run and settings UI for packaged Symphony installs.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{OrchestratorManager, SettingsStore}

  @impl true
  def mount(_params, _session, socket) do
    values = SettingsStore.form_values()

    {:ok,
     socket
     |> assign(:values, form_values(values))
     |> assign(:configured?, SettingsStore.configured?())
     |> assign(:error, nil)
     |> assign(:saved?, false)}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    case SettingsStore.save_setup(params) do
      {:ok, settings} ->
        :ok = SettingsStore.apply_workflow_path()
        restart_result = OrchestratorManager.restart_runtime()

        socket =
          socket
          |> assign(:values, form_values(settings))
          |> assign(:configured?, SettingsStore.configured?())
          |> assign(:saved?, restart_result == :ok)
          |> assign(:error, restart_error(restart_result))

        {:noreply, socket}

      {:error, _reason, message} ->
        {:noreply, assign(socket, :error, message)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Setup</p>
            <h1 class="hero-title"><%= if @configured?, do: "Settings", else: "Connect your workspace" %></h1>
            <p class="hero-copy">
              Save the local configuration Symphony needs to poll Linear, create workspaces, and run Codex.
            </p>
          </div>

          <div class="status-stack">
            <span class={if @configured?, do: "status-badge status-badge-live", else: "status-badge status-badge-offline"}>
              <span class="status-badge-dot"></span>
              <%= if @configured?, do: "Configured", else: "Setup required" %>
            </span>
          </div>
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Setup not saved</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% end %>

      <%= if @saved? and is_nil(@error) do %>
        <section class="success-card">
          <h2 class="success-title">Symphony is ready</h2>
          <p class="success-copy">The workflow was generated and the orchestrator runtime has been started.</p>
        </section>
      <% end %>

      <section class="section-card">
        <form phx-submit="save" class="settings-form">
          <div class="form-grid">
            <label class="field">
              <span>Linear API key</span>
              <input
                type="password"
                name="settings[linear_api_key]"
                value=""
                placeholder={if @configured?, do: "Stored in OS keychain", else: "lin_api_..."}
                autocomplete="off"
              />
            </label>

            <label class="field">
              <span>Linear project slug</span>
              <input type="text" name="settings[linear_project_slug]" value={@values.linear_project_slug} />
            </label>

            <label class="field field-wide">
              <span>Repository clone URL</span>
              <input type="text" name="settings[repo_url]" value={@values.repo_url} />
            </label>

            <label class="field field-wide">
              <span>Workspace root</span>
              <input type="text" name="settings[workspace_root]" value={@values.workspace_root} />
            </label>

            <label class="field field-wide">
              <span>Codex command</span>
              <input type="text" name="settings[codex_command]" value={@values.codex_command} />
            </label>

            <label class="field">
              <span>Server port</span>
              <input type="number" min="0" name="settings[server_port]" value={@values.server_port} />
            </label>

            <label class="field">
              <span>Active states</span>
              <textarea name="settings[active_states]" rows="5"><%= @values.active_states %></textarea>
            </label>

            <label class="field">
              <span>Terminal states</span>
              <textarea name="settings[terminal_states]" rows="5"><%= @values.terminal_states %></textarea>
            </label>
          </div>

          <div class="form-actions">
            <a class="secondary-link" href="/">Dashboard</a>
            <button type="submit">Save and start</button>
          </div>
        </form>
      </section>
    </section>
    """
  end

  defp form_values(values) do
    %{
      linear_project_slug: Map.get(values, "linear_project_slug", ""),
      repo_url: Map.get(values, "repo_url", ""),
      workspace_root: Map.get(values, "workspace_root", ""),
      codex_command: Map.get(values, "codex_command", "codex app-server"),
      server_port: Map.get(values, "server_port", SettingsStore.default_port()),
      active_states: states_text(Map.get(values, "active_states", [])),
      terminal_states: states_text(Map.get(values, "terminal_states", []))
    }
  end

  defp states_text(values) when is_list(values), do: Enum.join(values, "\n")
  defp states_text(value) when is_binary(value), do: value
  defp states_text(_value), do: ""

  defp restart_error(:ok), do: nil
  defp restart_error({:error, reason}), do: "Settings saved, but the orchestrator did not start: #{inspect(reason)}"
end
