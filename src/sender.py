"""
HTTP sender with retry logic and offline fallback.
Uses tenacity for exponential backoff retries.
Smart error classification: 4xx → dead_letter, 5xx → outbox retry.
"""

import json
import shutil
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional

import requests
from loguru import logger
from pydantic import BaseModel
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)

from . import SCHEMA_VERSION

try:
    import orjson

    def json_dumps(obj: Any) -> str:
        """Fast JSON serialization with orjson."""
        return orjson.dumps(obj, default=str).decode("utf-8")

except ImportError:
    def json_dumps(obj: Any) -> str:
        """Standard JSON serialization."""
        return json.dumps(obj, default=str, ensure_ascii=False)


# HTTP status codes that should NOT be retried (client errors / validation)
NO_RETRY_CODES = {400, 401, 403, 404, 409, 422}

# Max retry attempts before moving to dead_letter
MAX_OUTBOX_RETRIES = 50

# Days before outbox files expire
OUTBOX_TTL_DAYS = 7


class SendResult(BaseModel):
    """Result of a send attempt."""

    success: bool
    status_code: Optional[int] = None
    message: str = ""
    saved_to_outbox: bool = False
    saved_to_dead_letter: bool = False
    outbox_path: Optional[str] = None


class OutboxManager:
    """Manages the offline outbox queue and dead_letter archive."""

    def __init__(self, outbox_dir: Path):
        self.outbox_dir = Path(outbox_dir)
        self.dead_letter_dir = self.outbox_dir.parent / "dead_letter"
        self._ensure_directories()

    def _ensure_directories(self) -> None:
        """Ensure outbox and dead_letter directories exist."""
        self.outbox_dir.mkdir(parents=True, exist_ok=True)
        self.dead_letter_dir.mkdir(parents=True, exist_ok=True)

    def save(self, payload: dict[str, Any], sync_id: str) -> Path:
        """Save a failed payload to the outbox for retry."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{timestamp}_{sync_id[:12]}.json"
        filepath = self.outbox_dir / filename

        # Wrap payload with retry metadata
        envelope = {
            "_retry_count": 0,
            "_created_at": datetime.now().isoformat(),
            "payload": payload,
        }

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(envelope, f, ensure_ascii=False, indent=2, default=str)

        logger.warning(f"Payload saved to outbox: {filepath}")
        return filepath

    def save_dead_letter(
        self, payload: dict[str, Any], sync_id: str, reason: str, status_code: Optional[int] = None
    ) -> Path:
        """Save a permanently failed payload to dead_letter (no retry)."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        code_suffix = f"_{status_code}" if status_code else ""
        filename = f"{timestamp}_{sync_id[:12]}{code_suffix}.json"
        filepath = self.dead_letter_dir / filename

        envelope = {
            "_reason": reason,
            "_status_code": status_code,
            "_dead_at": datetime.now().isoformat(),
            "payload": payload,
        }

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(envelope, f, ensure_ascii=False, indent=2, default=str)

        logger.error(f"Payload moved to dead_letter: {filepath} (reason: {reason})")
        return filepath

    def list_pending(self) -> list[Path]:
        """List valid pending payloads (not expired)."""
        if not self.outbox_dir.exists():
            return []

        cutoff = datetime.now() - timedelta(days=OUTBOX_TTL_DAYS)
        files = sorted(self.outbox_dir.glob("*.json"))
        valid = []

        for f in files:
            # Check file age by modification time
            mtime = datetime.fromtimestamp(f.stat().st_mtime)
            if mtime < cutoff:
                logger.warning(f"Outbox file expired ({OUTBOX_TTL_DAYS}d TTL): {f.name}")
                self._move_to_dead_letter(f, reason=f"expired_ttl_{OUTBOX_TTL_DAYS}d")
            else:
                valid.append(f)

        if valid:
            logger.info(f"Found {len(valid)} pending payloads in outbox")
        return valid

    def load(self, filepath: Path) -> Optional[dict[str, Any]]:
        """Load and unwrap a payload from the outbox."""
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)

            # Handle both old format (raw payload) and new envelope format
            if "payload" in data and "_retry_count" in data:
                return data  # New envelope format
            else:
                # Old format: wrap it
                return {"_retry_count": 0, "payload": data}

        except (json.JSONDecodeError, IOError) as e:
            logger.error(f"Failed to load outbox file {filepath}: {e}")
            return None

    def increment_retry(self, filepath: Path, envelope: dict) -> int:
        """Increment retry count and save back. Returns new count."""
        envelope["_retry_count"] = envelope.get("_retry_count", 0) + 1
        envelope["_last_retry"] = datetime.now().isoformat()

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(envelope, f, ensure_ascii=False, indent=2, default=str)

        return envelope["_retry_count"]

    def remove(self, filepath: Path) -> None:
        """Remove a successfully sent payload from the outbox."""
        try:
            filepath.unlink()
            logger.info(f"Removed from outbox: {filepath}")
        except IOError as e:
            logger.warning(f"Failed to remove outbox file {filepath}: {e}")

    def _move_to_dead_letter(self, filepath: Path, reason: str) -> None:
        """Move an outbox file to dead_letter."""
        try:
            dest = self.dead_letter_dir / filepath.name
            shutil.move(str(filepath), str(dest))
            logger.warning(f"Moved to dead_letter: {filepath.name} ({reason})")
        except IOError as e:
            logger.error(f"Failed to move to dead_letter: {e}")


class HttpSender:
    """Sends payloads to the central API."""

    def __init__(
        self,
        endpoint: str,
        token: str,
        timeout: int,
        outbox_dir: Path,
    ):
        self.endpoint = endpoint
        self.token = token
        self.timeout = timeout
        self.outbox = OutboxManager(outbox_dir)

    def _get_headers(self) -> dict[str, str]:
        """Build request headers."""
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-PDV-Schema-Version": SCHEMA_VERSION,
        }

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        retry=retry_if_exception_type((requests.Timeout, requests.ConnectionError)),
        before_sleep=before_sleep_log(logger, "WARNING"),
    )
    def _send_with_retry(self, payload_json: str) -> requests.Response:
        """Send with tenacity retry on network errors. Each attempt gets unique X-Request-Id."""
        request_id = str(uuid.uuid4())
        headers = self._get_headers()
        headers["X-Request-Id"] = request_id
        logger.info(f"POST attempt (request_id={request_id})")
        return requests.post(
            self.endpoint,
            data=payload_json,
            headers=headers,
            timeout=self.timeout,
        )

    def send(self, payload: dict[str, Any]) -> SendResult:
        """
        Send a payload to the API.
        Smart error handling:
          - 2xx: success
          - 4xx (400/401/403/422): dead_letter (no retry, payload is invalid)
          - 5xx / network error: outbox (retry next cycle)
        """
        sync_id = payload.get("integrity", {}).get("sync_id", "unknown")
        logger.info(f"Sending payload to {self.endpoint} (sync_id={sync_id[:12]}...)")

        try:
            payload_json = json_dumps(payload)
            response = self._send_with_retry(payload_json)

            if response.status_code in (200, 201):
                logger.success(
                    f"Payload sent successfully (HTTP {response.status_code})"
                )
                return SendResult(
                    success=True,
                    status_code=response.status_code,
                    message="Payload sent successfully",
                )

            elif response.status_code in NO_RETRY_CODES:
                # Client error — don't retry, save to dead_letter for analysis
                body_preview = response.text[:300]
                logger.error(
                    f"Client error (no retry): HTTP {response.status_code} - {body_preview}"
                )
                dl_path = self.outbox.save_dead_letter(
                    payload, sync_id,
                    reason=f"http_{response.status_code}",
                    status_code=response.status_code,
                )
                return SendResult(
                    success=False,
                    status_code=response.status_code,
                    message=f"Client error (dead_letter): {body_preview}",
                    saved_to_dead_letter=True,
                    outbox_path=str(dl_path),
                )

            else:
                # Server error (5xx) — save to outbox for retry
                logger.error(
                    f"Server error (will retry): HTTP {response.status_code} - {response.text[:200]}"
                )
                outbox_path = self.outbox.save(payload, sync_id)
                return SendResult(
                    success=False,
                    status_code=response.status_code,
                    message=f"Server error (outbox): {response.text[:200]}",
                    saved_to_outbox=True,
                    outbox_path=str(outbox_path),
                )

        except requests.RequestException as e:
            logger.error(f"Network error after retries: {e}")
            outbox_path = self.outbox.save(payload, sync_id)
            return SendResult(
                success=False,
                message=f"Network error: {e}",
                saved_to_outbox=True,
                outbox_path=str(outbox_path),
            )

    def process_outbox(self) -> int:
        """
        Process all pending payloads in the outbox.
        - Expired payloads (>TTL) are moved to dead_letter automatically
        - Payloads exceeding MAX_OUTBOX_RETRIES are moved to dead_letter
        - 4xx responses move payload to dead_letter (no further retry)
        Returns the number of successfully sent payloads.
        """
        pending = self.outbox.list_pending()  # Already filters expired
        if not pending:
            return 0

        logger.info(f"Processing {len(pending)} pending payloads from outbox")
        success_count = 0

        for filepath in pending:
            envelope = self.outbox.load(filepath)
            if envelope is None:
                continue

            payload = envelope.get("payload", envelope)
            retry_count = envelope.get("_retry_count", 0)
            sync_id = payload.get("integrity", {}).get("sync_id", "unknown")

            # Check max retries
            if retry_count >= MAX_OUTBOX_RETRIES:
                logger.error(
                    f"Max retries ({MAX_OUTBOX_RETRIES}) exceeded: {filepath.name}"
                )
                self.outbox._move_to_dead_letter(filepath, reason="max_retries_exceeded")
                continue

            logger.info(
                f"Retrying outbox payload: {filepath.name} "
                f"(sync_id={sync_id[:12]}..., attempt #{retry_count + 1})"
            )

            try:
                payload_json = json_dumps(payload)
                response = self._send_with_retry(payload_json)

                if response.status_code in (200, 201):
                    logger.success(f"Outbox payload sent: {filepath.name}")
                    self.outbox.remove(filepath)
                    success_count += 1

                elif response.status_code in NO_RETRY_CODES:
                    # Client error — stop retrying, move to dead_letter
                    logger.error(
                        f"Outbox payload permanently rejected: "
                        f"HTTP {response.status_code} - {filepath.name}"
                    )
                    self.outbox._move_to_dead_letter(
                        filepath, reason=f"http_{response.status_code}"
                    )

                else:
                    # Server error — increment retry, keep in outbox
                    new_count = self.outbox.increment_retry(filepath, envelope)
                    logger.warning(
                        f"Outbox payload still failing: HTTP {response.status_code} "
                        f"(retry {new_count}/{MAX_OUTBOX_RETRIES})"
                    )

            except requests.RequestException as e:
                logger.warning(f"Outbox payload network error: {e}")
                self.outbox.increment_retry(filepath, envelope)
                break  # Stop processing outbox if network is down

        return success_count


def create_sender(
    endpoint: str,
    token: str,
    timeout: int,
    outbox_dir: Path,
) -> HttpSender:
    """Factory function to create HTTP sender."""
    return HttpSender(endpoint, token, timeout, outbox_dir)
