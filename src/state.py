"""
State management for incremental sync.
Tracks the last successful sync timestamp.
"""

import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from loguru import logger
from pydantic import BaseModel


class SyncState(BaseModel):
    """Persistent sync state."""

    last_sync_to: Optional[datetime] = None


class StateManager:
    """Manages the sync state file."""

    def __init__(self, state_file: Path):
        self.state_file = Path(state_file)
        self._ensure_directory()

    def _ensure_directory(self) -> None:
        """Ensure the state file directory exists."""
        self.state_file.parent.mkdir(parents=True, exist_ok=True)

    def load(self) -> SyncState:
        """Load state from file."""
        if not self.state_file.exists():
            logger.info("State file not found, starting fresh")
            return SyncState()

        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            # Parse datetime if present
            if data.get("last_sync_to"):
                data["last_sync_to"] = datetime.fromisoformat(data["last_sync_to"])

            state = SyncState(**data)
            logger.info(f"Loaded state: last_sync_to={state.last_sync_to}")
            return state

        except (json.JSONDecodeError, ValueError) as e:
            logger.warning(f"Invalid state file, starting fresh: {e}")
            return SyncState()

    def save(self, state: SyncState) -> None:
        """Save state to file."""
        data = {
            "last_sync_to": (
                state.last_sync_to.isoformat() if state.last_sync_to else None
            )
        }

        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)

        logger.info(f"State saved: last_sync_to={state.last_sync_to}")

    def update_last_sync(self, dt: datetime) -> None:
        """Update and save the last sync timestamp."""
        state = SyncState(last_sync_to=dt)
        self.save(state)


class WindowCalculator:
    """Calculates the sync window based on state."""

    def __init__(
        self,
        state_manager: StateManager,
        window_minutes: int,
    ):
        self.state_manager = state_manager
        self.window_minutes = window_minutes

    def calculate_window(self) -> tuple[datetime, datetime]:
        """
        Calculate the sync window (from, to).

        - If last_sync_to exists, use it as 'from'
        - Otherwise, use now - window_minutes
        - 'to' is always now
        """
        state = self.state_manager.load()
        now = datetime.now()

        if state.last_sync_to:
            dt_from = state.last_sync_to
        else:
            dt_from = now - timedelta(minutes=self.window_minutes)
            logger.info(
                f"No previous sync, using window of {self.window_minutes} minutes"
            )

        dt_to = now

        logger.info(f"Sync window: {dt_from} -> {dt_to}")
        return dt_from, dt_to

    def mark_success(self, dt_to: datetime) -> None:
        """Mark the sync as successful by updating state."""
        self.state_manager.update_last_sync(dt_to)


def create_state_manager(state_file: Path) -> StateManager:
    """Factory function to create state manager."""
    return StateManager(state_file)


def create_window_calculator(
    state_manager: StateManager,
    window_minutes: int,
) -> WindowCalculator:
    """Factory function to create window calculator."""
    return WindowCalculator(state_manager, window_minutes)
