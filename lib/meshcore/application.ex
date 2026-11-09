defmodule Meshcore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Meshcore.TaskSupervisor},
      {DynamicSupervisor, name: Meshcore.ConnectionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Meshcore.Supervisor)
  end
end
