defmodule Oban.Senator do
  @moduledoc false

  use GenServer

  alias Oban.{Backoff, Config, Connection, Registry}

  @type option ::
          {:name, module()}
          | {:conf, Config.t()}
          | {:key, pos_integer()}
          | {:interval, timeout()}

  @key_base 428_836_387_984

  defmodule State do
    @moduledoc false

    @enforce_keys [:conf, :key]
    defstruct [
      :conf,
      :conn_ref,
      :key,
      :timer,
      interval: :timer.seconds(30),
      leader?: false,
      leader_boost: 2
    ]
  end

  @spec leader?(Config.t() | GenServer.server()) :: boolean()
  def leader?(%Config{name: name}) do
    name
    |> Registry.via(__MODULE__)
    |> leader?()
  end

  def leader?(server), do: GenServer.call(server, :leader?)

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    opts
    |> super()
    |> Supervisor.child_spec(id: name)
  end

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    conf = Keyword.fetch!(opts, :conf)
    opts = Keyword.put_new(opts, :key, @key_base + :erlang.phash2(conf.name))

    {:ok, struct!(State, opts), {:continue, :start}}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :ok
  end

  @impl GenServer
  def handle_continue(:start, %State{} = state) do
    handle_info(:election, state)
  end

  @impl GenServer
  def handle_info(:election, %State{} = state) do
    state =
      state
      |> monitor_conn()
      |> election()
      |> schedule_election()

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, %{state | conn_ref: nil, leader?: false}}
  end

  @impl GenServer
  def handle_call(:leader?, _from, %State{} = state) do
    {:reply, state.leader?, state}
  end

  defp monitor_conn(%State{conf: conf, conn_ref: nil} = state) do
    case Registry.whereis(conf.name, Connection) do
      pid when is_pid(pid) -> %{state | conn_ref: Process.monitor(pid)}
      nil -> state
    end
  end

  defp monitor_conn(state), do: state

  defp election(state) do
    leader? = (state.leader? and connected?(state)) or acquire_lock?(state)

    %{state | leader?: leader?}
  end

  defp schedule_election(%State{interval: interval} = state) do
    base = if state.leader?, do: div(interval, state.leader_boost), else: interval
    time = Backoff.jitter(base)

    %{state | timer: Process.send_after(self(), :election, time)}
  end

  defp connected?(%State{conn_ref: nil}), do: false

  defp connected?(%State{conf: conf}) do
    conn = Registry.whereis(conf.name, Connection)

    is_pid(conn) and Process.alive?(conn) and Connection.connected?(conn)
  end

  defp acquire_lock?(%State{conf: conf, key: key} = state) do
    if connected?(state) do
      {:ok, %{rows: [[raw_boolean]]}} =
        conf.name
        |> Registry.via(Connection)
        |> GenServer.call({:query, "SELECT pg_try_advisory_lock(#{key})"})

      raw_boolean == "t"
    else
      false
    end
  catch
    :exit, _value -> false
  end
end
