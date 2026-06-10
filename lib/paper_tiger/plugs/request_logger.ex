defmodule PaperTiger.Plugs.RequestLogger do
  @moduledoc """
  Captures inbound API requests for test assertions.

  The logger runs in `register_before_send/2`, so it records requests that
  halt in upstream plugs and still returns the final connection unchanged.
  """

  @behaviour Plug

  import Plug.Conn

  alias PaperTiger.Store.Requests

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      if should_log?(conn) do
        Requests.record(conn)
      end

      conn
    end)
  end

  defp should_log?(%{request_path: request_path}) when is_binary(request_path) do
    should_log_path?(request_path) and sandbox_namespace?()
  end

  defp should_log?(_conn), do: false

  defp should_log_path?(request_path) when is_binary(request_path) do
    not String.starts_with?(request_path, "/_test")
  end

  defp should_log_path?(_), do: false

  defp sandbox_namespace? do
    PaperTiger.Test.current_namespace() != :global
  end
end
