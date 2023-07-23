#! /bin/sh

init_fn() {
  if [ "${DEBUG:-}" = '1' ]; then
    set -x
  fi
  data_dir=/etc/reverse_proxy/data
  acme_dir="$data_dir/.acme.sh"
  nginx_file="/etc/reverse_proxy/nginx.conf"
  acme() {
    "$acme_dir/acme.sh" --home "$acme_dir" "$@"
  }

  if [ ! -d "$data_dir" ]; then 
    echo "$data_dir does not exist. Did you forget to mount the volume?"
    exit 1
  fi
  cp "$nginx_file" /etc/nginx/conf.d/default.conf || exit 1
  # Add the cron job to create the initial certificates
  (crontab -l; echo "* * * * * /etc/reverse_proxy/create_certs.sh") | sort -u | crontab -
  # Add the cron job to renew the certificates
  acme --install-cronjob
}

(set -u; init_fn) || exit $?

# Start crond in the background
crond &
