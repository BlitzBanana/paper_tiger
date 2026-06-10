defmodule PaperTiger.Store.Requests do
  @moduledoc """
  ETS-backed store for captured inbound API requests during tests.

  The request spy supports end-to-end assertions on what was sent to
  PaperTiger, including method, path, parsed params, and selected headers.
  """

  use PaperTiger.Store,
    table: :paper_tiger_requests,
    resource: "request",
    prefix: "req",
    plural: "requests",
    url_path: "/_test/requests"

  @type filter :: [
          method: String.t() | atom() | nil,
          path: String.t() | nil,
          idempotency_key: String.t() | nil,
          params: map() | nil
        ]

  @doc """
  Records an inbound request for later inspection.
  """
  @spec record(Plug.Conn.t()) :: map()
  def record(conn) do
    namespace = PaperTiger.Connect.storage_namespace()

    request = %{
      body_params: normalize_payload(conn.body_params),
      created: PaperTiger.Clock.now(),
      headers: normalize_headers(conn.req_headers),
      id: PaperTiger.Resource.generate_id("req"),
      idempotency_key: List.first(Plug.Conn.get_req_header(conn, "idempotency-key")),
      method: conn.method,
      namespace: namespace,
      params: normalize_payload(conn.params),
      path: request_path(conn),
      query: conn.query_string,
      query_params: normalize_payload(conn.query_params),
      sequence: :erlang.unique_integer([:monotonic, :positive]),
      status: conn.status
    }

    insert(request)
    trim_request_log(namespace)
    request
  end

  @doc """
  Returns all captured requests for the current namespace.
  """
  @spec list_all() :: [map()]
  def list_all do
    @table
    |> :ets.match_object({{PaperTiger.Connect.storage_namespace(), :_}, :_})
    |> Enum.map(fn {_key, request} -> request end)
    |> Enum.sort_by(&{&1.created, &1.sequence}, :desc)
  end

  @doc """
  Returns captured requests filtered by method/path and optional param match.
  """
  @spec filter(keyword()) :: [map()]
  def filter(filters) when is_list(filters) do
    method = normalize_method(Keyword.get(filters, :method))
    path_filter = Keyword.get(filters, :path)
    idempotency_key = Keyword.get(filters, :idempotency_key)
    params_filter = Keyword.get(filters, :params, %{})

    list_all()
    |> Enum.filter(fn request ->
      method_match?(request, method) and
        path_match?(request, path_filter) and
        idempotency_match?(request, idempotency_key) and
        params_match?(request, params_filter)
    end)
  end

  @spec normalize_method(String.t() | atom() | nil) :: String.t() | nil
  defp normalize_method(nil), do: nil
  defp normalize_method(method) when is_atom(method), do: method |> Atom.to_string() |> String.upcase()
  defp normalize_method(method), do: String.upcase(method)

  defp method_match?(_request, nil), do: true

  defp method_match?(%{method: request_method}, request_method), do: true

  defp method_match?(%{method: request_method}, method) do
    normalize_method(request_method) == method
  end

  defp request_path(%{request_path: request_path}) do
    request_path
  end

  defp path_match?(_request, nil), do: true

  defp path_match?(%{path: request_path}, path_filter) do
    if String.ends_with?(path_filter, "*") do
      String.starts_with?(request_path, String.trim_trailing(path_filter, "*"))
    else
      request_path == path_filter
    end
  end

  defp idempotency_match?(_request, nil), do: true
  defp idempotency_match?(%{idempotency_key: nil}, _expected), do: false
  defp idempotency_match?(%{idempotency_key: existing}, expected), do: existing == expected

  defp params_match?(_request, nil), do: true
  defp params_match?(_request, %{} = expected) when expected == %{}, do: true

  defp params_match?(%{params: request_params}, expected) do
    expected = normalize_payload(expected)
    payload_match?(request_params, expected)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.downcase(key), sanitize_header(key, value)}
    end)
  end

  defp normalize_headers(_other), do: []

  defp sanitize_header("authorization", _value), do: "[redacted]"
  defp sanitize_header(_key, value), do: value

  defp normalize_payload(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {normalize_payload_key(k), normalize_payload(v)} end)
  end

  defp normalize_payload(value) when is_list(value) do
    Enum.map(value, &normalize_payload/1)
  end

  defp normalize_payload(value), do: value

  defp normalize_payload_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_payload_key(key), do: key

  defp payload_match?(actual, expected) when is_map(actual) and is_map(expected) do
    Enum.all?(expected, fn {key, value} ->
      payload_match?(Map.get(actual, key), value)
    end)
  end

  defp payload_match?(actual, expected) when is_list(actual) and is_list(expected) do
    Enum.all?(Enum.with_index(expected), fn {expected_value, index} ->
      payload_match?(Enum.at(actual, index), expected_value)
    end)
  end

  defp payload_match?(actual, expected), do: actual == expected

  defp trim_request_log(namespace) do
    max_entries = Application.get_env(:paper_tiger, :request_log_max_entries, 500)

    if is_integer(max_entries) and max_entries > 0 do
      namespace_requests(namespace)
      |> Enum.sort_by(& &1.sequence, :desc)
      |> Enum.drop(max_entries)
      |> Enum.each(&delete(namespace, &1))
    end
  end

  defp namespace_requests(namespace) do
    :ets.match_object(@table, {{namespace, :_}, :_})
    |> Enum.map(fn {_key, request} -> request end)
  end

  defp delete(namespace, %{id: id}), do: :ets.delete(@table, {namespace, id})
end
