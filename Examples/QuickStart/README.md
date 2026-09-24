# QuickStart

A minimal Vapor app with SwiftlyBotKit installed: two HTML pages, AI-agent
tracking on every request, and the dashboard at `/admin/ai-bots/`.

Everything BotKit-related is in
[`Sources/QuickStart/configure.swift`](Sources/QuickStart/configure.swift).

## Run it

1. Start PostgreSQL (BotKit requires it):

   ```bash
   docker compose up -d
   ```

   or, without Compose:

   ```bash
   docker run -d --name botkit-postgres -p 5432:5432 \
     -e POSTGRES_USER=botkit -e POSTGRES_PASSWORD=botkit -e POSTGRES_DB=botkit \
     postgres:16
   ```

2. Set the dashboard credentials and signing secret:

   ```bash
   export BOT_DASHBOARD_USER=owner
   export BOT_DASHBOARD_PASSWORD=change-me
   export BOT_DASHBOARD_SECRET=$(openssl rand -hex 32)
   ```

   Without the first two, recording still runs but the dashboard is not
   mounted. Without the secret, a random one is used and sign-ins end at every
   restart.

   The app connects to
   `postgres://botkit:botkit@localhost:5432/botkit?sslmode=disable` unless
   `DATABASE_URL` is set.

3. Run the app. The first start creates the `ai_bot_visits` table:

   ```bash
   swift run
   ```

4. Pretend to be an AI crawler:

   ```bash
   curl -A "GPTBot/1.2" http://localhost:8080/
   curl -A "ExampleResearchBot/1.0" http://localhost:8080/about/
   curl -H "Referer: https://chatgpt.com/" http://localhost:8080/about/
   ```

   The first is a built-in agent, the second the custom agent the example
   registers, and the third a person arriving from ChatGPT.

5. Open <http://localhost:8080/admin/ai-bots/> and sign in.

The `GPTBot` hit shows as **spoofed**: it claims to be OpenAI's crawler but
came from `127.0.0.1`, which is not in OpenAI's published ranges. That is the
verification working. Recording is done off the request path, so a row can take
a moment to appear while the range feeds are fetched for the first time.

## Clean up

```bash
docker compose down -v
```
