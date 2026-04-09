defmodule PaperTiger.Store.Accounts do
  @moduledoc """
  ETS-backed storage for Stripe Connect Account resources.

  Uses the shared store pattern via `use PaperTiger.Store`.

  ## Architecture

  - **ETS Table**: `:paper_tiger_accounts` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Isolation semantics

  Connect Accounts are **platform-level** objects — they are created on the
  platform account, not on a connected account. All reads and writes to
  this store happen with `connect_account = nil`, regardless of whether
  the caller is otherwise inside a Connect context.

  In practice this means the shared macro's default behavior is correct:
  code that creates, retrieves, or updates an Account never passes
  `Stripe-Account`, so `PaperTiger.Test.current_connect_account/0` returns
  `nil`, and the ETS key is `{namespace, nil, id}`. Other resources (like
  PaymentIntents) that ARE per-account isolated key on the organizer's
  account ID, but Account itself doesn't.

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, account} = PaperTiger.Store.Accounts.get("acct_123")

      # Serialized write
      account = %{id: "acct_123", object: "account", ...}
      {:ok, account} = PaperTiger.Store.Accounts.insert(account)
  """

  use PaperTiger.Store,
    table: :paper_tiger_accounts,
    resource: "account",
    prefix: "acct"
end
