package main

import "strings"

// Well-known DNS-over-HTTPS resolvers, denied in PERMISSIVE mode (#154).
//
// Why: the proxy's DNS responder is sandy's DNS policy point — it redirects
// names to the proxy, refuses HTTPS/SVCB to keep SNI readable, and (with
// SANDY_EGRESS_LOG) the transparent listeners record what the agent actually
// reached. Permissive mode allows every public host, so a client could simply
// decline to use DNS: resolve over HTTPS against a public resolver on TCP/443
// and dial the answer itself. That does not widen reach (the internet is
// already open in permissive mode) but it defeats VISIBILITY — resolutions
// move off the path sandy observes, so the egress log's "what did this session
// reach" rollup goes incomplete — and it skips the proxy's resolve-then-check
// rebinding defence (the --internal topology still blocks a private
// destination at L3, so that half is defence in depth, not a breach).
//
// What is already closed without this list: on the --internal sidecar the
// proxy's listeners are the only route off the box, and UDP (so DoH over
// QUIC/HTTP-3, and DoT over UDP) is dropped at L3. An agent dialing a resolver
// IP directly (https://1.1.1.1/dns-query with no proxy) has no route at all.
// What the default path leaves open is a NAMED DoH provider: the name resolves
// to the proxy, the proxy reads it from SNI (or Host, or a CONNECT target) and
// dials it — which is exactly the decision point this list sits on, so one
// check covers the :443, :80 and CONNECT paths alike (and DoT via CONNECT to
// a listed name on :853).
//
// NOT covered: an IP-literal resolver reached through the proxy's own paths
// (an explicit CONNECT to 1.1.1.1:443, a Host header naming an IP) — a public
// IP is allowed in permissive mode, and a list of resolver ADDRESSES is a
// different, larger mechanism than this one.
//
// HONEST LIMIT, and it must stay documented rather than implied: this list is
// ENUMERABLE, NOT COMPLETE. Any host can serve DoH on 443, and a determined
// agent can stand one up. It raises the cost of accidental or lazy DNS-policy
// bypass by the wrong-but-not-evil agent sandy's threat model targets; it does
// not close the channel against an adversary. Strict mode is the real fix and
// needs no list: it already denies every resolver that is not allowlisted.
//
// Escape hatch: an explicit allowlist entry (SANDY_ALLOW_HOSTS) wins — someone
// who allowlists a DoH host has said what they want — so Policy.Egress checks
// the allowlist BEFORE this list. There is deliberately no separate
// SANDY_ALLOW_DOH key (maintainer decision on #154).
//
// Matching: an entry matches the name itself AND any subdomain of it
// ("cloudflare-dns.com" also covers "mozilla.cloudflare-dns.com",
// "family.cloudflare-dns.com", ...). Every entry is therefore a name that is
// resolver infrastructure in its entirety — never a parent domain that also
// hosts ordinary sites (so "dns.mullvad.net", never "mullvad.net"; "dns.google",
// which Google uses for nothing else).
var dohProviders = []string{
	// Google Public DNS
	"dns.google",
	"dns.google.com",
	// Cloudflare (cloudflare-dns.com is DoH-only; covers mozilla., security.,
	// family., 1dot1dot1dot1., chrome. ...)
	"cloudflare-dns.com",
	"one.one.one.one",
	// Quad9
	"dns.quad9.net",
	"dns9.quad9.net",
	"dns10.quad9.net",
	"dns11.quad9.net",
	"dns12.quad9.net",
	// Cisco OpenDNS
	"doh.opendns.com",
	"doh.familyshield.opendns.com",
	// NextDNS
	"dns.nextdns.io",
	// CleanBrowsing
	"doh.cleanbrowsing.org",
	// AdGuard DNS
	"dns.adguard.com",
	"dns.adguard-dns.com",
	"unfiltered.adguard-dns.com",
	"family.adguard-dns.com",
	// DNS.SB
	"doh.dns.sb",
	// Mullvad
	"dns.mullvad.net",
	// Control D
	"dns.controld.com",
	"freedns.controld.com",
	// dns0.eu (zero., kids., open. ...)
	"dns0.eu",
	// Alibaba, Tencent/DNSPod
	"dns.alidns.com",
	"doh.pub",
	// LibreDNS, Applied Privacy
	"doh.libredns.gr",
	"doh.applied-privacy.net",
}

// isDoHProvider reports whether an already-normalized, non-IP hostname is (or
// is a subdomain of) a well-known DoH resolver. The caller must normalize
// first (normalizeHost lower-cases and rejects garbage), so a plain suffix
// comparison is exact: "evilcloudflare-dns.com" does not match, because the
// subdomain test requires the dot boundary.
func isDoHProvider(h string) bool {
	for _, d := range dohProviders {
		if h == d || strings.HasSuffix(h, "."+d) {
			return true
		}
	}
	return false
}
