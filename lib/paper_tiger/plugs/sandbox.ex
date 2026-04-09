defmodule PaperTiger.Plugs.Sandbox do
  @moduledoc """
  Plug that extracts test namespace and Stripe Connect account from HTTP
  headers for sandbox isolation.

  Two headers are inspected:

  - `x-paper-tiger-namespace` — the test-process PID, used to isolate
    concurrent tests from one another.
  - `Stripe-Account` — the Stripe Connect account ID, used to isolate
    Direct Charges per connected account within a single test. Sent
    automatically by `stripity_stripe` when the caller passes the
    `connect_account:` option.

  Both values are written into the process dictionary so that all store
  operations in this request scope data to `{namespace, connect_account}`.
  Either can be absent: no `x-paper-tiger-namespace` → `:global` namespace;
  no `Stripe-Account` → platform-level (`nil`) account context.

  ## How It Works

  1. Client sends `x-paper-tiger-namespace` header with the test PID as a string
  2. Client optionally sends `Stripe-Account` header for Connect requests
  3. This plug parses both and sets them in the process dictionary
  4. All subsequent store operations in this request use the composite key
  5. Data is isolated both between concurrent tests and between connected accounts
  """

  import Plug.Conn

  @namespace_header "x-paper-tiger-namespace"
  @stripe_account_header "stripe-account"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_namespace_from_header()
    |> put_connect_account_from_header()
  end

  defp put_namespace_from_header(conn) do
    case get_req_header(conn, @namespace_header) do
      [namespace_string | _] ->
        # Parse the namespace (could be a PID string like "#PID<0.123.0>")
        namespace = parse_namespace(namespace_string)
        Process.put(:paper_tiger_namespace, namespace)
        conn

      [] ->
        # No namespace header - use :global (default behavior)
        conn
    end
  end

  defp put_connect_account_from_header(conn) do
    # Plug lowercases header names before matching, so the lookup is
    # case-insensitive regardless of how stripity_stripe or the HTTP client
    # cased the outgoing header.
    case get_req_header(conn, @stripe_account_header) do
      [account_id | _] when is_binary(account_id) and account_id != "" ->
        PaperTiger.Test.put_connect_account(account_id)
        conn

      _ ->
        # No Connect account — ensure we don't inherit stale state from a
        # previous request handled on this same Bandit connection process.
        PaperTiger.Test.put_connect_account(nil)
        conn
    end
  end

  defp parse_namespace(string) do
    # Try to parse as a PID string first
    case parse_pid_string(string) do
      {:ok, pid} -> pid
      :error -> String.to_atom(string)
    end
  end

  # Parse PID string like "#PID<0.123.0>" or "0.123.0"
  defp parse_pid_string(string) do
    # Remove #PID< and > if present
    cleaned =
      string
      |> String.replace_prefix("#PID<", "")
      |> String.replace_suffix(">", "")

    case String.split(cleaned, ".") do
      [a, b, c] ->
        try do
          pid = :c.pid(String.to_integer(a), String.to_integer(b), String.to_integer(c))
          {:ok, pid}
        rescue
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
