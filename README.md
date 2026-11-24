# Local development pipeline

This repository helps you setting up a running local pipeline using Docker containers with docker compose. 

### Containers:

- Dependency Track (port 8080)
- Sonarqube Community Edition (port 9000)
- Defectdojo (port 8082)

### Local packages used by the pipeline:

- actionlint (for linting workflow syntax)
- act (for testing workflows prior to deployment)
- syft (SBOM export)
- betterleaks (secret detection)

### System requirements:

- Min. 16 GB RAM
- Lightweight linux-based OS (Windows not tested but expecting it to only run with minimum 32GBRAM)

## Getting started
Clone this repo into your preferred docker folder. We recommend mkdir /opt/docker-pipeline and ensure ownership and group to be your own (eg. ``sudo chown $USER:users ./docker-pipeline)

Ensure your user is in the docker group: ``sudo usermod +G $USER docker`` and log out and a back in afterwards.

### The Forgejo instance
Each container will be needed to be started one by one, starting with Forgejo to create the external network "forgejo" for the other containers to join:

```cd forgejo/
docker compose up -d
```

Go to localhost:3000 and log in to Forgejo using the default admin password: administrator/******.
- Change the password
- Create an organization
- Create a local user with your username/password (uncheck change on first login)
- Log in as your new user
- Add your public SSH key to your user
- Create a new user called repo-provisioner (uncheck change on first login)
- Add the repo-provisioner to team "owners" in the organisation
- Log in as repo-provisionerj
- Create a new API key for the organization under avatar --> settings --> applications. The API key requires the following permissions:
    - write organization
    - write repository
    - write user
- create an organization wide runner called "local-runner" and not down uuid and token

From here on we interact with Forgejo using the rest API, to create new repos, adding files, creating templates and the like.

You can run new-repo.sh to test this.

### Forgejo runner
The forgejo runner needs to register with forgejo through its data/config.yml file.
Run ``docker compose up -d", then add the following:

```
connections:
    forgejo:
      url: http://forgejo:3000/
      uuid: <uuid from forgejo (need to create a runner first)>
      token: <token from forgejo (need to create a runner first)>
      labels:
        - "ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
        - "docker:docker://node:20-bookworm"
´´´
add the runner to the network by adding the following:
´´´
network: "forgejo"
´´´

run ``docker compose down && docker compose up -d`` 

The runner should show as online on the list of forgejo runners.
 
### Dependency Track

For VM RAM limitations, ``max_map_count`` must be set to 524288 and added to kernel parameters:

**Nixos**:
Add the following to your boot.kernel parameters in your configuration.nix:

``boot.kernel.sysctl."vm.max_map_count" = 524288;``

**Debian/Ubuntu/Fedora** (systemd based distros):
``XXXXX``

Cd to the Dependency Track repo and run ``docker compose up -d``.

Open your browser and login to localhost:8080 for the first time using default admin/admin.

Setup (as admin)

- Administration > Access Management > Teams > Create Team. Name it forgejo-ci.
- Open the team and grant only what the pipeline needs:
    BOM_UPLOAD, to upload the SBOM.
    PROJECT_CREATION_UPLOAD, so autoCreate=true can create projects.
    VIEW_PORTFOLIO, to look up the project and read findings.
- On the same team page, generate an API key and copy it into the Forgejo secret DT_KEY.

### .env for Dependency Track
Add the values to /opt/dependency-track/.env:

 ```
 DT_HEAP=2g
 DT_MEM_LIMIT=4g
 ```

### Sonarqube
- Cd to the Sonarqube repo and run ``docker compose up -d``.

- Open your browser and login to localhost:9000 (or sonar:9000 if you have set up local hosts file) for the first time using default admin/admin.

- Change admin password and create a local user/password (as admin):

- Administration > Security > Users > Create User. Use a login like ci-bot and a name like "Forgejo CI". The email is optional. Give it a long random password, since nothing needs to log in as it.
- Administration > Security > Global Permissions. Grant ci-bot these two permissions and nothing else:
    Execute Analysis, to run scans.
    Create Projects, so the first scan can create the project automatically.
- Log in as ci-bot (a private window is easiest) and go to My Account > Security.
Generate a token with type Global Analysis Token, name it forgejo-ci, and pick an expiry. The Global Analysis Token type is only offered to users who have the Execute Analysis permission, so if you don't see it, recheck step 2.
- Copy the token into the Forgejo secret SONAR_TOKEN and into your .env file.

### Defectdojo
Defectdojo requires to use their own official docker compose file.

```
git clone https://github.com/DefectDojo/django-DefectDojo /opt/docker-pipeline/defectdojo
cd /opt/docker-pipeline/defectdojo
chmod +x ./docker/docker-compose-check.sh
bash ./docker/docker-compose-check.sh
```

The check needs to return positive. 

#### port clash

DefectDojo's nginx publishes 8080, which your Dependency-Track frontend already uses. Create /opt/defectdojo/compose.local.yaml, which also joins DefectDojo to the forgejo network so runner jobs can reach it:

```yaml
networks:
  forgejo:
    external: true

services:
  nginx:
    ports: !override
      - "8082:8080"
    networks:
      default: {}
      forgejo:
        aliases: [defectdojo]
```

The !override tag replaces the upstream port list instead of adding to it, and needs Docker Compose 2.24 or newer. Check with docker compose version. Then tell Compose to load both files by creating /opt/defectdojo/.env:

``COMPOSE_FILE=docker-compose.yml:compose.local.yaml``

If the repo already has a .env, append that line instead of overwriting it. Confirm the merge before starting:

```bash
docker compose config | grep -A3 "published"
```

You should see 8082 and no 8080.

3. Start it

```bash
docker compose build        # or `docker compose pull` if you prefer prebuilt images
docker compose up -d
docker compose logs -f initializer
```

The initializer can take up to about 3 minutes. When it finishes, get the generated admin password:

```bash
docker compose logs initializer | grep "Admin password:"
```

#### existing volume errors
On some occasions, a  media volume called "threats" is already created. Docker compose down and remove this:
```
docker compose down
docker volume rm defectdojo_defectdojo_media
docker compose up -d
docker compose logs -f initializer
```
(You can also check if the volume is present before running the container:)
``cd /opt/defectdojo
sudo ls -la /var/lib/docker/volumes/defectdojo_defectdojo_media/_data``


Cd to the Defectdojo folder and run ``docker compose up -d``.

Open your browser and login to localhost:8082 for the first time using default admin/admin.

Change admin password and create a local user/password.
Setup (as admin)

- Create the user. Go to Users > New User, with a login like ci-bot. Don't make it a superuser. The first account on a new instance is a superuser and manages permissions for everyone else, so that's your admin account. 
- Create an organization, does not matter what you call it. 
- Create an asset for that organization. This should be the same as a repo. 
- Add the ci-bot as "authorized user" when viewing the newly created asset.
- Log in as ci-bot and save the api2 key and Token.
- Store it as the Forgejo secret DD_TOKEN, and the server address as a variable DD_URL. 

Test api access using the Token:
Create a small test file:
```bash
echo '{"findings":[{"title":"test finding","severity":"Low","description":"permission test"}]}'>> t.json
```
Then call the API:
```bash
curl -i -X POST http://<VM3-IP>:<port>/api/v2/import-scan/ \
  -H "Authorization: Token <ci-bot key>" \
  -F scan_type="Generic Findings Import" -F file=@t.json \
  -F product_name="<asset-name>" -F engagement_name="forgejo-ci" \
  -F auto_create_context=true
```

# Starting a workflow

- Copy "env.example" to .env, fill in, and: chmod 600 .env (do not commit it, also part of .gitignore)


## Notes
The containers create several standalone postgreSQL databases. These reside **locally** so either back them up or be ready to cry if you lose your disk.

If you are so lucky to run NixOS you can simply follow the instructions and run ``nix develop`` as the flake.nix in the repo contains all the needed packages. Other distributions or OSes need to have the tools installed as noted previously.

You can create local dns host resolution on Linux distros the following way:

**Nixos**:
Add the following to your configuration.nix under network settings:

``networking.hosts."127.0.0.1" = [ "forgejo" "dt" "sonar" "defectdojo" ];"

**Debian/Ubuntu**:
Edit /etc/hosts:

``XXXXX``

# Backlog:

´´´
- update scripts to work with JUST
- set up to easily integrate into KIND
- 

```
