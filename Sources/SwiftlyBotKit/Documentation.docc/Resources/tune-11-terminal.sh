# The custom agent is recorded with the purpose you gave it.
curl -A "Mozilla/5.0 (compatible; AcmeResearchBot/1.0)" http://127.0.0.1:8080/pricing

# A human arriving from DeepSeek is recorded as an AI referral.
curl -e "https://chat.deepseek.com/a/chat/s/123" http://127.0.0.1:8080/pricing

# An excluded path is never recorded, whoever asks.
curl -A "GPTBot" http://127.0.0.1:8080/healthz

# Two rows: one agent visit, one referral with agent_name empty.
psql "$DATABASE_URL" -c \
  "SELECT agent_name, purpose, verification, referrer_platform, path FROM ai_bot_visits ORDER BY created_at DESC LIMIT 2;"
