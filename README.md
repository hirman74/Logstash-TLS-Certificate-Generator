# Logstash-TLS-Certificate-Generator

This script generates the TLS/SSL certificates needed to secure the connection
to be used by **Elastic Agent** and **Logstash** over HTTPS.

It creates:

- An **internal Certificate Authority (CA)** — used to sign the Logstash certificate locally.
- A **Logstash server certificate** signed by that CA, including the host FQDN and IP as SANs.
- A **PKCS#8-format private key**, which Logstash requires for `ssl_key`.



---

## Prerequisites

- A Linux host (RHEL/CentOS/Ubuntu-style) with `sudo` access.
- `openssl` installed.
- The Logstash user/group exists on the system (the script sets ownership to
  `root:logstash`).
- The hostname is **set correctly before running the script** — certificates are
  issued for the machine's FQDN (`hostname -f`).

---

## Hostname setup

Certificates are generated using the FQDN (`hostname -f`), so the hostname **must
be correct before** generating certs.

When you run the script it will:

1. Display the current FQDN and ask you to confirm it.
2. If you reject it, prompt you for a new hostname (e.g. `logstash.example.com`).
3. Apply the new hostname with `hostnamectl set-hostname`.
4. Automatically update `/etc/hosts` (adding `IP FQDN shortname` and removing
   stale entries referencing the old or new hostname).
5. Optionally reboot if you confirm it's required.

> If the hostname resolves via `/etc/hosts`, the script keeps that entry in sync to
> avoid hostname/IP mismatches.
>
> After a hostname change, **re-run the script** once `hostname -f` returns the new
> value.

---

## What the script does

| Step | Command (abridged) | Purpose |
|------|--------------------|---------|
| 1 | `openssl genrsa -out ca.key 4096` | Create the internal CA **private key** (keep secure — never ship to sender hosts). |
| 2 | `openssl req -x509 ... -out ca.crt` | Create the internal **CA certificate** (3650 days / ~10 years). |
| 3 | `openssl x509 -in ca.crt -noout -dates` | Verify the CA certificate and its validity period. |
| 4 | `openssl genrsa -out <fqdn>.key 4096` | Create the Logstash private key. |
| 5 | `openssl req -new ... -addext "subjectAltName=DNS:<fqdn>,IP:<ip>"` | Create the CSR with SANs for the host FQDN and IP. |
| 6 | `openssl x509 -req -in <fqdn>.csr -CA ca.crt -CAkey ca.key ... -days 825` | Sign the Logstash certificate with the internal CA. |
| 7 | `openssl x509 -in <fqdn>.crt -noout -dates` | Verify the Logstash certificate and its validity period. |
| 8 | `openssl pkcs8 -topk8 ... -out <fqdn>.pkcs8.key -nocrypt` | Convert the private key to **PKCS#8** format (required by Logstash). |
| 9 | `cp <fqdn>.pkcs8.key <fqdn>.pkcs8.pem` + `cmp` | Create a PEM copy and confirm the files match. |
| 10 | `chown -R root:logstash` / `chmod 640` | Apply ownership and permissions so Logstash can read the certs. |

### Multi-SAN example

To add more hostnames/IPs to the certificate, extend the `-addext` value, e.g.:

```bash
-addext "subjectAltName=DNS:logstash.example.com,IP:192.168.1.100,DNS:logstash.example.net,IP:192.168.1.101"
```

---

## Files generated

All files are created in **`/etc/logstash/certs/`**.

| File | Description | Where it goes |
|------|-------------|---------------|
| `ca.key` | Internal CA **private key** — the secret. Never copy to sender hosts. | Keep only on the Logstash host (used to sign certs locally). |
| `ca.crt` | CA **certificate**. | Copy to **sender hosts**; used as `certificate_authorities` in Elastic Agent enrollment and as `ssl_certificate_authorities` in Logstash config. |
| `<fqdn>.crt` | Logstash server **certificate**. | Logstash host — used as `ssl_certificate`. |
| `<fqdn>.key` | Logstash private key (original PEM). | Logstash host. Can be deleted after PKCS#8 conversion. |
| `<fqdn>.csr` | Certificate signing request. | Temporary — can be deleted after signing. |
| `<fqdn>.pkcs8.key` | Logstash private key in **PKCS#8** format. | Logstash host — used as `ssl_key`. |
| `<fqdn>.pkcs8.pem` | PKCS#8 key copied with a `.pem` extension (for apps that require PEM). | Logstash host. |

> **Sender hosts do NOT need** `ca.key`, `<fqdn>.key`, or `<fqdn>.pkcs8.key`.
> They only need **`ca.crt`** to verify the Logstash server's identity during the
> TLS handshake.

---

## Logstash configuration example

```ruby
input {
  beats {
    port => 5044
    ssl => true
    ssl_certificate => "/etc/logstash/certs/logstash.crt"
    ssl_key => "/etc/logstash/certs/logstash.pkcs8.key"
    ssl_certificate_authorities => "/etc/logstash/certs/ca.crt"
  }
  http {
    host => "0.0.0.0"
    port => 8080
    ssl => true
    ssl_certificate => "/etc/logstash/certs/logstash.crt"
    ssl_key => "/etc/logstash/certs/logstash.pkcs8.key"
    ssl_certificate_authorities => "/etc/logstash/certs/ca.crt"
  }
}
```

> Use `logstash.pkcs8.key` for `ssl_key` (not `logstash.key`) — **Logstash requires
> the private key in PKCS#8 format**.

---

## Sender host verification

From any sender host that has the `ca.crt`:

```bash
# Verify TLS handshake to the Logstash beats input
openssl s_client -connect <LOGSTASH_HOST>:5044 -CAfile /path/to/ca.crt

# Verify HTTPS to the Logstash http input
curl -v --cacert /path/to/ca.crt https://<LOGSTASH_HOST>:8080
```

Use `ca.crt` as the `certificate_authorities` value in the Elastic Agent
enrollment command.

---

## Usage

```bash
# Make the script executable (once)
chmod +x KeyGen.sh

# Run it with sudo
sudo ./KeyGen.sh
```

---

## Important security notes

- Keep **`ca.key`** secure at all times — it is the signing secret for your
  internal PKI. Anyone with it can issue trusted certificates for your Logstash.
- If the hostname changes **after** certs are generated, the certificate's SANs
  will no longer match and TLS validation will fail — re-run the script.
- The Logstash certificate is valid for **825 days**; the CA for **3650 days**.
  Plan for renewal before expiry.
- [Rotate SSL/TLS CA certificates](https://www.elastic.co/docs/reference/fleet/certificates-rotation)
- [Configure SSL/TLS for the Logstash output](https://www.elastic.co/docs/reference/fleet/secure-logstash-connections)
