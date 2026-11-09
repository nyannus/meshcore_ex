defmodule Meshcore.Subscription do
  @moduledoc """
  Handle returned by `Meshcore.subscribe/3`.

  Events are delivered to the subscribed process as
  `{:meshcore, ref, %Meshcore.Event{}}`, where `ref` is `subscription.ref`.
  """

  @type t :: %__MODULE__{ref: reference(), mc: GenServer.server()}
  @enforce_keys [:ref, :mc]
  defstruct [:ref, :mc]
end
