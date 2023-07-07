#! /bin/sh
# shellcheck disable=SC2181

set -x -o noglob
{
  data_dir=/etc/reverse_proxy/data
  acme_dir="$data_dir/.acme.sh"
  cert_dir="$data_dir/certs"
  config_file="/etc/reverse_proxy/config.json"

  acme() {
    "$acme_dir/acme.sh" --home "$acme_dir" "$@"
  }

  lock_file="/tmp/create_certs.lock"
  if [ -f "$lock_file" ]; then
    echo "create_certs already running"
    exit 0
  fi

  touch "$lock_file"

  trap 'rm "$lock_file"' EXIT
  num_domains=$(jq -e -r '.domains | length' "$config_file")
  if [ $? -ne 0 ] || [ "$num_domains" -lt 1 ]; then
    echo "No domains listed in the config"
    exit 1
  fi

  i=0
  while [ "$i" -lt "$num_domains" ]; do
    domain_json=$(jq -e ".domains[$i]" "$config_file")
    domain=$(echo "$domain_json" | jq -e -r '.name')
    # column 5 = created_at
    created_at=$(acme --list | awk '$1 == '"$domain"' {print $5}')
    if [ -z "$created_at" ]; then
      echo "Creating certificate for $domain"
      acme_domain_args=$(echo "$domain_json" | jq -e -r '[.name] + .aliases | map("-d " + .) | join(" ")')
      # shellcheck disable=SC2086
      acme --server letsencrypt --issue --stateless $acme_domain_args || exit 1

      echo "Certificate created! Copying it over to $cert_dir"
      acme --install-cert -d "$domain" \
      --cert-file "$cert_dir/$domain/cert.pem" \
      --key-file "$cert_dir/$domain/key.pem" \
      --fullchain-file "$cert_dir/$domain/fullchain.pem" \
      --reloadcmd "nginx -s reload || true" || exit 1
      ls -la "$cert_dir/$domain"
    fi

    i=$((i+1))
  done
  echo "The certificates have all been installed. Uninstalling the cron job"
  crontab -l | grep -v 'create_certs' | crontab -
# Redirect logs to process 1, so they show up in docker
} 1>/proc/1/fd/1 2>/proc/1/fd/2
