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

And then when you run reverse-proxy it will:

1. Automatically generate a nginx.conf file which serves https://example.com and https://www.example.com and forwards the traffic to http://app:8000
1. Automatically generate a SSL certificate for example.com and www.example.com
1. Automatically renew the SSL certificate every ~60 days
1. Redirect HTTP traffic to HTTPS

So. that's basically it :)

# Running the reverse-proxy using Docker-Compose

The container needs 3 things to work properly

1. The config.json file
1. A mounted volume to /etc/reverse_proxy/data so that SSL certificates are persisted (otherwise you \_will\* get rate-limited by LetsEncrypt)
1. A docker network to forward the traffic to your other docker containers

Here's an example docker-compose file you can use to start the service properly:

```yml
services:
  reverse-proxy:
    image:
    build:
      context: .
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

Then, you can create your services (even if they're in a different docker-compose.yml file). You just need to specify the network name to match

# Advanced configuration

Since this is just nginx, you can customize the nginx.conf file to meet your exact needs

First, run the docker container, which will generate the nginx.conf (even when running locally). Use a bind mount for the volume so it's easy to access the data. For example: `docker run --rm -v ./my_local_folder:/etc/reverse_proxy` (make sure to add a config.json with the correct data to my_local_folder).

Then, make the custom changes to my_local_folder/nginx.conf that you want to.

Finally, tell the reverse-proxy to prefer your nginx.conf instead:
`docker run --rm -v ./my_local_folder:/etc/reverse_proxy -e SKIP_WRITE_NGINX_CONF=1`
The `SKIP_WRITE_NGINX_CONF` prevents the code from re-creating nginx.conf from the config
