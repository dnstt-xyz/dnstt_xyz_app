Userspace DNS tunnel with support for DoH and DoT
https://www.bamsoftware.com/software/dnstt/
David Fifield <david@bamsoftware.com>
Public domain

dnstt is a DNS tunnel with these features:
 * Works over DNS over HTTPS (DoH) and DNS over TLS (DoT) as well as
   plaintext UDP DNS.
 * Embeds a sequencing and session protocol (KCP/smux), which means that
   the client does not have to wait for a response before sending more
   data, and any lost packets are automatically retransmitted.
 * Encrypts the contents of the tunnel and authenticates the server by
   public key.

dnstt is an application-layer tunnel that runs in userspace. It doesn't
provide a TUN/TAP interface; it only hooks up a local TCP port with a
remote TCP port (like netcat or `ssh -L`) by way of a DNS resolver. It
does not itself provide a SOCKS or HTTP proxy interface, but you can get
the same effect by running a proxy on the tunnel server and having the
tunnel terminate at the proxy.

```
.------.  |            .---------.             .------.
|tunnel|  |            | public  |             |tunnel|
|client|<---DoH/DoT--->|recursive|<--UDP DNS-->|server|
'------'  |c           |resolver |             '------'
   |      |e           '---------'                |
.------.  |n                                   .------.
|local |  |s                                   |remote|
| app  |  |o                                   | app  |
'------'  |r                                   '------'
```


## DNS zone setup

Because the server side of the tunnel acts like an authoritative name
server, you need to own a domain name and set up a subdomain for the
tunnel. Let's say your domain name is example.com and your server's IP
addresses are 203.0.113.2 and 2001:db8::2. Go to your name registrar and
add three new records:

```
A	tns.example.com	points to 203.0.113.2
AAAA	tns.example.com	points to 2001:db8::2
NS	t.example.com	is managed by tns.example.com
```

The labels `tns` and `t` can be anything you want, but the `tns` label
should not be a subdomain of the `t` label (that space is reserved for
the contents of the tunnel), and the `t` label should be short (because
there is limited space available in a DNS message, and the domain name
takes up part of that space).

Now, when a recursive DNS resolver receives a query for a name like
aaaa.t.example.com, it will forward the query to the tunnel server at
203.0.113.2 or 2001:db8::2.


## Tunnel server setup

Compile the server:
```
tunnel-server$ cd dnstt-server
tunnel-server$ go build
```

First you need to generate the server keypair that will be used to
authenticate the server and encrypt the tunnel.
```
tunnel-server$ ./dnstt-server -gen-key -privkey-file server.key -pubkey-file server.pub
privkey written to server.key
pubkey  written to server.pub
```

Run the server. You need to provide an address that will listen for UDP
DNS packets (`:5300`), the private key file (`server.key`), the root of
the DNS zone (`t.example.com`), and a TCP address to which incoming
tunnel streams will be forwarded (`127.0.0.1:8000`).
```
tunnel-server$ ./dnstt-server -udp :5300 -privkey-file server.key t.example.com 127.0.0.1:8000
```

The tunnel server needs to be able to receive packets on an external
port 53. You can have it listen on port 53 directly using `-udp :53`,
but that requires the program to run as root. It is better to run the
program as an ordinary user and have it listen on an unprivileged port
(`:5300` above), and port-forward port 53 to it. On Linux, use these
commands to forward external port 53 to localhost port 5300:
```
tunnel-server$ sudo iptables -I INPUT -p udp --dport 5300 -j ACCEPT
tunnel-server$ sudo iptables -t nat -I PREROUTING -i eth0 -p udp --dport 53 -j REDIRECT --to-ports 5300
tunnel-server$ sudo ip6tables -I INPUT -p udp --dport 5300 -j ACCEPT
tunnel-server$ sudo ip6tables -t nat -I PREROUTING -i eth0 -p udp --dport 53 -j REDIRECT --to-ports 5300
```

You need to also run something for the tunnel server to connect to. It
can be a proxy server or anything else. For testing, you can use an
Ncat listener:
```
tunnel-server$ ncat -l -k -v 127.0.0.1 8000
```


## Tunnel client setup

Compile the client:
```
tunnel-client$ cd dnstt-client
tunnel-client$ go build
```

Copy the server.pub file from the server to the client. You don't need
server.key on the client; leave it on the server.

Choose a public DoH or DoT resolver. There is a list of DoH resolvers
here:
 * https://github.com/curl/curl/wiki/DNS-over-HTTPS#publicly-available-servers

And DoT resolvers here:
 * https://dnsprivacy.org/wiki/display/DP/DNS+Privacy+Public+Resolvers#DNSPrivacyPublicResolvers-DNS-over-TLS%28DoT%29
 * https://dnsencryption.info/imc19-doe.html

To run the tunnel client using DoH, you need to provide the URL of the
DoH resolver (`https://doh.example/dns-query`), the server's public key
files (`server.pub`), the root of the DNS zone (`t.example.com`), and
the local TCP port that will receive connections and forward them
through the tunnel (`127.0.0.1:7000`):
```
tunnel-client$ ./dnstt-client -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
```

For DoT, it's the same, but use the `-dot` option instead:
```
tunnel-client$ ./dnstt-client -dot dot.example:853 -pubkey-file server.pub t.example.com 127.0.0.1:7000
```

Once the tunnel client is running, you can connect to the local end of
the tunnel, type something, and see it appear at the remote end.
```
tunnel-client$ ncat -v 127.0.0.1 7000
```

The client also has a plaintext UDP mode that can work through a
recursive resolver or directly to the tunnel server
(`-udp tns.example.com`), but it does not provide any covertness for the
tunnel and should only be used for testing.


## How to make a proxy

dnstt is only a tunnel; it's up to you what you want to connect to it.
You can make the tunnel work like an ordinary SOCKS or HTTP proxy by
having the tunnel server forward to a standard proxy server. There are
many ways to set it up; here are some examples.


### Ncat HTTP proxy

Ncat has a simple built-in HTTP/HTTPS proxy, good for testing. Be aware
that Ncat's proxy isn't intended for use by untrusted clients; it won't
prevent them from connecting to localhost ports on the tunnel server,
for example.

```
tunnel-server$ ncat -l -k --proxy-type http 127.0.0.1 8000
tunnel-server$ ./dnstt-server -udp :5300 -privkey-file server.key t.example.com 127.0.0.1:8000
```

On the client, have the tunnel client listen on 127.0.0.1:7000, and configure
your applications to use 127.0.0.1:7000 as an HTTP proxy.

```
tunnel-client$ ./dnstt-client -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
tunnel-client$ curl --proxy http://127.0.0.1:7000/ https://wtfismyip.com/text
```


### SSH SOCKS proxy

OpenSSH has a built-in SOCKS proxy, which makes it easy to add a SOCKS
proxy to a server that already has sshd installed.

On the server, make a localhost SSH connection, using the `-D` option to
open a SOCKS listener at port 8000. Then configure the tunnel server to
forward incoming connections to port 8000. Have the tunnel client listen
on its own local port 7000.

```
tunnel-server$ ssh -N -D 127.0.0.1:8000 -o NoHostAuthenticationForLocalhost=yes 127.0.0.1
# Enter the password of the local user on tunnel-server
tunnel-server$ ./dnstt-server -udp :5300 -privkey-file server.key t.example.com 127.0.0.1:8000
```

```
tunnel-client$ ./dnstt-client -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
tunnel-client$ curl --proxy socks5h://127.0.0.1:7000/ https://wtfismyip.com/text
```

The above configuration, by locating the SOCKS client port on the
server, makes a SOCKS proxy that can be used by anyone with access to
the DNS tunnel. Alternatively, you can make an SSH SOCKS proxy for your
own private use, with the SSH connection going through the tunnel and
the SOCKS client port being located at the client.

Let's assume you have the SSH details configured so that you can run
`ssh tunnel-server` on the tunnel client. Make sure `AllowTcpForwarding`
is set to `yes` (the default value) in sshd_config. Run the tunnel
server and have it forward directly to the SSH port.

```
tunnel-server$ ./dnstt-server -udp :5300 -privkey-file server.key t.example.com 127.0.0.1:22
```

Run the tunnel client with the local listening port at 127.0.0.1:7000.
The `HostKeyAlias` ssh option lets you connect to the SSH server as if
it were located at 127.0.0.1:8000. Replace `tunnel-server` with the
hostname or IP address of the SSH server.

```
tunnel-client$ ./dnstt-client -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:8000
tunnel-client$ ssh -N -D 127.0.0.1:7000 -o HostKeyAlias=tunnel-server -p 8000 127.0.0.1
tunnel-client$ curl --proxy socks5h://127.0.0.1:7000/ https://wtfismyip.com/text
```


### Tor bridge

You can run a Tor bridge on the tunnel server and tunnel the connection
to the bridge with dnstt, using dnstt as like a pluggable transport. The
Tor client provides a SOCKS interface that other programs can use. Let's
say your Tor bridge's ORPort is 9001.

```
tunnel-server$ ./dnstt-server -udp :5300 -privkey-file server.key t.example.com 127.0.0.1:9001
```

```
tunnel-client$ ./dnstt-client -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
```

Add a Bridge line to /etc/tor/torrc, or paste it into Tor Browser. You
can get `FINGERPRINT` from /var/lib/tor/fingerprint on the bridge.

```
Bridge 127.0.0.1:7000 FINGERPRINT
```

If you use a system tor, the client SOCKS port will be 127.0.0.1:9050.
If you use Tor Browser, it will be 127.0.0.1:9150.


## Covertness

Support for DoH and DoT is only to make it more difficult for a local
observer to see that a DNS tunnel is being used, not for the overall
security of the connection. There is a separate encryption layer inside
the tunnel that protects the contents of the tunnel from the resolver
itself.

The encryption of DoH or DoT prevents a network observer between the
tunnel client and the resolver from seeing the remote destination of the
tunnel. An observer can see that the tunnel client is connecting to a
resolver, but cannot see where the resolver is forwarding its queries.
An observer can probably infer, based on volume and other traffic
characteristics, that a tunnel is being used, though it cannot tell
where the remote end of the tunnel is, nor what the contents of the
tunnel are. If the tunnel client is not using DoH or DoT but instead UDP
(`-udp` option), then even an observer between the tunnel client and the
resolver can see that a tunnel is being used and where the remote end of
the tunnel is.

An observer between the resolver and the tunnel server (this includes
the resolver itself) can easily tell that a tunnel is being used and
where the remote end of the tunnel is, because there is no DoH or DoT
encryption at that point. This kind of observer still cannot read the
contents of the tunnel, because there is an additional layer of
end-to-end encryption between the tunnel client and the tunnel server.

An observer who watches what leaves the tunnel server will be able to
see anything that the tunnel server forwards to some other host (if the
tunnel server is acting as a proxy, for example), unless that data has
been separately encrypted before being sent through the tunnel.

dnstt-client disguises its TLS fingerprint using uTLS
(https://github.com/refraction-networking/utls). By default, a specific
TLS Client Hello fingerprint is selected randomly from a weighted
distribution. You can control the distribution of fingerprints (or
select a specific single fingerprint) using the `-utls` option. The
syntax of the option's argument is a comma-separated list of fingerprint
names, each optionally preceded by an integer weight and `*`.
```
$ ./dnstt-client -utls '3*Firefox,2*Chrome,1*iOS' ...
$ ./dnstt-client -utls Firefox ...
$ ./dnstt-client -utls random ...
```
Run `./dnstt-client -help` to see the available fingerprint names and
the default distribution. The `random` fingerprint is a randomized
fingerprint. The special value `none` disables uTLS and uses the native
crypto/tls fingerprint, which is less covert but likely to be compatible
with more servers.


## Encryption and authentication

The tunnel uses a Noise protocol (https://noiseprotocol.org/noise.html)
for end-to-end security between the tunnel client and tunnel server.
This protocol is independent of the DoH or DoT encryption between the
tunnel client and resolver. The specific protocol is Noise_NK_25519_ChaChaPoly_BLAKE2s
(https://noiseprotocol.org/noise.html#protocol-names-and-modifiers).
The NK handshake pattern authenticates the server but not the client.

The Noise layer is sandwiched between two other protocol layers: KCP
(https://github.com/xtaci/kcp-go) which creates a reliable stream on top
of unreliable datagrams, and smux (https://github.com/xtaci/smux) which
provides stream multiplexing and session features. An observer who can
see DNS messages, such as the intermediary resolver, will be able to see
the headers of the KCP layer, but not of the smux layer nor of the
streams that are inside. The model is similar to what you would get with
TLS or SSH over TCP: an observer can see TCP-level ACKs and sequence
numbers, but cannot read the stream data.

```
application data
smux
Noise
KCP
DNS messages
DoH / DoT / UDP DNS
```

When you run `dnstt-server -gen-key`, you can save the private and
public keys to a file using the `-privkey-file` and `-pubkey-file`
options. You can then load the keys later using `-privkey-file` on the
server and `-pubkey-file` on the client. Alternatively, you can deal
with the keys as literal hexadecimal strings rather than files. If you
run `dnstt-server -gen-key` without the `-privkey-file` and
`-pubkey-file` options, it will display the keys rather than save them
to files. You can then use the keys with `-privkey` on the server and
`-pubkey` on the client.
```
$ ./dnstt-server -gen-key
privkey 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
pubkey  0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff
$ ./dnstt-server -udp :5300 -privkey 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef t.example.com 127.0.0.1:8000
$ ./dnstt-client -dot dot.example:853 -pubkey 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff t.example.com 127.0.0.1:7000
```
If you run the server without `-privkey-file` or `-privkey`, it will
generate a temporary keypair and print the public key in the log. But
the key will be different the next time you restart the server, and you
will have to reconfigure clients.


## Payload sizes

In the client, the available space for user data per query depends on
the length of the domain name in use. Shorter domain names leave more
space for user data.

In the server, the available space for user data per response depends on
the maximum UDP payload size. The larger the UDP payload size, the more
space there is for user data. You want to use as large a UDP payload
size as possible, but not larger than what is supported by the resolver
you are using. Values above 1452 may cause IP fragmentation which can
reduce performance. You can control the maximum UDP payload size with
the `-mtu` option on the server. The default is 1232 bytes; this ought
to be supported by most resolvers that understand EDNS(0) (RFC 6891).
For maximum compatibility, set the maximum to 512, but know that doing
so will reduce downstream bandwidth.
```
$ ./dnstt-server -mtu 512 -doh https://doh.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
```

The client and server emit an "effective MTU" log line when starting up
that shows how much space is available for user data in each query or
response. For the server, there may be more space available in some
responses and less in others (depending on the size of the corresponding
query); the logged value is the minimum that is guaranteed to be
supported in any response.
