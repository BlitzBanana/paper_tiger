defmodule PaperTiger.Resources.Account do
  @moduledoc """
  Handles Stripe Connect Account resource endpoints.

  ## Endpoints

  - POST /v1/accounts         - Create connected account
  - GET  /v1/accounts/:id     - Retrieve connected account
  - POST /v1/accounts/:id     - Update connected account (e.g. request additional capabilities)

  ## Account Object

      %{
        id: "acct_...",
        object: "account",
        type: "express" | "standard" | "custom",
        country: "FR",
        email: "...",
        details_submitted: false,
        charges_enabled: false,
        payouts_enabled: false,
        capabilities: %{
          card_payments: "inactive",
          transfers: "inactive"
        },
        business_type: nil,
        created: 1234567890,
        metadata: %{}
      }

  ## Behavior parity with real Stripe

  - Newly created accounts start with `details_submitted: false`,
    `charges_enabled: false`, `payouts_enabled: false`, and all requested
    capabilities in `"inactive"` state. In real Stripe these flip to
    `"active"` after the account owner completes the KYC / Onboarding
    flow. In PaperTiger, tests can flip them directly via
    `POST /v1/accounts/:id` with `details_submitted: true`,
    `charges_enabled: true`, `payouts_enabled: true` — this mimics what
    the real `account.updated` webhook reflects after verification.

  - Requested capabilities are mirrored into the `capabilities` map as
    `"inactive"` on create. An update can flip them to `"active"`.

  - No AccountLink object is modeled here — see
    `PaperTiger.Resources.AccountLink`.

  ## Isolation

  Accounts themselves live at the platform level (never behind a
  `Stripe-Account` header). The shared store macro handles this
  automatically: a request to `POST /v1/accounts` without a
  `Stripe-Account` header has `current_connect_account = nil`, and the
  account is stored with key `{namespace, nil, account_id}`.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Accounts

  @doc """
  Creates a new Connect account.

  ## Parameters

  - `type` - Account type: "express" (default), "standard", or "custom"
  - `country` - Two-letter country code (defaults to "US" — tests for
    French organizers should pass "FR" explicitly)
  - `email` - Account owner's email
  - `capabilities` - Map of requested capabilities, e.g.
    `%{card_payments: %{requested: true}, transfers: %{requested: true}}`
  - `business_type` - "individual" or "company"
  - `metadata` - Key-value metadata
  - `id` - Custom ID (must start with "acct_"); useful for deterministic test data
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    account = build_account(conn.params)

    {:ok, account} = Accounts.insert(account)
    maybe_store_idempotency(conn, account)

    :telemetry.execute([:paper_tiger, :account, :created], %{}, %{object: account})

    json_response(conn, 200, account)
  end

  @doc """
  Retrieves a Connect account by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Accounts.get(id) do
      {:ok, account} ->
        json_response(conn, 200, account)

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("account", id))
    end
  end

  @doc """
  Updates a Connect account.

  ## Updatable Fields

  - `email`
  - `metadata`
  - `business_type`
  - `capabilities` (either Stripe-style `%{card_payments: %{requested: true}}`
    requests, which are normalized to `"inactive"`, or direct status strings
    like `%{card_payments: "active"}` for test orchestration)
  - `charges_enabled`, `payouts_enabled`, `details_submitted` — test-only
    shortcuts for simulating verification state changes. Real Stripe does
    not let you set these directly; in PaperTiger they exist so tests can
    mimic the state transitions that happen post-KYC without going through
    a full onboarding flow.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Accounts.get(id),
         updated = apply_updates(existing, conn.params),
         {:ok, updated} <- Accounts.update(updated) do
      :telemetry.execute([:paper_tiger, :account, :updated], %{}, %{
        object: updated,
        previous_attributes: existing
      })

      json_response(conn, 200, updated)
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("account", id))
    end
  end

  ## Private Functions

  defp build_account(params) do
    created = get_optional_integer(params, :created) || PaperTiger.now()
    capabilities = normalize_capabilities(Map.get(params, :capabilities, %{}))

    %{
      id: generate_id("acct", Map.get(params, :id)),
      object: "account",
      type: Map.get(params, :type, "express"),
      country: Map.get(params, :country, "US"),
      email: Map.get(params, :email),
      business_type: Map.get(params, :business_type),
      capabilities: capabilities,
      charges_enabled: false,
      payouts_enabled: false,
      details_submitted: false,
      created: created,
      metadata: Map.get(params, :metadata, %{}),
      livemode: false,
      default_currency: Map.get(params, :default_currency, "usd"),
      requirements: %{
        currently_due: [],
        disabled_reason: nil,
        eventually_due: [],
        past_due: [],
        pending_verification: []
      }
    }
  end

  # Stripe's create params use `%{card_payments: %{requested: true}}`. The
  # account object returns `%{card_payments: "inactive" | "pending" | "active"}`.
  # This helper normalizes the input shape into the output shape, defaulting
  # newly-requested capabilities to "inactive".
  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    Map.new(capabilities, fn
      {key, %{requested: true}} -> {key, "inactive"}
      {key, %{"requested" => true}} -> {key, "inactive"}
      {key, value} when is_binary(value) -> {key, value}
      {key, _other} -> {key, "inactive"}
    end)
  end

  defp normalize_capabilities(_), do: %{}

  # Merge the update params into the existing account. Capabilities updates
  # overlay on top of the existing capabilities map rather than replacing it,
  # matching Stripe's behavior.
  defp apply_updates(existing, params) do
    updates =
      params
      |> Map.take([
        :email,
        :metadata,
        :business_type,
        :default_currency,
        :charges_enabled,
        :payouts_enabled,
        :details_submitted
      ])
      |> maybe_merge_capabilities(existing, params)

    merge_updates(existing, updates)
  end

  defp maybe_merge_capabilities(updates, existing, params) do
    case Map.get(params, :capabilities) do
      nil ->
        updates

      new_caps when is_map(new_caps) ->
        merged =
          existing.capabilities
          |> Map.merge(normalize_capabilities(new_caps))

        Map.put(updates, :capabilities, merged)
    end
  end
end
