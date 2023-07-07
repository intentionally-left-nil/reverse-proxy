#! /bin/sh

init_fn() {
  data_dir=/etc/reverse_proxy/data
  if [ ! -d "$data_dir" ]; then 
    echo "$data_dir does not exist. Did you forget to mount the volume?"
    exit 1
  fi

  cp "$data_dir/nginx.conf" /etc/nginx/conf.d/default.conf || exit 1
}

(set -u; init_fn) || exit $?
