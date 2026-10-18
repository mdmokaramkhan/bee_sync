# Server guide

What your endpoint receives from bee_sync, and how to respond.

**Contents:** [The request](#the-request) · [Responding](#responding) · [Deduplication](#deduplication) · [Example server](#example-server) · [Checklist](#checklist)

## The request

bee_sync sends one `POST` per batch to the endpoint you configured:

```http
POST /events HTTP/1.1
Content-Type: application/json
Authorization: Bearer <your-ingestion-key>          (whatever headers you set)
X-BeeSync-Batch-Id: 6f1c1a52-2f4e-4f8a-9d38-2b7c1d3e5a10
X-BeeSync-Sdk: bee_sync/0.3.2 (android; android_worker)
Content-Encoding: gzip                              (only with HttpTransport(gzip: true))
```

```json
{
  "batch_id": "6f1c1a52-2f4e-4f8a-9d38-2b7c1d3e5a10",
  "sent_at": 1771234567890,
  "events": [
    {
      "id": "0199a3c0-0000-7000-8000-000000000001",
      "name": "purchase",
      "timestamp": 1771234562890,
      "priority": "immediate",
      "attempt": 1,
      "properties": { "order_id": "A1", "amount": 12.5 }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `batch_id` | New for every request, including retries. |
| `sent_at` | Device time when the request was sent (ms since epoch, UTC). |
| `events[].id` | UUIDv7, the same on every retry. **Deduplicate on this.** |
| `events[].timestamp` | Device time when `track()` was called (ms since epoch, UTC). |
| `events[].priority` | `normal` or `immediate`. |
| `events[].attempt` | 1 on the first try, then 2, 3, … after each retryable response (408, 429, 5xx). Network failures aren't counted. |
| `events[].properties` | The JSON object passed to `track()`. |

**Clock skew:** device clocks can be wrong. To correct a timestamp, use `timestamp + (server_now - sent_at)`.

The `X-BeeSync-Sdk` header says which uploader sent the request:
- `dart`: the app itself;
- `android_worker`: Android WorkManager;
- `ios_bg_exit`: the iOS upload when the app is backgrounded;
- `ios_bgtask`: iOS background tasks.

## Responding

| You return | bee_sync does |
|---|---|
| **2xx** | Marks the whole batch delivered. |
| 2xx with `{"rejected": ["<id>", …]}` | Delivers the rest and drops the listed events, e.g. ones that fail your validation. |
| 408, 429, 5xx | Retries with exponential backoff, honouring `Retry-After` (seconds or an HTTP date). Drops the event after `maxAttempts` (12) such responses. |
| No response (offline, timeout) | Retries with exponential backoff, without counting an attempt. |
| 401, 403 | Keeps the events and pauses uploads until the app sets new headers. |
| 413 | Splits the batch in half and retries; drops a single event only if it's too large on its own. |
| Other 4xx | Splits the batch to find and drop only the events you refuse. |

Return 2xx **as soon as the events are stored**, and do the heavier processing afterwards. Slow responses delay the next batch, and a timeout (30 s by default) counts as a failure.

## Deduplication

Delivery is **at-least-once**. The same event can arrive twice, for example when your server stored a batch but the response never reached the phone. Handle it by treating `id` as unique:

- **SQL:** add a unique index on `id` and use `INSERT … ON CONFLICT (id) DO NOTHING`.
- **Key-value stores:** use `id` as the key.
- Keep ids for at least as long as events can wait on the device: `RetentionPolicy.maxAge`, 7 days by default.
- Return 2xx for duplicates too; they were stored already.

## Example server

A minimal [Express](https://expressjs.com) endpoint. It handles gzip automatically (`express.json` inflates it) and deduplicates on `id`:

```js
import express from 'express';

const app = express();
app.use(express.json({ limit: '2mb' }));

const seen = new Set(); // use a database with a unique index in production

app.post('/events', (req, res) => {
  if (req.get('Authorization') !== `Bearer ${process.env.INGESTION_KEY}`) {
    return res.sendStatus(401);
  }
  for (const event of req.body.events ?? []) {
    if (seen.has(event.id)) continue; // duplicate: already stored
    seen.add(event.id);
    console.log(event.name, event.properties);
  }
  res.sendStatus(200);
});

app.listen(8080);
```

For local testing without writing a server, the repository includes `tool/test_server.dart`. It logs every batch and can simulate failures (`--mode ok|fail|auth|slow`).

## Checklist

- [ ] HTTPS endpoint accepting `POST` with a JSON body (and gzip, if you enable it).
- [ ] Return 2xx once events are stored.
- [ ] Deduplicate on `events[].id`.
- [ ] Use a long-lived ingestion key, not an expiring user token.
- [ ] Return 429 or 503 with `Retry-After` when overloaded.
- [ ] Optional: return `{"rejected": [ids]}` for events you can't accept.
