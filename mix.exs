defmodule Meshcore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyannus/meshcore_ex"

  def project do
    [
      app: :meshcore,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Meshcore",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Meshcore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:circuits_uart, "~> 1.7", optional: true},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev], runtime: false}
    ]
  end

  defp description do
    "Elixir client for MeshCore companion radios over serial, TCP and BLE. " <>
      "A port of the meshcore_py library."
  end

  defp package do
    [
      name: "meshcore",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Python reference" => "https://github.com/fdlamotte/meshcore_py"
      },
      files: ~w(lib guides mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/connecting.md",
        "guides/commands-and-events.md",
        "guides/contacts-and-messaging.md",
        "guides/channels.md",
        "guides/repeaters.md",
        "guides/device-management.md",
        "guides/signing-and-keys.md",
        "guides/monitoring-and-tracing.md",
        "guides/bots.md",
        "guides/ble.md",
        "guides/fault-tolerance.md",
        "guides/migrating-from-python.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Introduction: ["README.md", "guides/getting-started.md", "guides/connecting.md"],
        "Using the API": [
          "guides/commands-and-events.md",
          "guides/contacts-and-messaging.md",
          "guides/channels.md",
          "guides/repeaters.md",
          "guides/device-management.md",
          "guides/signing-and-keys.md"
        ],
        "Examples & recipes": [
          "guides/monitoring-and-tracing.md",
          "guides/bots.md",
          "guides/ble.md"
        ],
        Reference: [
          "guides/fault-tolerance.md",
          "guides/migrating-from-python.md",
          "CHANGELOG.md"
        ]
      ],
      groups_for_modules: [
        Core: [Meshcore, Meshcore.Event, Meshcore.Subscription, Meshcore.Client],
        Commands: [
          Meshcore.Commands,
          Meshcore.Commands.Device,
          Meshcore.Commands.Contact,
          Meshcore.Commands.Messaging,
          Meshcore.Commands.Binary,
          Meshcore.Commands.ControlData,
          Meshcore.Commands.Base
        ],
        Transports: [
          Meshcore.Transport,
          Meshcore.Transport.TCP,
          Meshcore.Transport.Serial,
          Meshcore.Transport.BLE,
          Meshcore.Transport.BLE.Adapter,
          Meshcore.Frame
        ],
        Protocol: [
          Meshcore.Packets,
          Meshcore.Reader,
          Meshcore.PacketParser,
          Meshcore.Parsing,
          Meshcore.Lpp,
          Meshcore.Util
        ]
      ]
    ]
  end
end
