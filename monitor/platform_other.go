//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
)

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".thirdeye-monitor")
}

// protect/unprotect: on Windows this is DPAPI; elsewhere (tests, development) values are stored as is.
func protect(b []byte) ([]byte, error)   { return append([]byte(nil), b...), nil }
func unprotect(b []byte) ([]byte, error) { return append([]byte(nil), b...), nil }

func keepAwake() {}

func tailscaleExe() string {
	p, _ := exec.LookPath("tailscale")
	return p
}

func install(dataDir, addr string) error {
	return errors.New("install is for Windows; on this system use `thirdeye-monitor run`")
}

func uninstall() error { return errors.New("uninstall is for Windows") }
