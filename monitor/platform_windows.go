//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

func defaultDataDir() string {
	pd := os.Getenv("ProgramData")
	if pd == "" {
		pd = `C:\ProgramData`
	}
	return filepath.Join(pd, "ThirdEye")
}

// --- DPAPI: secrets are encrypted with this machine's Windows key before they touch the disk ---

var (
	crypt32                     = syscall.NewLazyDLL("crypt32.dll")
	kernel32                    = syscall.NewLazyDLL("kernel32.dll")
	procCryptProtectData        = crypt32.NewProc("CryptProtectData")
	procCryptUnprotectData      = crypt32.NewProc("CryptUnprotectData")
	procLocalFree               = kernel32.NewProc("LocalFree")
	procSetThreadExecutionState = kernel32.NewProc("SetThreadExecutionState")
)

type dataBlob struct {
	cbData uint32
	pbData *byte
}

func newBlob(d []byte) *dataBlob {
	if len(d) == 0 {
		return &dataBlob{}
	}
	return &dataBlob{cbData: uint32(len(d)), pbData: &d[0]}
}

func (b *dataBlob) bytes() []byte {
	if b.pbData == nil || b.cbData == 0 {
		return nil
	}
	out := make([]byte, b.cbData)
	copy(out, unsafe.Slice(b.pbData, b.cbData))
	return out
}

const (
	cryptprotectUIForbidden  = 0x1
	cryptprotectLocalMachine = 0x4 // the background task (SYSTEM) and the command line can both read it
)

func protect(d []byte) ([]byte, error) {
	var out dataBlob
	in := newBlob(d)
	r, _, err := procCryptProtectData.Call(uintptr(unsafe.Pointer(in)), 0, 0, 0, 0,
		cryptprotectUIForbidden|cryptprotectLocalMachine, uintptr(unsafe.Pointer(&out)))
	if r == 0 {
		return nil, fmt.Errorf("CryptProtectData: %w", err)
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	return out.bytes(), nil
}

func unprotect(d []byte) ([]byte, error) {
	var out dataBlob
	in := newBlob(d)
	r, _, err := procCryptUnprotectData.Call(uintptr(unsafe.Pointer(in)), 0, 0, 0, 0,
		cryptprotectUIForbidden, uintptr(unsafe.Pointer(&out)))
	if r == 0 {
		return nil, fmt.Errorf("CryptUnprotectData: %w", err)
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	return out.bytes(), nil
}

// keepAwake stops Windows from going to sleep while the monitor runs (the screen can still turn off).
func keepAwake() {
	go func() {
		runtime.LockOSThread()
		const esContinuous, esSystemRequired = 0x80000000, 0x00000001
		procSetThreadExecutionState.Call(uintptr(esContinuous | esSystemRequired))
		select {}
	}()
}

func tailscaleExe() string {
	for _, p := range []string{
		filepath.Join(os.Getenv("ProgramFiles"), "Tailscale", "tailscale.exe"),
		`C:\Program Files\Tailscale\tailscale.exe`,
	} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	p, _ := exec.LookPath("tailscale")
	return p
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// taskXML: start at boot as SYSTEM, re-check every 5 minutes (restarts it if it ever stopped; a second
// copy exits at once because the port is taken), no 3-day time limit, run on battery too.
func taskXML(exe, dataDir, addr string) string {
	args := fmt.Sprintf(`run -data "%s" -addr %s`, dataDir, addr)
	return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Third Eye price monitor: sends trade alerts to your iPhone.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>true</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>` + xmlEscape(exe) + `</Command>
      <Arguments>` + xmlEscape(args) + `</Arguments>
      <WorkingDirectory>` + xmlEscape(filepath.Dir(exe)) + `</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
`
}

func utf16File(s string) []byte {
	u := utf16.Encode([]rune(s))
	b := make([]byte, 2+2*len(u))
	b[0], b[1] = 0xFF, 0xFE // little-endian BOM
	for i, v := range u {
		binary.LittleEndian.PutUint16(b[2+2*i:], v)
	}
	return b
}

func install(dataDir, addr string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.Abs(exe)
	fmt.Println("1/4  Registering the background task (starts at boot, keeps the PC awake)…")
	tmp := filepath.Join(os.TempDir(), "thirdeye-monitor-task.xml")
	if err := os.WriteFile(tmp, utf16File(taskXML(exe, dataDir, addr)), 0o600); err != nil {
		return err
	}
	defer os.Remove(tmp)
	out, err := exec.Command("schtasks", "/Create", "/TN", taskName, "/XML", tmp, "/F").CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(strings.ToLower(msg), "denied") {
			return errors.New("access denied — open Command Prompt with \"Run as administrator\" and run this again")
		}
		return fmt.Errorf("schtasks: %v %s", err, msg)
	}
	_ = exec.Command("schtasks", "/Run", "/TN", taskName).Run()

	fmt.Println("2/4  Starting…")
	up := false
	for i := 0; i < 30 && !up; i++ {
		time.Sleep(time.Second)
		resp, err := (&http.Client{Timeout: 2 * time.Second}).Get("http://" + addr + "/healthz")
		if err == nil {
			resp.Body.Close()
			up = resp.StatusCode == 200
		}
	}
	if !up {
		return errors.New("the monitor did not start — see monitor.log in " + dataDir)
	}

	fmt.Println("3/4  Publishing it to your Tailscale devices (HTTPS, private to your tailnet)…")
	ts := tailscaleExe()
	if ts == "" {
		fmt.Println("     Tailscale is not installed on this PC. Install it from https://tailscale.com/download/windows,")
		fmt.Println("     sign in, then run `thirdeye-monitor install` again.")
	} else {
		port := addr[strings.LastIndex(addr, ":")+1:]
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		out, err := exec.CommandContext(ctx, ts, "serve", "--bg", port).CombinedOutput()
		cancel()
		text := strings.TrimSpace(string(out))
		if text != "" {
			fmt.Println("     " + strings.ReplaceAll(text, "\n", "\n     "))
		}
		if err != nil || strings.Contains(text, "not enabled") || strings.Contains(text, "login.tailscale.com") {
			fmt.Println("     → If a link is shown above, open it, allow HTTPS for your tailnet, then run install again.")
		}
		// Second door by IP address (http://100.x.y.z:8788), for iPhones that can't resolve the name.
		// Still private and encrypted: only your tailnet can reach it, over Tailscale's WireGuard tunnel.
		ctx2, cancel2 := context.WithTimeout(context.Background(), 25*time.Second)
		out2, err2 := exec.CommandContext(ctx2, ts, "serve", "--bg", "--tcp="+ipPort, "tcp://127.0.0.1:"+port).CombinedOutput()
		cancel2()
		if err2 != nil {
			fmt.Println("     (IP access not set up: " + strings.TrimSpace(string(out2)) + ")")
		}
	}

	fmt.Println("4/4  Pairing code for the app:")
	return cliPair(dataDir, addr)
}

// ipPort is the Tailscale port for the by-IP fallback (plain HTTP inside the encrypted tailnet).
const ipPort = "8788"

func uninstall() error {
	_ = exec.Command("schtasks", "/End", "/TN", taskName).Run()
	out, err := exec.Command("schtasks", "/Delete", "/TN", taskName, "/F").CombinedOutput()
	if err != nil {
		return fmt.Errorf("schtasks: %v %s", err, strings.TrimSpace(string(out)))
	}
	if ts := tailscaleExe(); ts != "" {
		_ = exec.Command(ts, "serve", "reset").Run()
	}
	fmt.Println("Removed. Your data folder was kept:", defaultDataDir())
	return nil
}
