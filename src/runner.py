"""
Main runner that orchestrates the sync process.
"""

from datetime import datetime
from typing import Optional

from loguru import logger

from .db import DatabaseConnection, create_db_connection
from .payload import SyncPayload, build_payload
from .queries import QueryExecutor, create_query_executor
from .sender import HttpSender, SendResult, create_sender
from .settings import Settings
from .state import StateManager, WindowCalculator, create_state_manager, create_window_calculator


class SyncRunner:
    """Orchestrates the complete sync process."""

    def __init__(
        self,
        settings: Settings,
        db: DatabaseConnection,
        queries: QueryExecutor,
        sender: HttpSender,
        state_manager: StateManager,
        window_calculator: WindowCalculator,
    ):
        self.settings = settings
        self.db = db
        self.queries = queries
        self.sender = sender
        self.state_manager = state_manager
        self.window_calculator = window_calculator

    def run(self) -> bool:
        """
        Run the complete sync process.

        1. Process any pending outbox payloads
        2. Calculate the sync window
        3. Execute queries and build payload
        4. Send to API
        5. Update state on success

        Returns True if sync was successful, False otherwise.
        """
        logger.info("=" * 60)
        logger.info("Starting PDV Sync")
        logger.info("=" * 60)

        try:
            # Step 1: Process outbox queue
            outbox_count = self.sender.process_outbox()
            if outbox_count > 0:
                logger.info(f"Processed {outbox_count} pending payloads from outbox")

            # Step 2: Calculate sync window
            dt_from, dt_to = self.window_calculator.calculate_window()

            # Step 3: Gather data
            payload = self._build_payload(dt_from, dt_to)
            if payload is None:
                logger.warning("No payload to send (possibly no data in window)")
                self.window_calculator.mark_success(dt_to)
                return True  # Not an error, just no data

            # Step 3.5: Skip sending if no operations (saves bandwidth)
            if payload.ops.count == 0:
                logger.info("No new sales in window — skipping POST")
                self.window_calculator.mark_success(dt_to)
                return True

            # Step 4: Send payload
            result = self._send_payload(payload)

            # Step 5: Update state on success
            if result.success:
                self.window_calculator.mark_success(dt_to)
                logger.success("Sync completed successfully")
                return True
            else:
                logger.warning("Sync completed with errors (payload saved to outbox)")
                return False

        except Exception as e:
            logger.exception(f"Sync failed with exception: {e}")
            return False

        finally:
            logger.info("=" * 60)

    def _build_payload(
        self, dt_from: datetime, dt_to: datetime
    ) -> Optional[SyncPayload]:
        """Build the sync payload from database queries."""
        logger.info("Gathering data from database")

        # Get store info
        store_info = self.queries.get_store_info(self.settings.store_id_ponto_venda)
        store_name = store_info["nome"] if store_info else f"PDV {self.settings.store_id_ponto_venda}"

        # Get current turno
        turno = self.queries.get_current_turno(self.settings.store_id_ponto_venda)

        # Get operation IDs (for deduplication)
        ops_ids = self.queries.get_operation_ids(dt_from, dt_to)

        if not ops_ids:
            logger.info("No operations found in window")

        # Get sales by vendor
        sales_by_vendor = self.queries.get_sales_by_vendor(dt_from, dt_to)

        # Get payments by method
        payments_by_method = self.queries.get_payments_by_method(dt_from, dt_to)

        # Build warnings
        warnings = self._check_warnings(sales_by_vendor, payments_by_method)

        # Build payload
        payload = build_payload(
            store_id=self.settings.store_id_ponto_venda,
            store_name=store_name,
            store_alias=self.settings.store_alias,
            dt_from=dt_from,
            dt_to=dt_to,
            window_minutes=self.settings.sync_window_minutes,
            turno=turno,
            ops_ids=ops_ids,
            sales_by_vendor=sales_by_vendor,
            payments_by_method=payments_by_method,
            warnings=warnings,
        )

        # Log payload summary
        logger.info(f"Payload built: {payload.ops.count} operations")
        logger.info(f"  - Vendors: {len(payload.sales.by_vendor)}")
        logger.info(f"  - Payment methods: {len(payload.sales.by_payment)}")
        if warnings:
            for w in warnings:
                logger.warning(f"  ! {w}")

        return payload

    def _check_warnings(
        self,
        sales_by_vendor: list[dict],
        payments_by_method: list[dict],
    ) -> list[str]:
        """Check for any data quality warnings."""
        warnings = []

        # Check for NULL vendors
        null_vendors = [v for v in sales_by_vendor if v.get("id_usuario_vendedor") is None]
        if null_vendors:
            total_null = sum(v.get("qtd_cupons", 0) for v in null_vendors)
            warnings.append(f"Vendedor NULL encontrado em {total_null} cupom(s)")

        # Check for NULL payment methods
        null_payments = [p for p in payments_by_method if p.get("id_finalizador") is None]
        if null_payments:
            warnings.append("Meio de pagamento NULL encontrado")

        return warnings

    def _send_payload(self, payload: SyncPayload) -> SendResult:
        """Send the payload to the API."""
        # Convert to dict for JSON serialization
        payload_dict = payload.model_dump(mode="json", by_alias=True)
        return self.sender.send(payload_dict)


def create_runner(settings: Settings) -> SyncRunner:
    """Factory function to create a fully configured SyncRunner."""
    # Create components
    db = create_db_connection(settings)
    queries = create_query_executor(db)
    sender = create_sender(
        endpoint=settings.api_endpoint,
        token=settings.api_token,
        timeout=settings.request_timeout_seconds,
        outbox_dir=settings.outbox_dir,
    )
    state_manager = create_state_manager(settings.state_file)
    window_calculator = create_window_calculator(
        state_manager=state_manager,
        window_minutes=settings.sync_window_minutes,
    )

    return SyncRunner(
        settings=settings,
        db=db,
        queries=queries,
        sender=sender,
        state_manager=state_manager,
        window_calculator=window_calculator,
    )
