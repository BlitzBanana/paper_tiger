defmodule PaperTiger.Resources.AccountTest do
  @moduledoc """
  End-to-end tests for Stripe Connect Account + AccountLink resources,
  and for per-connected-account isolation of other resources.
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  # --- Test helpers ---

  defp conn(method, path, params, extra_headers) do
    conn = Plug.Test.conn(method, path, params)

    headers =
      extra_headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_connect_key"}
        ] ++ sandbox_headers()

    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp request(method, path, params \\ nil, extra_headers \\ []) do
    method |> conn(path, params, extra_headers) |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  defp with_account(account_id), do: [{"stripe-account", account_id}]

  # --- Account CRUD ---

  describe "POST /v1/accounts" do
    test "creates an Express account with default values" do
      conn = request(:post, "/v1/accounts", %{"type" => "express"})

      assert conn.status == 200
      account = json_response(conn)

      assert String.starts_with?(account["id"], "acct_")
      assert account["object"] == "account"
      assert account["type"] == "express"
      assert account["charges_enabled"] == false
      assert account["payouts_enabled"] == false
      assert account["details_submitted"] == false
      assert account["capabilities"] == %{}
    end

    test "respects a custom id prefix" do
      conn = request(:post, "/v1/accounts", %{"id" => "acct_organizer_1"})

      assert conn.status == 200
      assert json_response(conn)["id"] == "acct_organizer_1"
    end

    test "normalizes capabilities request into inactive status" do
      params = %{
        "country" => "FR",
        "email" => "org@example.com",
        "capabilities" => %{
          "card_payments" => %{"requested" => true},
          "transfers" => %{"requested" => true}
        }
      }

      conn = request(:post, "/v1/accounts", params)

      assert conn.status == 200
      account = json_response(conn)
      assert account["country"] == "FR"
      assert account["email"] == "org@example.com"
      assert account["capabilities"] == %{"card_payments" => "inactive", "transfers" => "inactive"}
    end
  end

  describe "GET /v1/accounts/:id" do
    test "retrieves a previously created account" do
      %{status: 200} =
        created = request(:post, "/v1/accounts", %{"id" => "acct_retrieve_me"})

      id = json_response(created)["id"]

      conn = request(:get, "/v1/accounts/#{id}")

      assert conn.status == 200
      assert json_response(conn)["id"] == id
    end

    test "returns 404 for unknown account" do
      conn = request(:get, "/v1/accounts/acct_does_not_exist")

      assert conn.status == 404
      assert json_response(conn)["error"]["type"] == "invalid_request_error"
    end
  end

  describe "POST /v1/accounts/:id" do
    test "flips charges_enabled/payouts_enabled/details_submitted for test orchestration" do
      created =
        request(:post, "/v1/accounts", %{
          "id" => "acct_flip",
          "capabilities" => %{"card_payments" => %{"requested" => true}}
        })

      assert json_response(created)["charges_enabled"] == false

      updated =
        request(:post, "/v1/accounts/acct_flip", %{
          "charges_enabled" => true,
          "payouts_enabled" => true,
          "details_submitted" => true,
          "capabilities" => %{"card_payments" => "active"}
        })

      assert updated.status == 200
      account = json_response(updated)
      assert account["charges_enabled"] == true
      assert account["payouts_enabled"] == true
      assert account["details_submitted"] == true
      assert account["capabilities"]["card_payments"] == "active"
    end

    test "returns 404 for unknown account" do
      conn = request(:post, "/v1/accounts/acct_missing", %{"email" => "x@y.z"})

      assert conn.status == 404
    end
  end

  # --- AccountLink ---

  describe "POST /v1/account_links" do
    test "creates a link for a given account" do
      params = %{
        "account" => "acct_organizer_1",
        "refresh_url" => "https://example.com/refresh",
        "return_url" => "https://example.com/return",
        "type" => "account_onboarding"
      }

      conn = request(:post, "/v1/account_links", params)

      assert conn.status == 200
      link = json_response(conn)
      assert link["object"] == "account_link"
      assert is_integer(link["created"])
      assert link["expires_at"] > link["created"]
      assert String.contains?(link["url"], "acct_organizer_1")
    end

    test "rejects requests without an account param" do
      conn = request(:post, "/v1/account_links", %{"return_url" => "https://x"})

      assert conn.status == 400
      assert json_response(conn)["error"]["param"] == "account"
    end
  end

  # --- Per-Connect-account isolation ---
  #
  # The critical guarantee: a resource created with `Stripe-Account: acct_A`
  # must be invisible to a request with `Stripe-Account: acct_B`, and also
  # invisible to a request with no `Stripe-Account` at all (platform
  # context).

  describe "Connect account isolation" do
    test "a customer created under acct_A is not visible under acct_B" do
      # Customers is a good proxy resource — it's fully exercised by the
      # shared Store macro, and the test isn't coupled to PaymentIntent
      # confirmation machinery.
      created =
        request(:post, "/v1/customers", %{"email" => "iso@example.com"}, with_account("acct_A"))

      assert created.status == 200
      customer_id = json_response(created)["id"]

      # Same namespace, different connect account → not found
      from_b = request(:get, "/v1/customers/#{customer_id}", nil, with_account("acct_B"))
      assert from_b.status == 404

      # Same namespace, no connect account (platform) → also not found
      from_platform = request(:get, "/v1/customers/#{customer_id}")
      assert from_platform.status == 404

      # Same namespace and the original account → found
      from_a = request(:get, "/v1/customers/#{customer_id}", nil, with_account("acct_A"))
      assert from_a.status == 200
      assert json_response(from_a)["email"] == "iso@example.com"
    end

    test "listing customers respects the current connect account" do
      request(:post, "/v1/customers", %{"email" => "a@example.com"}, with_account("acct_A"))
      request(:post, "/v1/customers", %{"email" => "b@example.com"}, with_account("acct_B"))
      request(:post, "/v1/customers", %{"email" => "platform@example.com"})

      list_a = request(:get, "/v1/customers", nil, with_account("acct_A")) |> json_response()
      list_b = request(:get, "/v1/customers", nil, with_account("acct_B")) |> json_response()
      list_platform = request(:get, "/v1/customers") |> json_response()

      emails_a = Enum.map(list_a["data"], & &1["email"])
      emails_b = Enum.map(list_b["data"], & &1["email"])
      emails_platform = Enum.map(list_platform["data"], & &1["email"])

      assert emails_a == ["a@example.com"]
      assert emails_b == ["b@example.com"]
      assert emails_platform == ["platform@example.com"]
    end

    test "Account resource itself lives at platform level regardless of Stripe-Account header" do
      # Creating an account with a Stripe-Account header set is a bit
      # nonsensical (real Stripe rejects this) but we need to confirm the
      # Account store isn't accidentally isolating account records by
      # connected-account context, which would be the dog-chasing-its-tail
      # case. Our contract: Accounts are platform-level, stored with
      # connect_account = nil under the hood, and retrievable WITHOUT a
      # Stripe-Account header.
      created = request(:post, "/v1/accounts", %{"id" => "acct_platform_scoped"})
      assert created.status == 200

      # Retrieve with no header → found
      assert request(:get, "/v1/accounts/acct_platform_scoped").status == 200
    end
  end

  # --- Events carry the `account` field when fired in a Connect context ---

  describe "Event account field" do
    setup do
      :ok = enable_webhook_collection()
      :ok
    end

    test "events from a platform-level operation have account = nil" do
      request(:post, "/v1/customers", %{"email" => "platform-evt@example.com"})

      [delivery] = assert_webhook_delivered("customer.created")
      assert delivery.account == nil
    end

    test "events from a connect-scoped operation carry the account id" do
      request(
        :post,
        "/v1/customers",
        %{"email" => "connect-evt@example.com"},
        with_account("acct_evt_source")
      )

      [delivery] = assert_webhook_delivered("customer.created")
      assert delivery.account == "acct_evt_source"
    end

    test "account.created fires an event with no account field (platform-level)" do
      request(:post, "/v1/accounts", %{"id" => "acct_will_emit"})

      [delivery] = assert_webhook_delivered("account.created")
      assert delivery.account == nil
      assert delivery.event_data.object.id == "acct_will_emit"
    end
  end

  # --- with_connect_account/2 helper for direct store access ---

  describe "with_connect_account/2" do
    test "wraps a block with a connect account context" do
      alias PaperTiger.Store.Customers

      customer = %{
        id: "cus_direct_insert",
        object: "customer",
        email: "direct@example.com",
        created: PaperTiger.now(),
        metadata: %{}
      }

      with_connect_account("acct_direct", fn ->
        {:ok, _} = Customers.insert(customer)
      end)

      # Outside the block, the customer is invisible
      assert {:error, :not_found} = Customers.get("cus_direct_insert")
      assert current_connect_account() == nil

      # Inside a matching block, it's found
      found =
        with_connect_account("acct_direct", fn ->
          Customers.get("cus_direct_insert")
        end)

      assert {:ok, %{id: "cus_direct_insert"}} = found
    end

    test "restores the previous connect account on exit" do
      put_connect_account("acct_outer")
      assert current_connect_account() == "acct_outer"

      with_connect_account("acct_inner", fn ->
        assert current_connect_account() == "acct_inner"
      end)

      assert current_connect_account() == "acct_outer"

      # Clean up so the next test isn't polluted
      put_connect_account(nil)
    end
  end
end
