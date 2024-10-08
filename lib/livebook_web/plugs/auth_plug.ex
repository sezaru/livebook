defmodule LivebookWeb.AuthPlug do
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  use LivebookWeb, :verified_routes

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Logger.info("AuthPlug call")
    if authenticated?(conn) do
      conn
    else
      authenticate(conn)
    end
  end

  @doc """
  Stores in the session the secret for the given mode.
  """
  @spec store(Plug.Conn.t(), Livebook.Config.authentication_mode(), String.t()) :: Plug.Conn.t()
  def store(conn, mode, value) do
    conn
    |> put_session(key(conn.port, mode), hash(value))
    |> configure_session(renew: true)
  end

  @doc """
  Checks if given connection is already authenticated.
  """
  @spec authenticated?(Plug.Conn.t()) :: boolean()
  def authenticated?(conn) do
    Logger.info("AuthPlug authenticated?")
    authenticated?(get_session(conn), conn.port)
  end

  @doc """
  Checks if the given session is authenticated.
  """
  @spec authenticated?(map(), non_neg_integer()) :: boolean()
  def authenticated?(session, port) do
    Logger.info("AuthPlug authenticated?/2")
    case authentication(session) do
      %{mode: :disabled} ->
        true

      %{mode: mode, secret: secret} when mode in [:token, :password] ->
        secret_hash = session[key(port, mode)]
        is_binary(secret_hash) and matches_secret?(secret_hash, secret)
    end
  end

  defp authenticate(conn) do
    Logger.info("AuthPlug authenticate")
    case authentication(conn) do
      %{mode: :password} ->
        Logger.info("AuthPlug authenticate: password")
        redirect_to_authenticate(conn)

      %{mode: :token, secret: secret} ->
        Logger.info("AuthPlug authenticate: token")
        {token, query_params} = Map.pop(conn.query_params, "token")

        if is_binary(token) and matches_secret?(hash(token), secret) do
          Logger.info("AuthPlug authenticate: if 1")
          # Redirect to the same path without query params
          conn
          |> store(:token, token)
          |> redirect(to: path_with_query(conn.request_path, query_params))
          |> halt()
        else
          Logger.info("AuthPlug authenticate: if 2")
          redirect_to_authenticate(conn)
        end
    end
  end

  defp matches_secret?(hash, secret) do
    Plug.Crypto.secure_compare(hash, hash(secret))
  end

  defp redirect_to_authenticate(%{path_info: []} = conn) do
    path =
      if Livebook.Apps.list_apps() != [] or Livebook.Config.apps_path() != nil or
           Livebook.Config.teams_auth?() do
        ~p"/apps"
      else
        ~p"/authenticate"
      end

    conn
    |> redirect(to: path)
    |> halt()
  end

  defp redirect_to_authenticate(conn) do
    conn
    |> then(fn
      %{method: "GET"} -> put_session(conn, :redirect_to, current_path(conn))
      conn -> conn
    end)
    |> redirect(to: ~p"/authenticate")
    |> halt()
  end

  defp path_with_query(path, params) when params == %{}, do: path
  defp path_with_query(path, params), do: path <> "?" <> URI.encode_query(params)

  defp key(port, mode), do: "#{port}:#{mode}"
  defp hash(value), do: :crypto.hash(:sha256, value)

  @doc """
  Returns the authentication configuration for the given `conn` or
  `session`.

  This mirrors `Livebook.Config.authentication/0`, except the it can
  be overridden in tests, for each connection.
  """
  if Mix.env() == :test do
    def authentication(%Plug.Conn{} = conn), do: authentication(get_session(conn))

    def authentication(%{} = session) do
      session["authentication_test_override"] || Livebook.Config.authentication()
    end
  else
    def authentication(_), do: Livebook.Config.authentication()
  end
end
