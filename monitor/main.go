// Command thirdeye-monitor watches your Third Eye trades on a Windows PC that stays on, and sends
// alerts (entry zone, stop-loss, take-profits, time limit, sharp moves) to your iPhone even when
// the app is closed.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

const (
	taskName    = "ThirdEye Monitor"
	defaultAddr = "127.0.0.1:8787"
)

func main() {
	cmd, args := "help", os.Args[1:]
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	dataDir := fs.String("data", defaultDataDir(), "data folder")
	addr := fs.String("addr", defaultAddr, "listen address; keep it on 127.0.0.1 — Tailscale serves it to your devices")
	_ = fs.Parse(args)

	switch cmd {
	case "run":
		run(*dataDir, *addr)
	case "install":
		exitOn(install(*dataDir, *addr))
	case "uninstall":
		exitOn(uninstall())
	case "pair":
		exitOn(cliPair(*dataDir, *addr))
	case "status":
		exitOn(cliStatus(*dataDir, *addr))
	case "version":
		fmt.Println(version)
	default:
		help()
		if len(os.Args) == 1 { // double-clicked: keep the window open
			fmt.Print("\nPress Enter to close…")
			_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
		}
	}
}

func help() {
	fmt.Printf(`Third Eye monitor %s — watches your trades and sends alerts to your iPhone.

Setup (once, in a Command Prompt opened with "Run as administrator", inside this folder):
  thirdeye-monitor install     start automatically at boot, keep the PC awake, publish it to
                               your Tailscale devices, and show the pairing code for the app
Daily use: nothing — it runs in the background.

Other commands:
  thirdeye-monitor pair        new pairing code for Third Eye → Settings → Alerts
  thirdeye-monitor status      what it is watching, last prices, recent alerts
  thirdeye-monitor uninstall   stop and remove the background task
  thirdeye-monitor run         run in this window (for testing)

Push notifications need your Apple key: put the AuthKey_XXXXXXXXXX.p8 file in this folder.
Data folder: %s
`, version, defaultDataDir())
}

func exitOn(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func openLog(dir string) io.Writer {
	_ = os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "monitor.log")
	if fi, err := os.Stat(path); err == nil && fi.Size() > 5<<20 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return io.Discard
	}
	return f
}

func run(dataDir, addr string) {
	log.SetOutput(io.MultiWriter(os.Stdout, openLog(dataDir)))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		// Another copy (the background task) is already running — nothing to do.
		log.Printf("not starting: %v (already running?)", err)
		return
	}
	store, err := OpenStore(dataDir)
	if err != nil {
		log.Fatalf("data folder %s: %v", dataDir, err)
	}
	exe, _ := os.Executable()
	mon := NewMonitor(store, dataDir, filepath.Dir(exe))
	keepAwake()

	store.Lock()
	if len(store.S.Tokens) == 0 {
		code := store.NewPairCode(time.Now())
		_ = store.Save()
		log.Printf("not paired yet — pairing code %s (valid 15 minutes; run `thirdeye-monitor pair` for a new one)", code)
	}
	store.Unlock()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	srv := &http.Server{Handler: NewServer(mon).Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("server: %v", err)
			stop()
		}
	}()
	log.Printf("Third Eye monitor %s listening on %s, data in %s", version, addr, dataDir)
	mon.Run(ctx)
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
}

// --- local command line (talks to the running monitor) ---

func adminKey(dataDir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dataDir, "state.json"))
	if err != nil {
		return "", fmt.Errorf("the monitor has not run yet (%v) — run `thirdeye-monitor install` first", err)
	}
	var s struct {
		AdminKey string `json:"adminKey"`
	}
	if err := json.Unmarshal(b, &s); err != nil || s.AdminKey == "" {
		return "", errors.New("could not read the monitor's state file")
	}
	return s.AdminKey, nil
}

func adminRequest(dataDir, addr, method, path string, out any) error {
	key, err := adminKey(dataDir)
	if err != nil {
		return err
	}
	req, _ := http.NewRequest(method, "http://"+addr+path, nil)
	req.Header.Set("X-Admin-Key", key)
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("the monitor is not running (%v) — run `thirdeye-monitor install` as administrator", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("monitor said %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func cliPair(dataDir, addr string) error {
	var r struct {
		Code    string    `json:"code"`
		Expires time.Time `json:"expires"`
	}
	if err := adminRequest(dataDir, addr, http.MethodPost, "/v1/admin/pair-code", &r); err != nil {
		return err
	}
	host := tailscaleName()
	if host == "" {
		host = "(your PC's Tailscale name, e.g. my-pc.tail1234.ts.net)"
	}
	fmt.Printf("\nIn Third Eye → Settings → Alerts, enter:\n\n  PC address:    %s\n  Pairing code:  %s   (valid until %s)\n\n",
		host, r.Code, r.Expires.Local().Format("15:04"))
	return nil
}

func cliStatus(dataDir, addr string) error {
	var s StatusResponse
	if err := adminRequest(dataDir, addr, http.MethodGet, "/v1/admin/status", &s); err != nil {
		return err
	}
	fmt.Printf("Third Eye monitor %s · running since %s · last check %s\n", s.Version,
		s.StartedAt.Local().Format("2 Jan 15:04"), s.LastLoopAt.Local().Format("15:04:05"))
	fmt.Printf("Push: %s · devices: %d\n", s.APNs, s.Devices)
	for k, v := range s.Providers {
		fmt.Printf("  %-10s %s\n", k, v)
	}
	fmt.Printf("Watching %d trade(s):\n", s.Watching)
	for _, t := range s.Trades {
		state := "market closed"
		if t.MarketOpen {
			state = "market open"
		}
		if t.LastPrice > 0 {
			fmt.Printf("  %-14s last %-12s at %s (%s)\n", t.Symbol, money(t.LastPrice, ""), t.LastCheck.Local().Format("15:04:05"), state)
		} else {
			fmt.Printf("  %-14s no price yet (%s)\n", t.Symbol, state)
		}
	}
	if len(s.Alerts) > 0 {
		fmt.Println("Recent alerts:")
		for i, a := range s.Alerts {
			if i == 10 {
				break
			}
			fmt.Printf("  %s  %s — %s\n", a.At.Local().Format("2 Jan 15:04"), a.Title, a.Delivered)
		}
	}
	return nil
}

// tailscaleName returns this PC's MagicDNS name, e.g. "my-pc.tail1234.ts.net".
func tailscaleName() string {
	exe := tailscaleExe()
	if exe == "" {
		return ""
	}
	out, err := exec.Command(exe, "status", "--json").Output()
	if err != nil {
		return ""
	}
	var st struct {
		Self struct {
			DNSName string `json:"DNSName"`
		} `json:"Self"`
	}
	if json.Unmarshal(out, &st) != nil {
		return ""
	}
	return strings.TrimSuffix(st.Self.DNSName, ".")
}
