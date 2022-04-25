defmodule FluentdForwarder do
  @moduledoc """
  A Fluentd forwarder server.

  ## Options

    * `:net` - If using `:inet` (IPv4 only - the default) or `:inet6` (IPv6)

    * `:ip` - the ip to bind the server to.
      Must be either a tuple in the format `{a, b, c, d}` with each value in `0..255` for IPv4,
      or a tuple in the format `{a, b, c, d, e, f, g, h}` with each value in `0..65535` for IPv6,
      or a tuple in the format `{:local, path}` for a unix socket at the given `path`.
      If you set an IPv6, the `:net` option will be automatically set to `:inet6`.
      If both `:net` and `:ip` options are given, make sure they are compatible
      (i.e. give a IPv4 for `:inet` and IPv6 for `:inet6`).
      Also, see "Loopback vs Public IP Addresses".

    * `:port` - the port to run the server.
      Defaults to 4000 (http) and 4040 (https).
      Must be 0 when `:ip` is a `{:local, path}` tuple.

    * `:handler` - the `FluentdForwarder.Handler` to use.

    * `:ref` - the reference name to be used.
      Defaults to `handler.TCP` (tcp) and `handler.TLS` (tls).
      Note, the default reference name does not contain the port so in order
      to serve the same plug on multiple ports you need to set the `:ref` accordingly,
      e.g.: `ref: MyHandler_TCP_24224`, `ref: MyHandler_TCP_24225`, etc.

    * `:protocol_options` - A keyword list specifying protocol options.
      By default `:timeout` will be set to `:infinity`.

    * `:transport_options` - A keyword list specifying transport options,
      see [Ranch docs](https://ninenines.eu/docs/en/ranch/1.7/manual/ranch/).
      By default `:num_acceptors` will be set to `100` and `:max_connections`
      to `16_384`.

  All other options given at the top level must configure the underlying
  socket. For TCP connections, those options are listed under
  [`ranch_tcp`](https://ninenines.eu/docs/en/ranch/1.7/manual/ranch_tcp/).
  For example, you can set `:ipv6_v6only` to true if you want to bind only
  on IPv6 addresses.

  For TLS connections, those options are described in
  [`ranch_ssl`](https://ninenines.eu/docs/en/ranch/1.7/manual/ranch_ssl/).

  ## Loopback vs Public IP Addresses

  Should your application bind to a loopback address, such as `::1` (IPv6) or
  `127.0.0.1` (IPv4), or a public one, such as `::0` (IPv6) or `0.0.0.0`
  (IPv4)? It depends on how (and whether) you want it to be reachable from
  other machines.

  Loopback addresses are only reachable from the same host (`localhost` is
  usually configured to resolve to a loopback address). You may wish to use one if:

  - Your app is running in a development environment (such as your laptop) and
  you don't want others on the same network to access it.
  - Your app is running in production, but behind a reverse proxy. For example,
  you might have Nginx bound to a public address and serving TLS, but
  forwarding the traffic to your application running on the same host. In that
  case, having your app bind to the loopback address means that Nginx can reach
  it, but outside traffic can only reach it via Nginx.

  Public addresses are reachable from other hosts. You may wish to use one if:

  - Your app is running in a container. In this case, its loopback address is
  reachable only from within the container; to be accessible from outside the
  container, it needs to bind to a public IP address.
  - Your app is running in production without a reverse proxy, using Ranch's
  TLS support.

  ## Instrumentation

  FluentdForwarder.Handler uses the `:telemetry` library for instrumentation. The following
  span events are published during each request:

    * `[:fluentd, :forward, :connection, :start]` - dispatched at the beginning of each connection
    * `[:fluentd, :forward, :connection, :stop]` - dispatched at the end of the connection
    * `[:fluentd, :forward, :message, :received]` - dispatched before successfully handling a message
    * `[:fluentd, :forward, :event, :handled]` - dispatched after successfully handling an event
    * `[:fluentd, :forward, :event, :exception]` - dispatched at the end of a message that exits

  """

  @type ref :: :ranch.ref()
  @type trans_opts :: :ranch.opts()
  @type proto_opts :: Keyword.t()

  @doc false
  def child_spec(opts) do
    transport = Keyword.fetch!(opts, :transport)

    {handler, handler_opts} =
      case Keyword.fetch!(opts, :handler) do
        {_, _} = tuple -> tuple
        plug -> {plug, []}
      end

    ranch_opts = Keyword.drop(opts, [:transport, :handler])

    ranch_args = args(transport, handler, handler_opts, ranch_opts)
    [ref, transport_opts, proto_opts] = ranch_args

    {ranch_module, transport_opts} =
      case transport do
        :tcp ->
          {:ranch_tcp, transport_opts}

        :tls ->
          %{socket_opts: socket_opts} = transport_opts

          socket_opts =
            socket_opts
            |> Keyword.put_new(:next_protocols_advertised, ["h2", "http/1.1"])
            |> Keyword.put_new(:alpn_preferred_protocols, ["h2", "http/1.1"])

          {:ranch_ssl, %{transport_opts | socket_opts: socket_opts}}
      end

    :ranch.child_spec(ref, ranch_module, transport_opts, FluentdForwarder.Handler, proto_opts)
  end

  @doc false
  def args(transport, handler, handler_opts, ranch_options) do
    {ranch_options, non_keyword_options} = Enum.split_with(ranch_options, &match?({_, _}, &1))

    ranch_options
    |> normalize_ranch_options(transport)
    |> to_args(transport, handler, handler_opts, non_keyword_options)
  end

  defp normalize_ranch_options(ranch_options, _) do
    Keyword.put_new(ranch_options, :port, 24224)
  end

  defp to_args(opts, transport, handler, handler_opts, non_keyword_opts) do
    opts = Keyword.delete(opts, :otp_app)
    {ref, opts} = Keyword.pop(opts, :ref)
    {protocol_options, opts} = Keyword.pop(opts, :protocol_options, [])

    protocol_options =
      Map.merge(%{handler: {handler, handler_opts}, timeout: :infinity}, Map.new(protocol_options))

    {transport_options, socket_options} = Keyword.pop(opts, :transport_options, [])

    {net, socket_options} = Keyword.pop(socket_options, :net)
    socket_options = List.wrap(net) ++ non_keyword_opts ++ socket_options

    transport_options =
      transport_options
      |> Keyword.put_new(:num_acceptors, 100)
      |> Keyword.put_new(:max_connections, 16_384)
      |> Keyword.update(
        :socket_opts,
        socket_options,
        &(&1 ++ socket_options)
      )
      |> Map.new()

    [ref || build_ref(handler, transport), transport_options, protocol_options]
  end

  defp build_ref(handler, transport) do
    Module.concat(handler, transport |> to_string |> String.upcase())
  end
end
