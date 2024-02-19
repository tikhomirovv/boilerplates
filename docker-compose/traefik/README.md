# traefik

## Getting started

Copy `.env.example` file to `.env` file and change it accordingly.

### Create data folder

Create a volume for the Traefik data, This is defined as traefik_data.

```sh
sudo docker volume create traefik_data
```

### Network

Create a network for Traefik and the services it will work with

```sh
sudo docker network create traefik
```


### Start Docker Compose

traefik can now be started via:

```sh
sudo docker compose up -d
```

To stop the container:

```sh
sudo docker compose stop
```

## Usage

Example `docker-compose.yml`:

```yml
services:
    whoami:
        image: "traefik/whoami"
        container_name: "simple-service"
        labels:
            - "traefik.enable=true"
            - "traefik.http.routers.whoami.rule=Host(`whoami.example.com`)"
            - "traefik.http.routers.whoami.entrypoints=web,websecure"
            - "traefik.http.routers.whoami.tls.certresolver=production"
            # - "traefik.http.routers.whoami.tls.certresolver=staging" // test the creation of an SSL certificate
```

## Testing

To test the configuration, specify label `traefik.http.routers.<service>.tls.certresolver=staging`.
If everything is ok, you will need to delete the file in `certificatesresolvers.staging.acme.storage`.
