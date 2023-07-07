## Local debugging

```sh
sudo docker build -t reverse-proxy .
sudo docker run --rm -it -v ./config.json:/etc/reverse_proxy/config.json:ro -v ./data:/etc/reverse_proxy/data --entrypoint /bin/sh reverse-proxy
```

## Run locally

```sh
sudo docker build -t reverse-proxy .
sudo docker run --rm -p 8000:80 -p 8443:443 -v ./config.json:/etc/reverse_proxy/config.json:ro -v ./data:/etc/reverse_proxy/data reverse-proxy
```
