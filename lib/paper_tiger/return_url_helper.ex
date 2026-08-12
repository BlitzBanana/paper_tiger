defmodule PaperTiger.ReturnUrlHelper do
  @moduledoc """
  Shared `return_url` validation for PaymentIntent and SetupIntent confirmation.

  Stripe refuses to confirm an intent whose enabled payment methods include
  redirect-based ones (boleto, iDEAL, ...) unless the caller supplied a
  `return_url` to send the customer back to. Accepting that confirmation would
  let an integration ship a call that cannot succeed against the real API, with
  a green suite the whole way.

  ## What is and is not decided here

  Only the case that is decidable from the request: `automatic_payment_methods`
  present with `enabled` truthy and `allow_redirects` not `"never"`. Stripe
  defaults `allow_redirects` to `"always"`, so an enabled block that omits it
  requires the URL.

  When `automatic_payment_methods` is absent entirely, Stripe falls back to the
  payment methods enabled in the account's dashboard — state PaperTiger does not
  model — so that case is deliberately allowed through rather than guessed at.
  """

  @doc """
  Returns `:ok`, or `{:error, :return_url_required}` when redirects are allowed
  and neither the stored intent nor the confirm params carry a `return_url`.

  `intent` is the stored object; `params` are the confirm request's params, since
  Stripe accepts `return_url` at either create or confirm time.
  """
  @spec validate(map(), map()) :: :ok | {:error, :return_url_required}
  def validate(intent, params) do
    if redirects_allowed?(param(intent, :automatic_payment_methods)) and
         is_nil(return_url(intent, params)) do
      {:error, :return_url_required}
    else
      :ok
    end
  end

  @doc """
  The operator-facing message. Stripe's own message names the specific resource,
  so the caller passes `"PaymentIntent"` or `"SetupIntent"`.
  """
  @spec error_message(String.t()) :: String.t()
  def error_message(resource) do
    "This #{resource} is configured to accept redirect-based " <>
      "payment methods, so a return_url must be supplied. Pass return_url, or set " <>
      "automatic_payment_methods[allow_redirects]=never."
  end

  defp redirects_allowed?(nil), do: false

  defp redirects_allowed?(automatic_payment_methods) when is_map(automatic_payment_methods) do
    enabled?(param(automatic_payment_methods, :enabled)) and
      param(automatic_payment_methods, :allow_redirects) not in ["never", :never]
  end

  defp redirects_allowed?(_other), do: false

  # Form-encoded bodies arrive as strings, JSON bodies as booleans.
  defp enabled?(true), do: true
  defp enabled?("true"), do: true
  defp enabled?(_other), do: false

  defp return_url(intent, params) do
    presence(param(params, :return_url)) || presence(param(intent, :return_url))
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp param(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp param(_map, _key), do: nil
end
