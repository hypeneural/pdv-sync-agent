"""
HTTP sender with retry logic and offline fallback.
Uses tenacity for exponential backoff retries.
"""

import json
from datetime import datetime
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

try:
    import orjson

    def json_dumps(obj: Any) -> str:
        """Fast JSON serialization with orjson."""
        return orjson.dumps(obj, default=str).decode("utf-8")

except ImportError:
    def json_dumps(obj: Any) -> str:
        """Standard JSON serialization."""
        return json.dumps(obj, default=str, ensure_ascii=False)


class SendResult(BaseModel):
    """Result of a send attempt."""

    success: bool
    status_code: Optional[int] = None
    message: str = ""
    saved_to_outbox: bool = False
    outbox_path: Optional[str] = None


class OutboxManager:
    """Manages the offline outbox queue."""

    def __init__(self, outbox_dir: Path):
        self.outbox_dir = Path(outbox_dir)
        self._ensure_directory()

    def _ensure_directory(self) -> None:
        """Ensure the outbox directory exists."""
        self.outbox_dir.mkdir(parents=True, exist_ok=True)

    def save(self, payload: dict[str, Any], sync_id: str) -> Path:
        """Save a failed payload to the outbox."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{timestamp}_{sync_id[:12]}.json"
        filepath = self.outbox_dir / filename

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2, default=str)

        logger.warning(f"Payload saved to outbox: {filepath}")
        return filepath

    def list_pending(self) -> list[Path]:
        """List all pending payloads in chronological order."""
        if not self.outbox_dir.exists():
            return []

        files = sorted(self.outbox_dir.glob("*.json"))
        logger.info(f"Found {len(files)} pending payloads in outbox")
        return files

    def load(self, filepath: Path) -> Optional[dict[str, Any]]:
        """Load a payload from the outbox."""
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            logger.error(f"Failed to load outbox file {filepath}: {e}")
            return None

    def remove(self, filepath: Path) -> None:
        """Remove a successfully sent payload from the outbox."""
        try:
            filepath.unlink()
            logger.info(f"Removed from outbox: {filepath}")
        except IOError as e:
            logger.warning(f"Failed to remove outbox file {filepath}: {e}")


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
        }

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        retry=retry_if_exception_type((requests.Timeout, requests.ConnectionError)),
        before_sleep=before_sleep_log(logger, "WARNING"),
    )
    def _send_with_retry(self, payload_json: str) -> requests.Response:
        """Send with tenacity retry on network errors."""
        return requests.post(
            self.endpoint,
            data=payload_json,
            headers=self._get_headers(),
            timeout=self.timeout,
        )

    def send(self, payload: dict[str, Any]) -> SendResult:
        """
        Send a payload to the API.
        Falls back to outbox on failure.
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
            else:
                logger.error(
                    f"API rejected payload: HTTP {response.status_code} - {response.text[:200]}"
                )
                # Save to outbox on non-2xx responses
                outbox_path = self.outbox.save(payload, sync_id)
                return SendResult(
                    success=False,
                    status_code=response.status_code,
                    message=f"API rejected: {response.text[:200]}",
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
        Returns the number of successfully sent payloads.
        """
        pending = self.outbox.list_pending()
        if not pending:
            return 0

        logger.info(f"Processing {len(pending)} pending payloads from outbox")
        success_count = 0

        for filepath in pending:
            payload = self.outbox.load(filepath)
            if payload is None:
                continue

            sync_id = payload.get("integrity", {}).get("sync_id", "unknown")
            logger.info(f"Retrying outbox payload: {filepath.name} (sync_id={sync_id[:12]}...)")

            try:
                payload_json = json_dumps(payload)
                response = self._send_with_retry(payload_json)

                if response.status_code in (200, 201):
                    logger.success(f"Outbox payload sent: {filepath.name}")
                    self.outbox.remove(filepath)
                    success_count += 1
                else:
                    logger.warning(
                        f"Outbox payload still failing: HTTP {response.status_code}"
                    )
            except requests.RequestException as e:
                logger.warning(f"Outbox payload network error: {e}")
                # Keep in outbox for next attempt
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
