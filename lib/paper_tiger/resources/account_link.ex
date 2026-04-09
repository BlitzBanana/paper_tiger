defmodule PaperTiger.Resources.AccountLink do
  @moduledoc """
  Handles Stripe Connect AccountLink resource endpoints.

  ## Endpoints

  - POST /v1/account_links - Create an AccountLink

  ## AccountLink Object

      %{
        object: "account_link",
        created: 1234567890,
        expires_at: 1234571490,
        url: "https://paper-tiger.local/connect/onboarding/acct_..."
      }

  ## Behavior

  Stripe's `/v1/account_links` creates a one-time URL that the account
  holder visits to complete their Stripe Connect onboarding. In
  PaperTiger this is stateless — we return a dummy URL that includes
  the target account ID so tests can assert that the right link was
  generated.

  Tests that want to simulate "account holder completed onboarding"
  should skip the URL entirely and POST an update directly to
  `/v1/accounts/:id` flipping `charges_enabled: true`,
  `payouts_enabled: true`, `details_submitted: true`. See
  `PaperTiger.Resources.Account` for details.

  ## Isolation

  AccountLinks are platform-level — they are created by the platform on
  behalf of a connected account but do not themselves live "inside" the
  connected account's data. No state is stored, so isolation is moot.
  """

  import PaperTiger.Resource

  @doc """
  Creates a new AccountLink.

  ## Required Parameters

  - `account` - The connected account ID
  - `refresh_url` - URL the user is sent to if the link is expired
  - `return_url` - URL the user is sent to after completing onboarding
  - `type` - Either "account_onboarding" or "account_update"

  Returns a 400 error if `account` is missing.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    case Map.get(conn.params, :account) do
      account_id when is_binary(account_id) and account_id != "" ->
        now = PaperTiger.now()

        link = %{
          object: "account_link",
          created: now,
          # Real Stripe AccountLinks expire after a few minutes. 1 hour is
          # a convenient stub.
          expires_at: now + 3600,
          url: "https://paper-tiger.local/connect/onboarding/#{account_id}"
        }

        :telemetry.execute([:paper_tiger, :account_link, :created], %{}, %{object: link})

        json_response(conn, 200, link)

      _ ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required param: account.", "account")
        )
    end
  end
end
