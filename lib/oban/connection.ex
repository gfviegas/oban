defmodule Oban.Connection do
  @moduledoc false

  @behaviour Postgrex.SimpleConnection

  alias Oban.{Config, Repo}
  alias Postgrex.SimpleConnection, as: Simple

  defmodule State do
    @moduledoc false

    @enforce_keys [:conf]
    defstruct [:conf, :from, :ref, connected?: false, channels: %{}, listeners: %{}]
  end

  @doc false
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server), do: Simple.call(server, :connected?)

  @doc false
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    %{id: opts[:name], start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(Keyword.t()) :: {:ok, pid} | {:error, Postgrex.Error.t()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    conf = Keyword.fetch!(opts, :conf)

    call_opts = [conf: conf]

    conn_opts =
      conf
      |> Repo.config()
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:auto_reconnect, true)
      |> Keyword.put_new(:sync_connect, false)

    Simple.start_link(__MODULE__, call_opts, conn_opts)
  end

  @impl Simple
  def init(args) do
    {:ok, struct!(State, args)}
  end

  @impl Simple
  def notify(full_channel, payload, %State{} = state) do
    decoded = Jason.decode!(payload)

    if in_scope?(decoded, state.conf) do
      channel = reverse_channel(full_channel)

      for pid <- Map.get(state.channels, full_channel, []) do
        send(pid, {:notification, channel, decoded})
      end
    end

    :ok
  end

  @impl Simple
  def handle_connect(%State{channels: channels} = state) do
    state = %{state | connected?: true}

    if map_size(channels) > 0 do
      parts =
        channels
        |> Map.keys()
        |> Enum.map_join("\n", &~s(LISTEN "#{&1}";))

      query = "DO $$BEGIN #{parts} END$$"

      {:query, query, state}
    else
      {:noreply, state}
    end
  end

  @impl Simple
  def handle_disconnect(%State{} = state) do
    {:noreply, %{state | connected?: false}}
  end

  @impl Simple
  def handle_call({:query, query}, from, %State{} = state) do
    {:query, query, %{state | from: from}}
  end

  def handle_call(:connected?, from, %State{} = state) do
    Simple.reply(from, state.connected?)

    {:noreply, state}
  end

  def handle_call({:listen, channels}, {pid, _} = from, %State{} = state) do
    new_channels = channels -- Map.keys(state.channels)

    state =
      state
      |> put_listener(pid, channels)
      |> put_channels(pid, channels)

    if state.connected? and Enum.any?(new_channels) do
      parts = Enum.map_join(new_channels, " \n", &~s(LISTEN "#{&1}";))
      query = "DO $$BEGIN #{parts} END$$"

      {:query, query, %{state | from: from}}
    else
      Simple.reply(from, :ok)

      {:noreply, state}
    end
  end

  def handle_call({:unlisten, channels}, {pid, _} = from, %State{} = state) do
    state =
      state
      |> del_listener(pid, channels)
      |> del_channels(pid, channels)

    del_channels = channels -- Map.keys(state.channels)

    if state.connected? and Enum.any?(del_channels) do
      parts = Enum.map_join(del_channels, " \n", &~s(UNLISTEN "#{&1}";))
      query = "DO $$BEGIN #{parts} END$$"

      {:query, query, %{state | from: from}}
    else
      Simple.reply(from, :ok)

      {:noreply, state}
    end
  end

  @impl Simple
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{} = state) do
    case Map.pop(state.listeners, pid) do
      {{_ref, channel_set}, listeners} ->
        state =
          state
          |> Map.put(:listeners, listeners)
          |> del_channels(pid, MapSet.to_list(channel_set))

        {:noreply, state}

      {nil, _listeners} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl Simple
  def handle_result(result, %State{from: from} = state) do
    if result.num_rows > 0 do
      Simple.reply(from, {:ok, result})
    else
      Simple.reply(from, :ok)
    end

    {:noreply, %{state | from: nil}}
  end

  # Helpers

  defp reverse_channel(full_channel) do
    [_prefix, "oban_" <> shortcut] = String.split(full_channel, ".", parts: 2)

    String.to_existing_atom(shortcut)
  end

  defp in_scope?(%{"ident" => "any"}, _conf), do: true
  defp in_scope?(%{"ident" => ident}, conf), do: Config.match_ident?(conf, ident)
  defp in_scope?(_decoded, _conf), do: true

  defp put_listener(%{listeners: listeners} = state, pid, channels) do
    new_set = MapSet.new(channels)

    listeners =
      case Map.get(listeners, pid) do
        {ref, old_set} ->
          Map.replace!(listeners, pid, {ref, MapSet.union(old_set, new_set)})

        nil ->
          ref = Process.monitor(pid)

          Map.put(listeners, pid, {ref, new_set})
      end

    %{state | listeners: listeners}
  end

  defp put_channels(state, pid, channels) do
    listener_channels =
      for channel <- channels, reduce: state.channels do
        acc -> Map.update(acc, channel, [pid], &[pid | &1])
      end

    %{state | channels: listener_channels}
  end

  defp del_listener(%{listeners: listeners} = state, pid, channels) do
    new_set = MapSet.new(channels)

    listeners =
      case Map.get(listeners, pid) do
        {ref, old_set} ->
          del_set = MapSet.difference(old_set, new_set)

          if MapSet.size(del_set) == 0 do
            Process.demonitor(ref)

            Map.delete(listeners, pid)
          else
            Map.replace!(listeners, pid, {ref, del_set})
          end

        nil ->
          listeners
      end

    %{state | listeners: listeners}
  end

  defp del_channels(state, pid, channels) do
    listener_channels =
      for channel <- channels, reduce: state.channels do
        acc ->
          acc = Map.update(acc, channel, [], &List.delete(&1, pid))

          if Enum.empty?(acc[channel]), do: Map.delete(acc, channel), else: acc
      end

    %{state | channels: listener_channels}
  end
end
