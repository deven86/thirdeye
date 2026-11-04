package main

import "os"

func writeFile(path string, b []byte) error { return os.WriteFile(path, b, 0o600) }

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
