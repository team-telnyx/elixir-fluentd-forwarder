# Fluentd Forwarder

`FluentdForwarder` is a server that implements the [Fluentd Forward Protocol Specification v1](https://github.com/fluent/fluentd/wiki/Forward-Protocol-Specification-v1).

## Installation

In order to use `FluentdForwarder`, add `fluentd_forwarder` as a dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:fluentd_forwarder, "~> 0.1"}
  ]
end
```
## Hello world

```elixir
defmodule InspectHandler do
  @behaviour FluentdForwarder.Handler
                                        
  def init(opts) do
    opts
  end
                                        
  def call(tag, time, record, _opts) do
    IO.inspect({tag, time, record})
  end
end
```

Then in your supervision tree, do:

```elixir
defmodule MyApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {FluentdForwarder, transport: :tcp, handler: InspectHandler}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

And you're ready to inspect logs from Docker.

On Linux, try with:

```
docker run --log-driver=fluentd --log-opt fluentd-address=localhost:24224 -ti elixir
```

On Mac, try with:

```
docker run --log-driver=fluentd --log-opt fluentd-address=docker.for.mac.localhost:24224 -ti elixir
```

and every output emitted by the container will be sent to your Elixir app.

## Contributing

We welcome everyone to contribute to `FluentdForwarder` and help us tackle existing issues!

Use the [issue tracker][issues] for bug reports or feature requests. Open a [pull request][pulls] when you are ready to contribute.

## License

Plug source code is released under Apache License 2.0.
Check `LICENSE` file for more information.
