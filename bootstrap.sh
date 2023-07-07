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

# Install acme.sh with the email in the config, ensure the account_thumbprint
if [ ! -d "$acme_dir" ]; then
  email=$(jqc -e -r '.email')
  if [ $? -ne 0 ]; then
    echo "$config_file is missing the email to use when registering the SSL certificates"
    exit 1
  fi
  echo "Installing acme.sh"
  (cd /opt/acme.sh && ./acme.sh --install --home "$acme_dir" --accountemail "$email") || exit 1
fi

account_thumbprint=$(jqc -e -r '.account_thumbprint')
if [ $? -ne 0 ] || [ -z "$account_thumbprint" ]; then
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


# Create dhparams
if [ ! -f "$cert_dir/dhparams.pem" ]; then
  openssl dhparam -dsaparam -out "$cert_dir/dhparams.pem" 4096 || exit 1
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

# Update the generated nginx.conf template
cat /dev/null > "$data_dir/nginx_generated.conf"
i=0
while [ "$i" -lt "$num_domains" ]; do
  domain_json=$(jqc -e ".domains[$i]")
  domain=$(echo "$domain_json" | jq -e -r '.name')
  if [ $? -ne 0 ]; then
    echo "Failed to get the name for $domain_json"
    exit 1
  fi
  server_name=$(echo "$domain_json" | jq -e -r '[.name] + .aliases | join(" ")')
  if [ $? -ne 0 ]; then
    echo "Failed to get the server names for $domain_json"
    exit 1
  fi
  dest=$(echo "$domain_json" | jq -e -r '.dest')
  if [ $? -ne 0 ]; then
    echo "Failed to get the dest for $domain_json"
    exit 1
  fi
  cat << EOF >> "$data_dir/nginx_generated.conf"
  server {
    server_name $server_name;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    ssl_certificate $cert_dir/$domain/fullchain.pem;
    ssl_certificate_key $cert_dir/$domain/key.pem;
    ssl_trusted_certificate $cert_dir/$domain/fullchain.pem;
    ssl_dhparam $cert_dir/dhparams.pem;

    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1440m;
    ssl_session_tickets off;
    ssl_prefer_server_ciphers on;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:MozSSL:10m;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 9.9.9.9 8.8.8.8;
    resolver_timeout 5s;

    location ~ ^/\.well-known/acme-challenge/([-_a-zA-Z0-9]+)\$ {
      default_type text/plain;
      return 200 "\$1.$account_thumbprint";
    }

    location / {
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_http_version 1.1;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Host \$host;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header Host \$host;
      proxy_pass $dest;
    }
  }

  server {
    server_name $server_name;
    listen 80;
    listen [::]:80;

    location ~ ^/\.well-known/acme-challenge/([-_a-zA-Z0-9]+)\$ {
      default_type text/plain;
      return 200 "\$1.$account_thumbprint";
    }
    location / {
      return 301 https://$domain\$request_uri;
    }
  }
EOF
  i=$((i+1))
done
cat << EOF >> "$data_dir/nginx_generated.conf"
# Sinkhole server, if the host doesn't match any of the known domains. Kills the connection
server {
  server_name _;
  listen 80 default_server deferred;
  listen [::]:80 default_server deferred;
  return 444;
}
EOF
