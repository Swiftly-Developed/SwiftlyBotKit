# Set the credentials and a long random session secret.
export ADMIN_USER=owner
export ADMIN_PASSWORD='a long passphrase'
export ADMIN_SESSION_SECRET="$(openssl rand -hex 32)"

swift run App serve --hostname 127.0.0.1 --port 8080

# In a second terminal: sign in and keep the session cookie.
curl -c cookies.txt \
  --data-urlencode "username=owner" \
  --data-urlencode "password=a long passphrase" \
  http://127.0.0.1:8080/internal/ai-traffic/login

# Every site, last 90 days.
curl -b cookies.txt "http://127.0.0.1:8080/internal/ai-traffic/?site=all&range=90d"
