# Set the credentials and a long random session secret.
export ADMIN_USER=owner
export ADMIN_PASSWORD='a long passphrase'
export ADMIN_SESSION_SECRET="$(openssl rand -hex 32)"

swift run App serve --hostname 127.0.0.1 --port 8080
