# n8n

## Getting started

Copy `.env.example` file to `.env` file and change it accordingly.

### Create data folder

Create the Docker volume that's defined as n8n_data. n8n will save the database file from SQLite and the encryption key in this volume.

```sh
sudo docker volume create n8n_data
```

Create a volume for the Traefik data, This is defined as traefik_data.

```sh
sudo docker volume create traefik_data
```

### Start Docker Compose

n8n can now be started via:

```sh
sudo docker compose up -d
```

To stop the container:

```sh
sudo docker compose stop
```

Documentation: https://docs.n8n.io/hosting/installation/server-setups/docker-compose/
