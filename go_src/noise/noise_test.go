package noise

import (
	"bytes"
	"io"
	"net"
	"testing"

	"github.com/flynn/noise"
)

func allMessages(buf []byte) ([][]byte, error) {
	var messages [][]byte
	r := bytes.NewReader(buf)
	for {
		msg, err := readMessage(r)
		if err != nil {
			return messages, err
		}
		messages = append(messages, msg)
	}
}

func messagesEqual(a, b [][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !bytes.Equal(a[i], b[i]) {
			return false
		}
	}
	return true
}

func TestReadMessage(t *testing.T) {
	for _, test := range []struct {
		input    string
		messages [][]byte
		err      error
	}{
		{"", [][]byte{}, io.EOF},
		{"\x00", [][]byte{}, io.ErrUnexpectedEOF},
		{"\x00\x00", [][]byte{{}}, io.EOF},
		{"\x00\x00\x00", [][]byte{{}}, io.ErrUnexpectedEOF},
		{"\x00\x01", [][]byte{}, io.ErrUnexpectedEOF},
		{"\x00\x05hello\x00\x05world", [][]byte{[]byte("hello"), []byte("world")}, io.EOF},
	} {
		packets, err := allMessages([]byte(test.input))
		if !messagesEqual(packets, test.messages) || err != test.err {
			t.Errorf("%x\nreturned %x %v\nexpected %x %v",
				test.input, packets, err, test.messages, test.err)
		}
	}
}

func TestMessageRoundTrip(t *testing.T) {
	for _, messages := range [][][]byte{
		{},
	} {
		var buf bytes.Buffer
		for _, msg := range messages {
			err := writeMessage(&buf, msg)
			if err != nil {
				panic(err)
			}
		}
		output, err := allMessages(buf.Bytes())
		if !messagesEqual(output, messages) || err != io.EOF {
			t.Errorf("%x roundtripped to %x %v",
				messages, output, err)
		}
	}
}

func TestReadKey(t *testing.T) {
	for _, test := range []struct {
		input  string
		output []byte
	}{
		{"", nil},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", nil},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", []byte("\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef")},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n", []byte("\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef")},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0", nil},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nX", nil},
		{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n\n", nil},
		{"\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", nil},
		{"X123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", nil},
		{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nil},
	} {
		output, err := ReadKey(bytes.NewReader([]byte(test.input)))
		if test.output == nil {
			if err == nil {
				t.Errorf("%+q expected error", test.input)
			}
		} else {
			if err != nil {
				t.Errorf("%+q returned error %v", test.input, err)
			} else if !bytes.Equal(output, test.output) {
				t.Errorf("%+q got %x, expected %x", test.input, output, test.output)
			}
		}
	}
}

func TestUnexpectedPayload(t *testing.T) {
	privkey, err := GeneratePrivkey()
	if err != nil {
		panic(err)
	}
	pubkey := PubkeyFromPrivkey(privkey)

	// Test the client sending an unexpected payload.
	clientWithPayload := func(rwc io.ReadWriteCloser) error {
		config := newConfig()
		config.Initiator = true
		config.PeerStatic = pubkey
		handshakeState, err := noise.NewHandshakeState(config)
		if err != nil {
			return err
		}

		// -> e, es
		msg, _, _, err := handshakeState.WriteMessage(nil, []byte("payload"))
		if err != nil {
			return err
		}
		err = writeMessage(rwc, msg)
		if err != nil {
			return err
		}

		// <- e, es
		// Return nil for all errors after this point, because we expect
		// the server to have failed, but we want to keep up the game
		// just in case the server did not fail.
		msg, err = readMessage(rwc)
		if err != nil {
			return nil
		}
		_, _, _, err = handshakeState.ReadMessage(nil, msg)
		if err != nil {
			return nil
		}

		return nil
	}
	func() {
		c, s := net.Pipe()
		defer s.Close()

		// Fake a client side that sends a payload.
		go func() {
			defer c.Close()
			err := clientWithPayload(c)
			if err != nil {
				t.Fatal(err)
			}
		}()

		server, err := NewServer(s, privkey)
		if err == nil || err.Error() != "unexpected client payload" || server != nil {
			t.Errorf("NewServer got (%T, %v)", server, err)
		}
	}()

	// Test the server sending an unexpected payload.
	serverWithPayload := func(rwc io.ReadWriteCloser) error {
		config := newConfig()
		config.Initiator = false
		config.StaticKeypair = noise.DHKey{Private: privkey, Public: pubkey}
		handshakeState, err := noise.NewHandshakeState(config)
		if err != nil {
			return err
		}

		// -> e, es
		msg, err := readMessage(rwc)
		if err != nil {
			return err
		}
		_, _, _, err = handshakeState.ReadMessage(nil, msg)
		if err != nil {
			return err
		}

		// <- e, es
		msg, _, _, err = handshakeState.WriteMessage(nil, []byte("payload"))
		if err != nil {
			return err
		}
		err = writeMessage(rwc, msg)
		if err != nil {
			return err
		}

		return nil
	}
	func() {
		c, s := net.Pipe()
		defer c.Close()

		// Fake a server side that sends a payload.
		go func() {
			defer s.Close()
			err := serverWithPayload(s)
			if err != nil {
				t.Fatal(err)
			}
		}()

		client, err := NewClient(c, pubkey)
		if err == nil || err.Error() != "unexpected server payload" || client != nil {
			t.Errorf("NewClient got (%T, %v)", client, err)
		}
	}()
}
