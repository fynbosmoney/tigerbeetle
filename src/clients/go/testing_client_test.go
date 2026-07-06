package tigerbeetle_go

import (
	"testing"

	"github.com/tigerbeetle/tigerbeetle-go/pkg/types"
)

func TestTestingClient(t *testing.T) {
	client, err := NewTestingClient(types.ToUint128(0), []string{"3000"})
	if err != nil {
		t.Fatalf("NewTestingClient: %v", err)
	}
	defer client.Close()

	accountResults, err := client.CreateAccounts([]types.Account{
		{ID: types.ToUint128(1), Ledger: 1, Code: 1},
		{ID: types.ToUint128(2), Ledger: 1, Code: 1},
	})
	if err != nil {
		t.Fatalf("CreateAccounts: %v", err)
	}
	if len(accountResults) != 0 {
		t.Fatalf("expected no account errors, got %+v", accountResults)
	}

	transferResults, err := client.CreateTransfers([]types.Transfer{
		{
			ID:              types.ToUint128(1),
			DebitAccountID:  types.ToUint128(1),
			CreditAccountID: types.ToUint128(2),
			Amount:          types.ToUint128(10),
			Ledger:          1,
			Code:            1,
		},
	})
	if err != nil {
		t.Fatalf("CreateTransfers: %v", err)
	}
	if len(transferResults) != 0 {
		t.Fatalf("expected no transfer errors, got %+v", transferResults)
	}

	accounts, err := client.LookupAccounts([]types.Uint128{types.ToUint128(1), types.ToUint128(2)})
	if err != nil {
		t.Fatalf("LookupAccounts: %v", err)
	}
	if len(accounts) != 2 {
		t.Fatalf("expected 2 accounts, got %d", len(accounts))
	}
	if got := accounts[0].DebitsPosted.BigInt(); got.Int64() != 10 {
		t.Fatalf("account 1 debits_posted = %s, want 10", got.String())
	}
	if got := accounts[1].CreditsPosted.BigInt(); got.Int64() != 10 {
		t.Fatalf("account 2 credits_posted = %s, want 10", got.String())
	}
}
