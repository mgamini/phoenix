defmodule Phoenix.Endpoint.Adapter do
  # This module contains the logic used by most functions
  # in Phoenix.Endpoint as well the supervisor for starting
  # the adapters/handlers.
  @moduledoc false

  import Supervisor.Spec
  alias Phoenix.CodeReloader.ChangeDetector

  @doc """
  Starts the endpoint supervision tree.
  """
  def start_link(otp_app, mod) do
    conf = config(otp_app, mod)

    children =
      [worker(Phoenix.Config, [otp_app, mod, defaults(otp_app, mod)])] ++
      pubsub_children(mod, conf) ++
      [supervisor(Phoenix.Endpoint.Server, [otp_app, mod])] ++
      watcher_children(mod, conf) ++
      code_reloader_children(mod, conf) ++
      live_reload_children(mod, conf)

    Supervisor.start_link(children, strategy: :one_for_one, name: mod)
  end

  defp pubsub_children(mod, conf) do
    pub_conf = conf[:pubsub]

    if adapter = pub_conf[:adapter] do
      [supervisor(adapter, [mod.__pubsub_server__(), pub_conf])]
    else
      []
    end
  end

  defp watcher_children(_mod, conf) do
    if conf[:server] do
      Enum.map(conf[:watchers], fn {cmd, args} ->
        worker(Phoenix.Endpoint.Watcher, [root!(conf), cmd, args],
               id: {cmd, args}, restart: :transient)
      end)
    else
      []
    end
  end

  defp code_reloader_children(_, conf) do
    if conf[:code_reloader] do
      [worker(Phoenix.CodeReloader.Server,
              [conf[:otp_app], root!(conf), conf[:reloadable_paths]])]
    else
      []
    end
  end

  defp root!(conf) do
    conf[:root] ||
      raise "please set root: Path.expand(\"..\", __DIR__) in your endpoint " <>
            "inside config/config.exs in order to use code reloading or watchers"
  end

  defp live_reload_children(mod, conf) do
    case Keyword.get(conf[:live_reload], :paths, []) do
      []    -> []
      paths -> [worker(ChangeDetector, [paths, {__MODULE__, :assets_change, [mod]}])]
    end
  end

  def assets_change(endpoint) do
    endpoint.broadcast!("phoenix", "assets:change", %{})
  end

  @doc """
  The endpoint configuration used at compile time.
  """
  def config(otp_app, endpoint) do
    Phoenix.Config.from_env(otp_app, endpoint, defaults(otp_app, endpoint))
  end

  defp defaults(otp_app, module) do
    [otp_app: otp_app,

     # Compile-time config
     code_reloader: false,
     debug_errors: false,
     render_errors: [view: render_errors(module), format: "html"],

     # Transports
     transports: [
       longpoller_window_ms: 10_000,
       longpoller_pubsub_timeout_ms: 1000,
       longpoller_crypto: [iterations: 1000,
                           length: 32,
                           digest: :sha256,
                           cache: Plug.Keys],

       websocket_serializer: Phoenix.Transports.JSONSerializer,
       websocket_timeout: :infinity
     ],

     # Runtime config
     cache_static_lookup: false,
     http: false,
     https: false,
     reloadable_paths: ["web"],
     secret_key_base: nil,
     server: Application.get_env(:phoenix, :serve_endpoints, false),
     url: [host: "localhost", path: "/"],

     # Supervisor config
     pubsub: [],
     watchers: [],
     live_reload: [paths: []]]
  end

  defp render_errors(module) do
    module
    |> Module.split
    |> Enum.at(0)
    |> Module.concat("ErrorView")
  end

  @doc """
  Builds the endpoint url from its configuration.

  The result is wrapped in a `{:cache, value}` tuple so
  the Phoenix.Config layer knows how to cache it.
  """
  def url(endpoint) do
    {scheme, port} =
      cond do
        config = endpoint.config(:https) ->
          {"https", config[:port]}
        config = endpoint.config(:http) ->
          {"http", config[:port]}
        true ->
          {"http", "80"}
      end

    url    = endpoint.config(:url)
    scheme = url[:scheme] || scheme
    host   = url[:host]
    port   = port_to_string(url[:port] || port)

    {:cache,
      case {scheme, port} do
        {"https", "443"} -> "https://" <> host
        {"http", "80"}   -> "http://" <> host
        {_, _}           -> scheme <> "://" <> host <> ":" <> port
      end}
  end

  @doc """
  Returns the static path of a file in the static root directory.

  When the file exists, it includes a timestamp. When it doesn't exist,
  just the static path is returned.

  The result is wrapped in a `{:cache | :stale, value}` tuple so
  the Phoenix.Config layer knows how to cache it.
  """
  def static_path(endpoint, "/" <> _ = path) do
    file = Application.app_dir(endpoint.config(:otp_app), Path.join("priv/static", path))

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
        key = if endpoint.config(:cache_static_lookup), do: :cache, else: :stale
        vsn = {size, mtime} |> :erlang.phash2() |> Integer.to_string(16)
        {key, endpoint.path(path <> "?vsn=" <> vsn)}
      _ ->
        {:stale, endpoint.path(path)}
    end
  end

  def static_path(_endpoint, path) when is_binary(path) do
    raise ArgumentError, "static_path/2 expects a path starting with / as argument"
  end

  defp port_to_string({:system, env_var}), do: System.get_env(env_var)
  defp port_to_string(port) when is_binary(port), do: port
  defp port_to_string(port) when is_integer(port), do: Integer.to_string(port)
end
