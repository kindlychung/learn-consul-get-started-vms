#!/usr/bin/env bash

export DATACENTER=${DATACENTER:-"dc1"}
export DOMAIN=${DOMAIN:-"consul"}
export CONSUL_DATA_DIR=${CONSUL_DATA_DIR:-"/etc/consul/data"}
export CONSUL_CONFIG_DIR=${CONSUL_CONFIG_DIR:-"/etc/consul/config"}

export DNS_RECURSOR=${DNS_RECURSOR:-"1.1.1.1"}
export HTTPS_PORT=${HTTPS_PORT:-"8443"}
export DNS_PORT=${DNS_PORT:-"8600"}

export PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)

echo "Clean existing configuration"
rm -rf ${CONSUL_DATA_DIR}/
rm -rf ${CONSUL_CONFIG_DIR}/

echo "Generate Consul folders"
mkdir -p ${CONSUL_CONFIG_DIR} && mkdir -p ${CONSUL_DATA_DIR}

STAT=$?

if [ ${STAT} -ne 0 ]; then
	echo "Folder creation failed, exiting."
	exit 1
fi

cd ${CONSUL_CONFIG_DIR}

echo "Generate agent configuration - agent-server-secure.hcl"
tee ${CONSUL_CONFIG_DIR}/agent-server-secure.hcl >/dev/null <<EOF
# agent-server-secure.hcl
# Data Persistence
data_dir = "${CONSUL_DATA_DIR}"
# Logging
log_level = "DEBUG"
# Enable service mesh
connect {
  enabled = true
}
# Addresses and ports
addresses {
  grpc = "127.0.0.1"
  https = "0.0.0.0"
  dns = "0.0.0.0"
}
ports {
  grpc_tls  = 8502
  http  = 8500
  https = ${HTTPS_PORT}
  dns   = ${DNS_PORT}
}
# DNS recursors
recursors = ["${DNS_RECURSOR}"]
# Disable script checks
enable_script_checks = false
# Enable local script checks
enable_local_script_checks = true
EOF

echo "Generate server configuration - agent-server-specific.hcl"
tee ${CONSUL_CONFIG_DIR}/agent-server-specific.hcl >/dev/null <<EOF
## Server specific configuration for ${DATACENTER}
server = true
bootstrap_expect = 1
datacenter = "${DATACENTER}"
client_addr = "0.0.0.0"
advertise_addr = "$PUBLIC_IP"
## UI configuration (1.9+)
ui_config {
  enabled = true
}
EOF

echo "Generate gossip encryption key configuration - agent-gossip-encryption.hcl"
if [[ ! -f ${CONSUL_CONFIG_DIR}/agent-gossip-encryption.hcl ]]; then
	echo encrypt = \"$(consul keygen)\" >${CONSUL_CONFIG_DIR}/agent-gossip-encryption.hcl
fi

# echo "Create CA for Consul datacenter"
# consul tls ca create -domain=${DOMAIN}
# echo "Create server Certificate and key pair"
# consul tls cert create -server -domain ${DOMAIN} -dc=${DATACENTER}

echo "Generate TLS configuration - agent-server-tls.hcl"
tee ${CONSUL_CONFIG_DIR}/agent-server-tls.hcl >/dev/null <<EOF
# TLS Encryption (requires cert files to be present on the server nodes)
tls {
  defaults {
    ca_file   = "${CONSUL_CONFIG_DIR}/consul-ca.pem"
    cert_file = "${CONSUL_CONFIG_DIR}/server.pem"
    key_file  = "${CONSUL_CONFIG_DIR}/server-key.pem"
    verify_outgoing        = false
    verify_incoming        = false
  }
  https {
    verify_incoming        = false
  }
  internal_rpc {
    verify_server_hostname = false
  }
}
EOF

echo "Generate ACL configuration - agent-server-acl.hcl"
tee ${CONSUL_CONFIG_DIR}/agent-server-acl.hcl >/dev/null <<EOF
## ACL configuration
acl = {
  enabled = true
  default_policy = "allow"
  enable_token_persistence = true
  enable_token_replication = true
  down_policy = "extend-cache"
}
EOF

echo "Validate configuration"
consul validate ${CONSUL_CONFIG_DIR}

STAT=$?

if [ ${STAT} -ne 0 ]; then
	echo "Configuration invalid. Exiting."
	exit 1
fi
