# Nginx + Acme + LetsEncrypt = Reverse Proxy

All you have to do: Provide a config.json that looks like this:

```json
{
  "email": "myemail@example.com",
  "domains": [
    {
      "name": "example.com",
      "aliases": ["www.example.com"],
      "dest": "http://app:8000"
    }
  ]
}
```

and then start the service like so:

```yml
services:
  reverse-proxy:
    image: ghcr.io/intentionally-left-nil/reverse-proxy:latest
    volumes:
      - ./config.json:/etc/reverse_proxy/config.json
      - reverse-proxy-data:/etc/reverse_proxy/data
    ports:
      - 80:80
      - 443:443
    networks:
      - www

volumes:
  reverse-proxy-data:
networks:
  www:
    name: reverse-proxy
```

And then when you run reverse-proxy it will:

1. Automatically generate a nginx.conf file which serves https://example.com and https://www.example.com and forwards the traffic to http://app:8000
1. Automatically generate a SSL certificate for example.com and www.example.com
1. Automatically renew the SSL certificate every ~60 days
1. Redirect HTTP traffic to HTTPS

So. that's basically it :)

# Environment variables

- `SKIP_BOOTSTRAP=1` means don't create any config files, or self-signed certs
- `SKIP_CREATE_CERTS=1` means don't call acme --issue to generate the SSL certificates
- `SKIP_WRITE_NGINX_CONF=1` means that /etc/reverse_proxy/nginx.conf is not overriden during the config process
- `DEBUG=1` means add verbose logging (set -x) to figure out what's going wrong

# Advanced configuration

Since this is just nginx, you can customize the nginx.conf file to meet your exact needs

First, run the docker container, which will generate the nginx.conf (even when running locally). Use a bind mount for the volume so it's easy to access the data. For example: `docker run --rm -v ./my_local_folder:/etc/reverse_proxy` (make sure to add a config.json with the correct data to my_local_folder).

Then, make the custom changes to my_local_folder/nginx.conf that you want to.

Finally, merge these config lines with your existing docker-compose.yml file

```yml
services:
  reverse-proxy:
    volumes:
      - ./my_nginx.conf:/etc/reverse_proxy/nginx.conf
    environment:
      - SKIP_WRITE_NGINX_CONF=1
```

The `SKIP_WRITE_NGINX_CONF` prevents the code from re-creating nginx.conf from the config

# How it works

This uses the [stateless](https://github.com/acmesh-official/acme.sh/wiki/Stateless-Mode) mode to generate a SSL certificate. Basically, you do a one-time registration flow, which generates a token. Then, you just need to handle the URL `<your_domain>/.well-known/acme-challenge/<random>` and return back `<token>.<random>`.

```
location ~ ^/\.well-known/acme-challenge/([-_a-zA-Z0-9]+)\$ {
        default_type text/plain;
        return 200 "\$1.$account_thumbprint";
      }
```

So, all of the devops revolves around making this happen. Some hoops to jump through include:

1. To return the value you need a working webserver. However, you can't run nginx if there are certs missing. So, the code generates a temporary self-signed certificate so that nginx will start
1. You need to start nginx before running the certs, so the cert generation is done as a cron job
1. acme.sh uses a different cron job to renew the certs, so we need to make sure nginx is running
1. To proxy_pass the data to the remote host, the DNS records need to be set. However, if you just start the reverse proxy, then the DNS entries aren't there. So we use the `set $variable` nginx trick to get around it

# Testing

1. cd [./test](./test/)
1. sudo docker compose up --build
1. curl -k https://localhost
