#! /bin/sh
# shellcheck disable=SC2181

data_dir=/etc/reverse_proxy
acme_dir="$data_dir/.acme.sh"
cert_dir="$data_dir/certs"
config_file="$data_dir/config.json"
acme="$acme_dir/acme.sh"

# First, validate the config file
if [ ! -f "$config_file" ]; then
  echo "Missing $config_file. Did you forget to mount the data volume?"
  exit 1
fi

config=$(cat "$config_file")
alias jqc='echo "$config" | jq'

num_domains=$(jqc -e -r '.domains | length')
if [ $? -ne 0 ] || [ "$num_domains" -lt 1 ]; then
  echo "No domains listed in the config"
  exit 1
fi

# Install acme.sh with the email in the config
if [ ! -d "$acme_dir" ]; then
  email=$(jqc -e -r '.email')
  if [ $? -ne 0 ]; then
    echo "$config_file is missing the email to use when registering the SSL certificates"
    exit 1
  fi
  echo "Installing acme.sh"
  (cd /opt/acme.sh && ./acme.sh --install --home "$acme_dir" --accountemail "$email") || exit 1
fi

if ! jqc -e '.account_thumbprint' >/dev/null; then
  echo "Registering account with LetsEncrypt"
  le_response=$("$acme" --home "$acme_dir" --server letsencrypt --register-account)
  if [ $? -ne 0 ]; then
    echo "Failed to register the acme account"
    echo "$le_response"
    exit 1
  fi
  account_thumbprint=$(echo "$le_response" | grep ACCOUNT_THUMBPRINT | sed "s/.*ACCOUNT_THUMBPRINT='\(.*\)'/\1/")
  # shellcheck disable=SC2016
  config=$(jqc -e --arg x "$account_thumbprint" '.account_thumbprint=$x')
  if [ $? -ne 0 ]; then
    echo "Failed to register the account thumbprint"
    exit 1
  fi
  echo "$config" > "$config_file"
fi

# Create the self-signed certificates
if [ ! -f "$cert_dir/self_signed_cert.pem" ]; then
  echo "Creating the self-signed certificate"

  mkdir -p "$cert_dir" || exit 1
  subject=$(jqc -e -r '.domains[0].name')
  alt_names=$(jqc -e -r '.domains | map([.name] + .aliases) | flatten | map("DNS:" + .) | join(",")')
  echo "subject: $subject"
  echo "alt_names: $alt_names"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$cert_dir/self_signed_key.pem" \
  -out "$cert_dir/self_signed_cert.pem" \
  -subj "/CN=$subject" \
  -addext "subjectAltName=$alt_names" || exit 1

  domains=$(jqc -e -r '.domains[].name')
  # Note that this script assumes that the config.json is trusted input
  # and the domain doesn't have e.g. ../../ in it
  for domain in $domains; do
    mkdir -p "$cert_dir/$domain" || exit 1
    if [ ! -f "$cert_dir/$domain/cert.pem" ]; then
        # This is the first time running the production server, and the prod certs
        # haven't been generated yet
        # Run the server with a self-signed certificate to solve the chicken/egg
        # problem (since generating the cert requires nginx to be running)
        ln -s "$cert_dir/self_signed_cert.pem" "$cert_dir/$domain/cert.pem" || exit 1
        ln -s "$cert_dir/self_signed_cert.pem" "$cert_dir/$domain/fullchain.pem" || exit 1
        ln -s "$cert_dir/self_signed_key.pem" "$cert_dir/$domain/key.pem" || exit 1
    fi
  done
fi
