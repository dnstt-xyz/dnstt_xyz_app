// Package desktop provides C-compatible FFI bindings for desktop platforms
package main

/*
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
*/
import "C"
import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/net/proxy"
	"www.bamsoftware.com/git/dnstt.git/mobile"
)

var (
	client     *mobile.DnsttClient
	clientLock sync.Mutex
	lastError  string

	// For testing - use a different port range to avoid conflicts
	testPortCounter int = 17000
	testPortLock    sync.Mutex
)

//export dnstt_create_client
func dnstt_create_client(dnsServer *C.char, tunnelDomain *C.char, pubKeyHex *C.char, listenAddr *C.char) C.int {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client != nil {
		lastError = "client already exists"
		return -1
	}

	c, err := mobile.NewClient(
		C.GoString(dnsServer),
		C.GoString(tunnelDomain),
		C.GoString(pubKeyHex),
		C.GoString(listenAddr),
	)
	if err != nil {
		lastError = fmt.Sprintf("failed to create client: %v", err)
		return -1
	}

	client = c
	log.Printf("dnstt client created")
	return 0
}

//export dnstt_start
func dnstt_start() C.int {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		lastError = "client not created"
		return -1
	}

	err := client.Start()
	if err != nil {
		lastError = fmt.Sprintf("failed to start: %v", err)
		return -1
	}

	log.Printf("dnstt client started")
	return 0
}

//export dnstt_stop
func dnstt_stop() C.int {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return 0
	}

	client.Stop()
	client = nil
	log.Printf("dnstt client stopped")
	return 0
}

//export dnstt_is_running
func dnstt_is_running() C.bool {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.bool(false)
	}
	return C.bool(client.IsRunning())
}

//export dnstt_get_last_error
func dnstt_get_last_error() *C.char {
	return C.CString(lastError)
}

//export dnstt_free_string
func dnstt_free_string(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// getNextTestPort returns a unique port for testing
func getNextTestPort() int {
	testPortLock.Lock()
	defer testPortLock.Unlock()
	port := testPortCounter
	testPortCounter++
	if testPortCounter > 18000 {
		testPortCounter = 17000
	}
	return port
}

//export dnstt_test_dns_server
// dnstt_test_dns_server tests if a DNS server works with the tunnel by:
// 1. Creating a temporary dnstt client
// 2. Making an HTTP request through the SOCKS5 proxy
// 3. Returns latency in milliseconds on success, -1 on failure
func dnstt_test_dns_server(dnsServer *C.char, tunnelDomain *C.char, pubKeyHex *C.char, testUrl *C.char, timeoutMs C.int) C.int {
	dns := C.GoString(dnsServer)
	domain := C.GoString(tunnelDomain)
	pubKey := C.GoString(pubKeyHex)
	url := C.GoString(testUrl)
	timeout := time.Duration(timeoutMs) * time.Millisecond

	// Get a unique port for this test
	port := getNextTestPort()
	listenAddr := fmt.Sprintf("127.0.0.1:%d", port)

	log.Printf("Testing DNS %s with tunnel %s on port %d", dns, domain, port)

	// Create temporary client
	testClient, err := mobile.NewClient(dns, domain, pubKey, listenAddr)
	if err != nil {
		lastError = fmt.Sprintf("failed to create test client: %v", err)
		log.Printf("Test failed: %s", lastError)
		return -1
	}

	// Start the client
	err = testClient.Start()
	if err != nil {
		lastError = fmt.Sprintf("failed to start test client: %v", err)
		log.Printf("Test failed: %s", lastError)
		return -1
	}

	// Ensure cleanup
	defer func() {
		testClient.Stop()
		log.Printf("Test client stopped for port %d", port)
	}()

	// Wait a bit for the SOCKS5 proxy to be ready
	time.Sleep(100 * time.Millisecond)

	// Create SOCKS5 dialer
	dialer, err := proxy.SOCKS5("tcp", listenAddr, nil, proxy.Direct)
	if err != nil {
		lastError = fmt.Sprintf("failed to create SOCKS5 dialer: %v", err)
		log.Printf("Test failed: %s", lastError)
		return -1
	}

	// Create HTTP client with SOCKS5 proxy
	httpTransport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
	}
	httpClient := &http.Client{
		Transport: httpTransport,
		Timeout:   timeout,
	}

	// Make the request
	start := time.Now()
	resp, err := httpClient.Get(url)
	if err != nil {
		lastError = fmt.Sprintf("HTTP request failed: %v", err)
		log.Printf("Test failed: %s", lastError)
		return -1
	}
	defer resp.Body.Close()

	// Read response body to ensure full round-trip
	_, err = io.ReadAll(resp.Body)
	if err != nil {
		lastError = fmt.Sprintf("failed to read response: %v", err)
		log.Printf("Test failed: %s", lastError)
		return -1
	}

	latency := time.Since(start)

	if resp.StatusCode >= 200 && resp.StatusCode < 400 {
		log.Printf("Test SUCCESS for DNS %s: %dms", dns, latency.Milliseconds())
		return C.int(latency.Milliseconds())
	}

	lastError = fmt.Sprintf("HTTP status %d", resp.StatusCode)
	log.Printf("Test failed: %s", lastError)
	return -1
}

func main() {}
