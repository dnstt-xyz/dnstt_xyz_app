// Package mobile provides a mobile-friendly interface to dnstt-client
package mobile

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/xtaci/kcp-go/v5"
	"github.com/xtaci/smux"
	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/noise"
	"www.bamsoftware.com/git/dnstt.git/turbotunnel"
)

const (
	// smux streams will be closed after this much time without receiving data.
	idleTimeout = 2 * time.Minute

	// Connection timeout for handshake (10 seconds for faster feedback)
	handshakeTimeout = 10 * time.Second

	// Padding configuration
	numPadding        = 3
	numPaddingForPoll = 8

	// Poll timing
	initPollDelay       = 500 * time.Millisecond
	maxPollDelay        = 10 * time.Second
	pollDelayMultiplier = 2.0
	pollLimit           = 16
)

// base32Encoding is a base32 encoding without padding.
var base32Encoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// ProtectSocketFunc is a callback to protect a socket from VPN routing
type ProtectSocketFunc func(fd int) bool

// DnsttClient wraps the dnstt tunnel client
type DnsttClient struct {
	mu            sync.Mutex
	running       bool
	listener      net.Listener
	conn          net.PacketConn
	ctx           context.Context
	cancel        context.CancelFunc
	pubKey        []byte
	domain        string
	dnsAddr       string
	listenAddr    string
	sess          *smux.Session
	tunFd         int
	protectSocket ProtectSocketFunc
	shareProxy    bool // If true, bind to 0.0.0.0 instead of 127.0.0.1
}

// NewClient creates a new dnstt client
func NewClient(dnsServer, tunnelDomain, pubKeyHex, listenAddr string) (*DnsttClient, error) {
	pubKey, err := noise.DecodeKey(pubKeyHex)
	if err != nil {
		return nil, fmt.Errorf("invalid public key: %v", err)
	}

	return &DnsttClient{
		pubKey:     pubKey,
		domain:     tunnelDomain,
		dnsAddr:    dnsServer,
		listenAddr: listenAddr,
		tunFd:      -1,
	}, nil
}

// SetTunFd sets the TUN file descriptor for routing traffic
func (c *DnsttClient) SetTunFd(fd int) {
	c.tunFd = fd
}

// SetProtectSocket sets a callback to protect sockets from VPN routing
func (c *DnsttClient) SetProtectSocket(protectFunc ProtectSocketFunc) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.protectSocket = protectFunc
}

// SetShareProxy enables or disables proxy sharing (binding to 0.0.0.0)
func (c *DnsttClient) SetShareProxy(enabled bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.shareProxy = enabled
}

// IsShareProxyEnabled returns whether proxy sharing is enabled
func (c *DnsttClient) IsShareProxyEnabled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.shareProxy
}

// Start starts the SOCKS5 proxy
func (c *DnsttClient) Start() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.running {
		return nil
	}

	// Parse domain
	domain, err := dns.ParseName(c.domain)
	if err != nil {
		return fmt.Errorf("invalid domain: %v", err)
	}

	// Resolve DNS server address
	dnsAddr := c.dnsAddr
	if _, _, err := net.SplitHostPort(dnsAddr); err != nil {
		dnsAddr = net.JoinHostPort(dnsAddr, "53")
	}

	remoteAddr, err := net.ResolveUDPAddr("udp", dnsAddr)
	if err != nil {
		return fmt.Errorf("failed to resolve DNS server: %v", err)
	}

	// Create UDP connection - bind to 0.0.0.0 (IPv4 only) to avoid IPv6 routing issues
	localAddr := &net.UDPAddr{
		IP:   net.IPv4zero,
		Port: 0,
	}
	pconn, err := net.ListenUDP("udp4", localAddr)
	if err != nil {
		return fmt.Errorf("failed to create UDP socket: %v", err)
	}

	// Protect the socket from VPN routing if callback is set
	if c.protectSocket != nil {
		// Get the file descriptor from the UDP connection
		rawConn, err := pconn.SyscallConn()
		if err != nil {
			pconn.Close()
			return fmt.Errorf("failed to get socket control: %v", err)
		}

		var protectErr error
		err = rawConn.Control(func(fd uintptr) {
			if !c.protectSocket(int(fd)) {
				protectErr = fmt.Errorf("failed to protect socket")
			} else {
				log.Printf("UDP socket protected from VPN routing (fd=%d)", fd)
			}
		})
		if err != nil {
			pconn.Close()
			return fmt.Errorf("failed to control socket: %v", err)
		}
		if protectErr != nil {
			pconn.Close()
			return protectErr
		}
	}

	c.conn = pconn

	// Create context
	c.ctx, c.cancel = context.WithCancel(context.Background())

	// Calculate MTU
	mtu := dnsNameCapacity(domain) - 8 - 1 - numPadding - 1
	if mtu < 80 {
		pconn.Close()
		return fmt.Errorf("domain %s leaves only %d bytes for payload", domain, mtu)
	}
	log.Printf("effective MTU %d", mtu)

	// Wrap in DNSPacketConn
	dnsConn := newDNSPacketConn(pconn, remoteAddr, domain)

	// Open KCP connection
	kcpConn, err := kcp.NewConn2(remoteAddr, nil, 0, 0, dnsConn)
	if err != nil {
		pconn.Close()
		return fmt.Errorf("opening KCP conn: %v", err)
	}

	// Configure KCP
	kcpConn.SetStreamMode(true)
	kcpConn.SetNoDelay(0, 0, 0, 1)
	kcpConn.SetWindowSize(turbotunnel.QueueSize/2, turbotunnel.QueueSize/2)
	if !kcpConn.SetMtu(mtu) {
		kcpConn.Close()
		pconn.Close()
		return fmt.Errorf("failed to set MTU")
	}

	// Create Noise channel with timeout
	type noiseResult struct {
		conn io.ReadWriteCloser
		err  error
	}
	noiseResultChan := make(chan noiseResult, 1)
	go func() {
		conn, err := noise.NewClient(kcpConn, c.pubKey)
		noiseResultChan <- noiseResult{conn, err}
	}()

	var noiseConn io.ReadWriteCloser
	select {
	case result := <-noiseResultChan:
		if result.err != nil {
			kcpConn.Close()
			pconn.Close()
			return fmt.Errorf("failed to create noise session: %v", result.err)
		}
		noiseConn = result.conn
	case <-time.After(handshakeTimeout):
		kcpConn.Close()
		pconn.Close()
		return fmt.Errorf("connection timeout: DNS server not responding")
	}

	// Start smux session
	smuxConfig := smux.DefaultConfig()
	smuxConfig.Version = 2
	smuxConfig.KeepAliveTimeout = idleTimeout
	smuxConfig.MaxStreamBuffer = 1 * 1024 * 1024
	sess, err := smux.Client(noiseConn, smuxConfig)
	if err != nil {
		noiseConn.Close()
		pconn.Close()
		return fmt.Errorf("opening smux session: %v", err)
	}
	c.sess = sess

	// Determine the listen address based on proxy sharing
	listenAddr := c.listenAddr
	if c.shareProxy {
		// Replace 127.0.0.1 with 0.0.0.0 to allow connections from other devices
		if strings.HasPrefix(listenAddr, "127.0.0.1:") {
			port := strings.TrimPrefix(listenAddr, "127.0.0.1:")
			listenAddr = "0.0.0.0:" + port
			log.Printf("Proxy sharing enabled, listening on %s", listenAddr)
		}
	}

	// Start TCP listener for SOCKS5
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		sess.Close()
		pconn.Close()
		return fmt.Errorf("failed to start listener: %v", err)
	}
	c.listener = listener

	// Accept connections
	go c.acceptLoop()

	c.running = true
	log.Printf("dnstt client started, listening on %s", c.listenAddr)
	return nil
}

// Stop stops the client
func (c *DnsttClient) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.running {
		return
	}

	if c.cancel != nil {
		c.cancel()
	}
	if c.sess != nil {
		c.sess.Close()
	}
	if c.listener != nil {
		c.listener.Close()
	}
	if c.conn != nil {
		c.conn.Close()
	}

	c.running = false
	log.Printf("dnstt client stopped")
}

// IsRunning returns whether the client is running
func (c *DnsttClient) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running
}

// DialTunnel creates a connection through the tunnel to the specified address
func (c *DnsttClient) DialTunnel(address string) (net.Conn, error) {
	c.mu.Lock()
	sess := c.sess
	c.mu.Unlock()

	if sess == nil {
		return nil, fmt.Errorf("tunnel not connected")
	}

	stream, err := sess.OpenStream()
	if err != nil {
		return nil, err
	}

	return stream, nil
}

func (c *DnsttClient) acceptLoop() {
	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		conn, err := c.listener.Accept()
		if err != nil {
			if c.ctx.Err() != nil {
				return
			}
			continue
		}

		go c.handleConnection(conn.(*net.TCPConn))
	}
}

func (c *DnsttClient) handleConnection(local *net.TCPConn) {
	defer local.Close()

	stream, err := c.sess.OpenStream()
	if err != nil {
		log.Printf("failed to open stream: %v", err)
		return
	}
	defer stream.Close()

	log.Printf("new stream opened")

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		io.Copy(stream, local)
		local.CloseRead()
		stream.Close()
	}()
	go func() {
		defer wg.Done()
		io.Copy(local, stream)
		local.CloseWrite()
	}()
	wg.Wait()
}

// dnsNameCapacity returns the number of bytes remaining for encoded data
func dnsNameCapacity(domain dns.Name) int {
	capacity := 255
	capacity -= 1 // null terminator
	for _, label := range domain {
		capacity -= len(label) + 1
	}
	capacity = capacity * 63 / 64
	capacity = capacity * 5 / 8
	return capacity
}

// DNSPacketConn wraps a PacketConn to do DNS encoding/decoding
type dnsPacketConn struct {
	clientID turbotunnel.ClientID
	domain   dns.Name
	pollChan chan struct{}
	*turbotunnel.QueuePacketConn
}

func newDNSPacketConn(transport net.PacketConn, addr net.Addr, domain dns.Name) *dnsPacketConn {
	clientID := turbotunnel.NewClientID()
	c := &dnsPacketConn{
		clientID:        clientID,
		domain:          domain,
		pollChan:        make(chan struct{}, pollLimit),
		QueuePacketConn: turbotunnel.NewQueuePacketConn(clientID, 0),
	}
	go c.recvLoop(transport)
	go c.sendLoop(transport, addr)
	return c
}

func (c *dnsPacketConn) recvLoop(transport net.PacketConn) {
	for {
		var buf [4096]byte
		n, addr, err := transport.ReadFrom(buf[:])
		if err != nil {
			if err, ok := err.(net.Error); ok && err.Temporary() {
				continue
			}
			return
		}

		resp, err := dns.MessageFromWireFormat(buf[:n])
		if err != nil {
			continue
		}

		payload := c.dnsResponsePayload(&resp)
		if payload == nil {
			continue
		}

		r := bytes.NewReader(payload)
		any := false
		for {
			p, err := c.nextPacket(r)
			if err != nil {
				break
			}
			any = true
			c.QueuePacketConn.QueueIncoming(p, addr)
		}

		if any {
			select {
			case c.pollChan <- struct{}{}:
			default:
			}
		}
	}
}

func (c *dnsPacketConn) dnsResponsePayload(resp *dns.Message) []byte {
	if resp.Flags&0x8000 != 0x8000 {
		return nil
	}
	if resp.Flags&0x000f != dns.RcodeNoError {
		return nil
	}
	if len(resp.Answer) != 1 {
		return nil
	}
	answer := resp.Answer[0]
	_, ok := answer.Name.TrimSuffix(c.domain)
	if !ok {
		return nil
	}
	if answer.Type != dns.RRTypeTXT {
		return nil
	}
	payload, err := dns.DecodeRDataTXT(answer.Data)
	if err != nil {
		return nil
	}
	return payload
}

func (c *dnsPacketConn) nextPacket(r *bytes.Reader) ([]byte, error) {
	var n uint16
	err := binary.Read(r, binary.BigEndian, &n)
	if err != nil {
		return nil, err
	}
	p := make([]byte, n)
	_, err = io.ReadFull(r, p)
	if err == io.EOF {
		err = io.ErrUnexpectedEOF
	}
	return p, err
}

func (c *dnsPacketConn) sendLoop(transport net.PacketConn, addr net.Addr) {
	pollDelay := initPollDelay
	pollTimer := time.NewTimer(pollDelay)
	for {
		var p []byte
		outgoing := c.QueuePacketConn.OutgoingQueue(addr)
		pollTimerExpired := false

		select {
		case p = <-outgoing:
		default:
			select {
			case p = <-outgoing:
			case <-c.pollChan:
			case <-pollTimer.C:
				pollTimerExpired = true
			}
		}

		if len(p) > 0 {
			select {
			case <-c.pollChan:
			default:
			}
		}

		if pollTimerExpired {
			pollDelay = time.Duration(float64(pollDelay) * pollDelayMultiplier)
			if pollDelay > maxPollDelay {
				pollDelay = maxPollDelay
			}
		} else {
			if !pollTimer.Stop() {
				<-pollTimer.C
			}
			pollDelay = initPollDelay
		}
		pollTimer.Reset(pollDelay)

		err := c.send(transport, p, addr)
		if err != nil {
			log.Printf("send: %v", err)
		}
	}
}

func (c *dnsPacketConn) send(transport net.PacketConn, p []byte, addr net.Addr) error {
	var decoded []byte
	{
		if len(p) >= 224 {
			return fmt.Errorf("packet too long")
		}
		var buf bytes.Buffer
		buf.Write(c.clientID[:])
		n := numPadding
		if len(p) == 0 {
			n = numPaddingForPoll
		}
		buf.WriteByte(byte(224 + n))
		io.CopyN(&buf, rand.Reader, int64(n))
		if len(p) > 0 {
			buf.WriteByte(byte(len(p)))
			buf.Write(p)
		}
		decoded = buf.Bytes()
	}

	encoded := make([]byte, base32Encoding.EncodedLen(len(decoded)))
	base32Encoding.Encode(encoded, decoded)
	encoded = bytes.ToLower(encoded)
	labels := chunks(encoded, 63)
	labels = append(labels, c.domain...)
	name, err := dns.NewName(labels)
	if err != nil {
		return err
	}

	var id uint16
	binary.Read(rand.Reader, binary.BigEndian, &id)
	query := &dns.Message{
		ID:    id,
		Flags: 0x0100,
		Question: []dns.Question{
			{
				Name:  name,
				Type:  dns.RRTypeTXT,
				Class: dns.ClassIN,
			},
		},
		Additional: []dns.RR{
			{
				Name:  dns.Name{},
				Type:  dns.RRTypeOPT,
				Class: 4096,
				TTL:   0,
				Data:  []byte{},
			},
		},
	}
	wireData, err := query.WireFormat()
	if err != nil {
		return err
	}

	_, err = transport.WriteTo(wireData, addr)
	// Don't return error on network failures - just log and continue
	// This prevents temporary network issues from killing the tunnel
	if err != nil && !isNetworkClosedError(err) {
		return err
	}
	return nil
}

func isNetworkClosedError(err error) bool {
	if err == nil {
		return false
	}
	// Check for "use of closed network connection" and similar errors
	errStr := err.Error()
	return strings.Contains(errStr, "closed network connection") ||
		strings.Contains(errStr, "broken pipe") ||
		strings.Contains(errStr, "connection refused")
}

func chunks(p []byte, n int) [][]byte {
	var result [][]byte
	for len(p) > 0 {
		sz := len(p)
		if sz > n {
			sz = n
		}
		result = append(result, p[:sz])
		p = p[sz:]
	}
	return result
}

// GetLocalIPAddresses returns a comma-separated list of local IP addresses
func GetLocalIPAddresses() string {
	var ips []string
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range ifaces {
		// Skip down interfaces and loopback
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			// Skip IPv6 and loopback addresses
			if ip == nil || ip.IsLoopback() || ip.To4() == nil {
				continue
			}

			// Only include private network addresses
			if isPrivateIP(ip) {
				ips = append(ips, ip.String())
			}
		}
	}

	return strings.Join(ips, ",")
}

// isPrivateIP checks if the IP is a private network address
func isPrivateIP(ip net.IP) bool {
	privateBlocks := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
	}

	for _, block := range privateBlocks {
		_, subnet, err := net.ParseCIDR(block)
		if err != nil {
			continue
		}
		if subnet.Contains(ip) {
			return true
		}
	}
	return false
}

// ConnectWithTunFd starts the tunnel using a TUN file descriptor from Android
// This allows the Go code to handle TCP/IP directly
func ConnectWithTunFd(fd int, dnsServer, tunnelDomain, pubKeyHex, socksAddr string) error {
	// Create a file from the fd
	tunFile := os.NewFile(uintptr(fd), "tun")
	if tunFile == nil {
		return fmt.Errorf("invalid tun fd")
	}

	log.Printf("TUN fd received: %d", fd)

	// For now, we don't use gvisor netstack - that would require more dependencies
	// Instead, we just log that this feature needs tun2socks integration
	log.Printf("Note: Full TUN integration requires tun2socks - using SOCKS5 proxy mode")

	return nil
}
