package main

import "testing"

func TestParseBinance(t *testing.T) {
	got, err := parseBinancePrices([]byte(`[{"symbol":"BTCUSDT","price":"78280.01000000"},{"symbol":"ETHUSDT","price":"0"}]`))
	if err != nil || got["BTCUSDT"] != 78280.01 || len(got) != 1 {
		t.Fatalf("%v %v", got, err)
	}
}

func TestParseTwelveData(t *testing.T) {
	batch := `{"AAPL":{"price":"227.52000"},"EUR/USD":{"price":"1.12670"},"XYZ":{"code":400,"message":"bad","status":"error"}}`
	got, err := parseTwelvePrices([]byte(batch), []string{"AAPL", "EUR/USD", "XYZ"})
	if err != nil || got["AAPL"] != 227.52 || got["EUR/USD"] != 1.1267 || len(got) != 2 {
		t.Fatalf("batch %v %v", got, err)
	}
	single, err := parseTwelvePrices([]byte(`{"price":"2650.12"}`), []string{"XAU/USD"})
	if err != nil || single["XAU/USD"] != 2650.12 {
		t.Fatalf("single %v %v", single, err)
	}
	if _, err := parseTwelvePrices([]byte(`{"code":429,"message":"run out of API credits","status":"error"}`), []string{"AAPL"}); err == nil {
		t.Fatal("rate-limit error must surface")
	}
}

func TestParseUpstox(t *testing.T) {
	body := `{"status":"success","data":{"NSE_EQ:RELIANCE":{"last_price":2731.5,"instrument_token":"NSE_EQ|INE002A01018"},
	"NSE_EQ:TCS":{"last_price":4100,"instrument_token":"NSE_EQ|INE467B01029"}}}`
	got, err := parseUpstoxLTP([]byte(body), []string{"NSE_EQ|INE002A01018", "NSE_EQ|INE467B01029"})
	if err != nil || got["NSE_EQ|INE002A01018"] != 2731.5 || got["NSE_EQ|INE467B01029"] != 4100 {
		t.Fatalf("%v %v", got, err)
	}
	one, _ := parseUpstoxLTP([]byte(`{"status":"success","data":{"NSE_INDEX:Nifty 50":{"last_price":24100.5}}}`), []string{"NSE_INDEX|Nifty 50"})
	if one["NSE_INDEX|Nifty 50"] != 24100.5 {
		t.Fatalf("single key without token: %v", one)
	}
}
