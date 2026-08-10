#!/bin/bash
 
# sudo update-ca-certificates -f
# remove certs
 

# ------------------------------------------------------------------
# Optional hostname setup
# ------------------------------------------------------------------
# Certificates are generated using the FQDN (`hostname -f`), so the hostname
# must be correct BEFORE generating certs. If it needs to change, do it here
# first, then re-run this script after the change takes effect.
# Note: If the hostname resolves via /etc/hosts, this script will also update
# the entry automatically when you set a new hostname.
# ------------------------------------------------------------------
currentHostname=$(hostname -f)
echo ""
echo "Current FQDN for this host: ${currentHostname}"
read -r -p "Is this hostname correct (certificates will be issued for it)? [y/N]: " confirmHostname
if [[ "${confirmHostname}" =~ ^[Yy]$ ]]; then
    echo "Hostname confirmed: ${currentHostname}"
else
    read -r -p "Enter the new hostname (FQDN, e.g. logstash.example.com): " newHostname
    if [[ -n "${newHostname}" ]]; then
        echo ""
        echo "New hostname: ${newHostname}"
        echo "Setting hostname to: ${newHostname}"
        sudo hostnamectl set-hostname "${newHostname}"
 
        # ------------------------------------------------------------------
        # Update /etc/hosts so the new hostname resolves locally.
        # This matters when the FQDN is resolved via /etc/hosts; keeping the
        # entry in sync avoids hostname/IP mismatches after the change.
        # ------------------------------------------------------------------
        newIP=$(hostname -I | awk '{print $1}')
        if [[ -n "${newIP}" ]]; then
            # Escape dots for safe regex matching against hostnames in /etc/hosts
            newHostnameEsc=$(printf '%s' "${newHostname}" | sed 's/\./\\\./g')
            currentHostnameEsc=$(printf '%s' "${currentHostname}" | sed 's/\./\\\./g')
            echo ""
            echo "Updating /etc/hosts with: ${newIP} ${newHostname} ${newHostname%%.*}"
            # Remove existing entries that reference the old or new hostname
            sudo sed -i -E "s/[[:space:]]+${newHostnameEsc}([[:space:]]|$)/ /g" /etc/hosts
            sudo sed -i -E "s/[[:space:]]+${currentHostnameEsc}([[:space:]]|$)/ /g" /etc/hosts
            # Append the new hostname entry (primary IP + FQDN + short name)
            echo "${newIP} ${newHostname} ${newHostname%%.*}" | sudo tee -a /etc/hosts > /dev/null
 
            # Show the updated file so the user can verify the change
            echo ""
            echo "Updated /etc/hosts. Here is the current file content:"
            more /etc/hosts
 
        else
            echo ""
            echo "Warning: could not determine the primary IP; /etc/hosts was not updated."
        fi
 
        read -r -p "Is a reboot required for the hostname change to take effect? [y/N]: " rebootRequired
        if [[ "${rebootRequired}" =~ ^[Yy]$ ]]; then
            echo "Rebooting now. After the system is back up, run this script again."
            sudo reboot
        else
            echo "No reboot requested."
        fi
        echo ""
        echo "Hostname change done. Re-run this script to generate the certificates"
        echo "once 'hostname -f' returns the new value."
        exit 0
    else
        echo "No new hostname entered; continuing with: ${currentHostname}"
    fi
fi
 
thisHostname=$(hostname -f)
thisIP=$(hostname -I | awk '{print $1}')
 
sudo mkdir -p /etc/logstash/certs
cd /etc/logstash/certs/
 
# This creates the internal CA private key and internal CA certificate.
# The `ca.key` should be kept secure, should not be copied to sender hosts, its the secret key and only used to sign certificates locally for Logstash/Agent.
# The `ca.crt` is the CA certificate that should be copied to sender hosts and used as the `certificate_authorities` value in the Elastic Agent enrollment command, and also used as the `ssl_certificate_authorities` value in the Logstash configuration.
sudo openssl genrsa -out ca.key 4096
sudo openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt
sudo openssl x509 -in ca.crt -noout -dates # Optional step to verify the CA certificate was created successfully and check its validity period
 
# Then generate and sign the Logstash certificate.
# The `logstash.crt` files should be copied to the Logstash host and used as `ssl_certificate` in the Logstash configuration respectively.
sudo openssl genrsa -out $(hostname -f).key 4096
sudo openssl req -new -key $(hostname -f).key -out $(hostname -f).csr -addext "subjectAltName=DNS:${thisHostname},IP:${thisIP}"
# Example of multiple SAN entries if needed: `-addext "subjectAltName=DNS:{thisHostname},IP:{thisIP},DNS:logstash.example.com,IP:192.168.1.100"`
sudo openssl x509 -req -in $(hostname -f).csr -CA ca.crt -CAkey ca.key -CAcreateserial -out $(hostname -f).crt -days 825 -sha256 -copy_extensions copy
sudo openssl x509 -in $(hostname -f).crt -noout -dates # Optional step to verify the Logstash certificate was created successfully and check its validity period
# The `logstash.csr` file can be deleted after the certificate is signed, its only used in the signing process and not needed for Logstash configuration.
# rm logstash.csr
 
# Convert the Logstash private key into PKCS#8 format, which is required by Logstash. PEM file is needed for some other API applications.
sudo openssl pkcs8 -topk8 -inform PEM -outform PEM -in $(hostname -f).key -out $(hostname -f).pkcs8.key -nocrypt
sudo cp /etc/logstash/certs/$(hostname -f).pkcs8.key /etc/logstash/certs/$(hostname -f).pkcs8.pem
sudo cmp /etc/logstash/certs/$(hostname -f).pkcs8.key /etc/logstash/certs/$(hostname -f).pkcs8.pem
# sudo chmod 600 /etc/logstash/certs/$(hostname -f).pkcs8.pem /etc/logstash/certs/$(hostname -f).pkcs8.key $(hostname -f).crt


# The `logstash.pkcs8.key` file should be used as the `ssl_key` value in the Logstash configuration instead of `logstash.key`, as Logstash requires the private key to be in PKCS#8 format. The original `logstash.key` file can be deleted after conversion.
# rm logstash.key
 
# Files that should exist in the logstash/certs directory after running this script:
# - /etc/logstash/certs/ca.crt (the CA certificate to be copied to sender hosts and used as the `certificate_authorities` value in the Elastic Agent enrollment command, and also used as the `ssl_certificate_authorities` value in the Logstash configuration)
# - /etc/logstash/certs/logstash.crt (the Logstash certificate to be used as the `ssl_certificate` value in the Logstash configuration)
# - /etc/logstash/certs/logstash.pkcs8.key (the Logstash private key in PKCS#8 format to be used as the `ssl_key` value in the Logstash configuration)
# - /etc/logstash/certs/logstash.pkcs8.pem (the Logstash private pem key in PKCS#8 format)
 
# Script to run at the logstash server.
sudo chown -R root:logstash /etc/logstash/certs
sudo chmod 640 /etc/logstash/certs/*
ls -al /etc/logstash/certs

 
# Sender hosts do **not** need `logstash.key`, `logstash.pk8`, or `ca.key`. They only need the `ca.crt` file to verify the Logstash server's identity during the SSL/TLS handshake, and to establish a secure connection. The `ca.crt` file should be used as the `certificate_authorities` value in the Elastic Agent enrollment command, and also used as the `ssl_certificate_authorities` value in the Logstash input configuration on the sender hosts.
 
# Test command for sender hosts to verify the certificate is working correctly and the sender can establish a secure connection to Logstash:
# openssl s_client -connect <LOGSTASH_HOST>:5044 -CAfile /path/to/ca.crt
# curl -v --cacert /path/to/ca.crt https://<LOGSTASH_HOST>:8080
 
