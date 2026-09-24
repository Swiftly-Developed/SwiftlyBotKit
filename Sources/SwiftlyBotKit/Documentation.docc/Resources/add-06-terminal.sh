# Start a throwaway PostgreSQL for local development.
docker run --name mysite-postgres \
  -e POSTGRES_USER=vapor_username \
  -e POSTGRES_PASSWORD=vapor_password \
  -e POSTGRES_DB=vapor_database \
  -p 5432:5432 -d postgres:16
