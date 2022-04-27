defmodule FluentdForwarder.Handler do
  @moduledoc """
  The `FluentdForwarder.Handler` specification.

  A Fluentd forward handler is a module that must export:

    * a `c:call/2` function.
    * an `c:init/1` function which takes a set of options and initializes it.

  The result returned by `c:init/1` is passed as last argument to `c:call/2`.
  Note that `c:init/1` may be called during initialization and as such it must
  not return pids, ports or values that are specific to the runtime.

  The API expected by a module plug is defined as a behaviour by the
  `FluentdForwarder.Handler` module (this module).

  ## Examples

      defmodule InspectHandler do
        @behaviour FluentdForwarder.Handler

        def init(opts) do
          opts
        end

        def call(tag, time, record, _opts) do
          IO.inspect({tag, time, record})
        end
      end
  """

  @behaviour :ranch_protocol

  @type tag :: String.t()
  @type time :: float
  @type record :: map
  @type opts ::
          binary
          | tuple
          | atom
          | integer
          | float
          | [opts]
          | %{optional(opts) => opts}
          | MapSet.t()

  @callback init(opts) :: opts
  @callback call(tag, time, record, opts) :: any

  use GenServer
  use Bitwise

  require Logger

  defstruct [:ref, :socket, :transport, :handler, :handler_opts, :timeout, pending: ""]

  @impl :ranch_protocol
  def start_link(ref, transport, opts) do
    GenServer.start_link(__MODULE__, {ref, transport, opts})
  end

  @impl GenServer
  def init({ref, transport, opts}) do
    Process.flag(:trap_exit, true)
    {handler, handler_opts} = Map.fetch!(opts, :handler)
    timeout = Map.fetch!(opts, :timeout)

    state = %__MODULE__{
      ref: ref,
      transport: transport,
      handler: handler,
      handler_opts: handler.init(handler_opts),
      timeout: timeout
    }

    {:ok, state, {:continue, {:handshake, ref}}}
  end

  @impl GenServer
  def handle_continue({:handshake, ref}, %{transport: transport} = state) do
    {:ok, socket} = :ranch.handshake(ref)
    transport.setopts(socket, active: true)

    :telemetry.execute(
      [:fluentd, :forward, :connection, :start],
      %{system_time: :erlang.system_time()},
      %{transport: transport, socket: socket, ref: ref}
    )

    {:noreply, %{state | socket: socket}}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.debug("Timed out receiving messages, connection closed")
    {:stop, :normal, state}
  end

  def handle_info(
        {:tcp, socket, data},
        %{pending: pending, socket: socket, timeout: timeout} = state
      ),
      do: {:noreply, %{state | pending: drain_chunks(pending <> data, state)}, timeout}

  def handle_info(
        {:tcp_closed, socket},
        %{transport: transport, socket: socket, ref: ref} = state
      ) do
    Logger.debug("Connection closed by peer")

    :telemetry.execute(
      [:fluentd, :forward, :connection, :stop],
      %{system_time: :erlang.system_time()},
      %{transport: transport, socket: socket, ref: ref}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(:normal, _state), do: :ok

  def terminate(reason, %{transport: transport, socket: socket, ref: ref}) do
    :telemetry.execute(
      [:fluentd, :forward, :event, :exception],
      %{system_time: :erlang.system_time()},
      %{transport: transport, socket: socket, ref: ref, reason: reason}
    )
  end

  defp drain_chunks("", _state), do: ""

  defp drain_chunks(data, %{transport: transport, socket: socket, ref: ref} = state) do
    case Msgpax.unpack_slice(data) do
      {:ok, msg, pending} ->
        :telemetry.execute(
          [:fluentd, :forward, :message, :received],
          %{system_time: :erlang.system_time()},
          %{transport: transport, socket: socket, ref: ref, tag: hd(msg)}
        )

        handle_msg(msg, state)
        drain_chunks(pending, state)

      {:error, _} ->
        data
    end
  end

  defp handle_msg([tag, entries], state) when is_list(entries),
    do: handle_msg([tag, entries, %{}], state)

  defp handle_msg([tag, entries, options], state) when is_list(entries) do
    for [time, record] <- entries do
      call_handler(tag, time, record, state)
    end

    maybe_send_ack(options, state)
  end

  defp handle_msg([tag, entries, %{"compressed" => "gzip"} = options], state),
    do: handle_msg([tag, :zlib.gunzip(entries), Map.delete(options, "compressed")], state)

  defp handle_msg([tag, entries], state) when is_binary(entries),
    do: handle_msg([tag, entries, %{}], state)

  defp handle_msg([_tag, "", options], state), do: maybe_send_ack(options, state)

  defp handle_msg([tag, entries, option], state) when is_binary(entries) do
    {[time, record], pending} = Msgpax.unpack_slice!(entries)
    call_handler(tag, time, record, state)
    handle_msg([tag, pending, option], state)
  end

  defp handle_msg([tag, time, record], state) when is_map(record),
    do: handle_msg([tag, time, record, %{}], state)

  defp handle_msg([tag, time, record, options], state) when is_map(record) do
    call_handler(tag, time, record, state)

    maybe_send_ack(options, state)
  end

  defp call_handler(tag, time, record, %{
         handler: handler,
         handler_opts: handler_opts,
         transport: transport,
         socket: socket,
         ref: ref
       }) do
    handler.call(tag, convert_time(time), record, handler_opts)

    :telemetry.execute(
      [:fluentd, :forward, :event, :handled],
      %{system_time: :erlang.system_time()},
      %{transport: transport, socket: socket, ref: ref}
    )
  end

  defp maybe_send_ack(%{"chunk" => chunk}, %{transport: transport, socket: socket}),
    do: transport.send(socket, Msgpax.pack!(%{"ack" => chunk}))

  defp maybe_send_ack(_options, _state), do: :ok

  defp convert_time(%{type: 0, data: <<seconds::size(32), nanoseconds::size(32)>>}),
    do: seconds + nanoseconds / 1_000_000_000

  defp convert_time(seconds) when is_integer(seconds), do: seconds + 0.0

  defp convert_time(_) do
    now = :erlang.system_time(:nanosecond)
    div(now, 1_000_000_000) + rem(now, 1_000_000_000) / 1_000_000_000
  end
end
