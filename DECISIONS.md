# Offline sync decisions

## 1. Ordering and priority

- Save captured work locally before reporting capture success. Sync visit
  records (including notes), then observations, then photos. Observations and
  photos require acknowledgment of their parent visit first.
- Priority applies across all pending visits, with FIFO within each item type.
  With two pending visits, send both visit records, then their observations,
  then their photos. Visit 2 does not wait for Visit 1's images.
- Structured data is needed within minutes of connectivity returning. At
  approximately 50 KB/s, a 3 MB photo takes about a minute; 5-20 photos take
  about 5-20 minutes before retries. Sending images first would delay the
  information agronomists need.
- Upload photos in 128 KB chunks (roughly 2.6 seconds per chunk at that speed).
  Recheck structured-data priority between chunks. If another visit is captured
  during an upload, finish the current chunk, then send its eligible structured
  data before continuing photos. This chunk size is a starting trade-off between
  request overhead and retransmission cost.
- Persist the next unacknowledged chunk only after a durable server receipt.
  If signal drops at 60%, retain acknowledged progress and resend the interrupted
  chunk, rather than restarting the photo. The server must deduplicate repeated
  chunks by photo ID and index, verify matching content, and confirm complete
  assembly before the photo leaves the outbox.
- Stop the current attempt on a disconnect or timeout. A scheduler retries using
  capped exponential backoff and jitter; connectivity changes can trigger an
  attempt but do not guarantee a working connection. Keep pending work visible
  to the agent. Continuous structured-data capture could starve photos; measure
  that before introducing a fairness policy.
