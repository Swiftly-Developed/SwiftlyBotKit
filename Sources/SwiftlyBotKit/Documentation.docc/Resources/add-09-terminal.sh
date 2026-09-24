# Start a throwaway PostgreSQL for local development.
docker run --name mysite-postgres \
  -e POSTGRES_USER=vapor_username \
  -e POSTGRES_PASSWORD=vapor_password \
  -e POSTGRES_DB=vapor_database \
  -p 5432:5432 -d postgres:16

# Run the app. autoMigrate() creates the table on first boot.
swift run App serve --hostname 127.0.0.1 --port 8080

# In a second terminal, pretend to be OpenAI's training crawler.
curl -A "GPTBot" http://127.0.0.1:8080/

# Look at the row it wrote.
docker exec -it mysite-postgres psql -U vapor_username -d vapor_database -c \
  "SELECT agent_name, purpose, verification, path, status_code FROM ai_bot_visits;"

#  agent_name | purpose  | verification | path | status_code
# ------------+----------+--------------+------+-------------
#  GPTBot     | training | spoofed      | /    |         200
