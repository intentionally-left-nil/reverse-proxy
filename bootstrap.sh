#! /bin/sh
# shellcheck disable=SC2181

bootstrap_fn() {
  set -x
  data_dir=/etc/reverse_proxy/data
  acme_dir="$data_dir/.acme.sh"
  cert_dir="$data_dir/certs"
  config_file="/etc/reverse_proxy/config.json"
  nginx_file="/etc/reverse_proxy/nginx.conf"
  acme="$acme_dir/acme.sh"

  if [ ! -d "$data_dir" ]; then 
    echo "$data_dir does not exist. Did you forget to mount the volume?"
    exit 1
  fi

  # First, validate the config file
  if [ ! -f "$config_file" ]; then
    echo "Missing $config_file. Did you forget to mount the config file?"
    exit 1
  fi

  num_domains=$(jq -e -r '.domains | length' "$config_file")
  if [ $? -ne 0 ] || [ "$num_domains" -lt 1 ]; then
    echo "No domains listed in the config"
    exit 1
  fi

  # Install acme.sh with the email in the config, ensure the account_thumbprint
  if [ ! -d "$acme_dir" ]; then
    email=$(jq -e -r '.email' "$config_file")
    if [ $? -ne 0 ]; then
      echo "$config_file is missing the email to use when registering the SSL certificates"
      exit 1
    fi
    echo "Installing acme.sh"
    (cd /opt/acme.sh && ./acme.sh --install --home "$acme_dir" --accountemail "$email") || exit 1
  fi

  account_thumbprint=$(cat "$data_dir/account_thumbprint")
  if [ $? -ne 0 ] || [ -z "$account_thumbprint" ]; then
    echo "Registering account with LetsEncrypt"
    le_response=$("$acme" --home "$acme_dir" --server letsencrypt --register-account)
    if [ $? -ne 0 ]; then
      echo "Failed to register the acme account"
      echo "$le_response"
      exit 1
    fi
    account_thumbprint=$(echo "$le_response" | grep ACCOUNT_THUMBPRINT | sed "s/.*ACCOUNT_THUMBPRINT='\(.*\)'/\1/")
    echo "$account_thumbprint" > "$data_dir/account_thumbprint" || exit 1
  fi

  mkdir -p "$cert_dir" || exit 1

  # Create dhparams
  if [ ! -f "$cert_dir/dhparams.pem" ]; then
    openssl dhparam -dsaparam -out "$cert_dir/dhparams.pem" 4096 || exit 1
  fi

  # Create the self-signed certificates
  if [ ! -f "$cert_dir/self_signed_cert.pem" ]; then
    echo "Creating the self-signed certificate"

    mkdir -p "$cert_dir" || exit 1
    subject=$(jq -e -r '.domains[0].name' "$config_file")
    alt_names=$(jq -e -r '.domains | map([.name] + .aliases) | flatten | map("DNS:" + .) | join(",")' "$config_file")
    echo "subject: $subject"
    echo "alt_names: $alt_names"
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
    -keyout "$cert_dir/self_signed_key.pem" \
    -out "$cert_dir/self_signed_cert.pem" \
    -subj "/CN=$subject" \
    -addext "subjectAltName=$alt_names" || exit 1
  fi

  domains=$(jq -e -r '.domains[].name' "$config_file")
  # Note that this script assumes that the config.json is trusted input
  # and the domain doesn't have e.g. ../../ in it
  for domain in $domains; do
    mkdir -p "$cert_dir/$domain" || exit 1
    if [ ! -f "$cert_dir/$domain/cert.pem" ]; then
        # This is the first time running the production server, and the prod certs
        # haven't been generated yet
        # Run the server with a self-signed certificate to solve the chicken/egg
        # problem (since generating the cert requires nginx to be running)
        cp "$cert_dir/self_signed_cert.pem" "$cert_dir/$domain/cert.pem" || exit 1
        cp "$cert_dir/self_signed_cert.pem" "$cert_dir/$domain/fullchain.pem" || exit 1
        cp "$cert_dir/self_signed_key.pem" "$cert_dir/$domain/key.pem" || exit 1
    fi
  done

  # Update the generated nginx.conf template
  cat /dev/null > "$data_dir/nginx_generated.conf"
  i=0
  while [ "$i" -lt "$num_domains" ]; do
    domain_json=$(jq -e ".domains[$i]" "$config_file")
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
      # Use docker's resolver for name resolution, see https://prds98.com/post/49/
      # Originally this tried to also use 9.9.9.9 as a backup, but the resolver directive
      # is in round-robin fashion, leading to intermittent failures resolving internal routes
      # https://nginx.org/en/docs/http/ngx_http_core_module.html#resolver
      # The TL;DR: is that this config can only be run under a docker container, and would need tweaking to run somewhere else
      resolver 127.0.0.11 valid=30s ipv6=off;
      resolver_timeout 10s;

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
        # The DNS record might not exist at startup time
        # So use a variable to prevent nginx from failing to start
        set \$proxy_dest_$i $dest;
        proxy_pass \$proxy_dest_$i;
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
        return 301 https://\$host\$request_uri;
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

  if [ ! -f "$nginx_file" ] || [ ! "${SKIP_WRITE_NGINX_CONF:-}" = "1" ]; then
    echo "Writing nginx_generated.conf to $nginx_file"
    cp "$data_dir/nginx_generated.conf" "$nginx_file"
  else
    echo "Skipping writing nginx_generated.conf"
  fi
}

if [ "${SKIP_BOOTSTRAP:-}" = "1" ]; then
  echo "skipping bootstrap stage because BOOTSTRAP environment variable (${BOOTSTRAP:-unset}) is not 1"
else
  # Run everything in a subshell so we don't pollute the global scope
  (set -u; bootstrap_fn) || exit $?
fi
