"""
Main runner that orchestrates the sync process (v4.0).

Flow:
  1. Process outbox queue (retry failed payloads)
  2. Calculate sync window
  3. Gather turno-level data (sistema vs declarado) — PDV + Gestão
  4. Gather individual sale details (items + payments) — PDV + Loja
  5. Build aggregated resumo — PDV + Loja combined
  6. Build snapshots (turnos + vendas) — PDV + Gestão combined
  7. Send JSON payload
  8. Update state on success
"""

from datetime import datetime
from typing import Optional

from loguru import logger

from .db import DatabaseConnection, create_db_connection, create_gestao_db_connection
from .payload import (
    SyncPayload,
    TurnoDetail,
    TurnoSnapshot,
    VendaSnapshot,
    SaleDetail,
    OperatorInfo,
    build_payload,
    build_turno_detail,
    build_sale_details,
    _aware,
)
from .queries import QueryExecutor, create_query_executor
from .queries_gestao import GestaoQueryExecutor, create_gestao_query_executor
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
        gestao_db: DatabaseConnection,
        gestao_queries: GestaoQueryExecutor,
        sender: HttpSender,
        state_manager: StateManager,
        window_calculator: WindowCalculator,
    ):
        self.settings = settings
        self.db = db
        self.queries = queries
        self.gestao_db = gestao_db
        self.gestao_queries = gestao_queries
        self.sender = sender
        self.state_manager = state_manager
        self.window_calculator = window_calculator
        self._gestao_warning: Optional[str] = None

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
        logger.info("Starting PDV Sync v4.0")
        logger.info("=" * 60)

        try:
            # Step 1: Process outbox queue
            outbox_count = self.sender.process_outbox()
            if outbox_count > 0:
                logger.info(f"Processed {outbox_count} pending payloads from outbox")

            # Step 2: Calculate sync window
            dt_from, dt_to = self.window_calculator.calculate_window()

            # Step 3: Gather data and build payload
            payload = self._build_payload(dt_from, dt_to)
            if payload is None:
                logger.warning("No payload to send (possibly no data in window)")
                self.window_calculator.mark_success(dt_to)
                return True  # Not an error, just no data

            # Step 3.5: Decide if POST is needed
            # POST if: has sales (PDV or Loja) OR a turno closed in this window
            has_sales = payload.ops.count > 0 or payload.ops.loja_count > 0
            has_closed_turno = any(t.fechado for t in payload.turnos)

            if not has_sales and not has_closed_turno:
                logger.info("No sales and no turno closure — skipping POST")
                self.window_calculator.mark_success(dt_to)
                return True

            if has_closed_turno and not has_sales:
                logger.info(
                    "No new sales but turno CLOSED — sending closure data"
                )

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
        """Build the sync payload v4.0 from both databases."""
        logger.info("Gathering data from databases (PDV + Gestão)")

        store_id = self.settings.store_id_ponto_venda
        store_id_filial = self.settings.resolved_store_id_filial

        if self.settings.store_id_filial is None:
            logger.warning(
                "STORE_ID_FILIAL not set — using STORE_ID_PONTO_VENDA as fallback. "
                "Set STORE_ID_FILIAL in .env if PDV and Gestão use different store IDs."
            )

        # ── Store Info ──
        store_info = self.queries.get_store_info(store_id)
        store_name = store_info["nome"] if store_info else f"PDV {store_id}"
        store_cnpj = store_info.get("cnpj") if store_info else None

        # ══════════════════════════════════════
        # PDV (HiperPdv / Caixa) data
        # ══════════════════════════════════════
        ops_ids = self.queries.get_operation_ids(dt_from, dt_to)
        if not ops_ids:
            logger.info("[PDV] No operations found in window")

        # Turnos PDV (canal=HIPER_CAIXA)
        turnos_pdv = self._build_turnos(dt_from, dt_to)

        # Individual PDV sale details (marked as HIPER_CAIXA)
        vendas_pdv = self._build_sale_details(dt_from, dt_to, canal="HIPER_CAIXA")

        # PDV aggregated data
        sales_by_vendor_pdv = self.queries.get_sales_by_vendor(dt_from, dt_to)
        payments_by_method_pdv = self.queries.get_payments_by_method(dt_from, dt_to)

        # ══════════════════════════════════════
        # Gestão (Hiper / Loja) data
        # ══════════════════════════════════════
        turnos_loja = []
        try:
            loja_ids = self.gestao_queries.get_loja_operation_ids(
                dt_from, dt_to, store_id_filial
            )
            if loja_ids:
                logger.info(f"[Gestão] Found {len(loja_ids)} Loja operations in window")
            else:
                logger.info("[Gestão] No Loja operations in window")

            # Turnos Gestão (canal=HIPER_LOJA) — independent UUIDs
            turnos_loja = self._build_loja_turnos(dt_from, dt_to)

            # Individual Loja sale details (marked as HIPER_LOJA)
            vendas_loja = self._build_loja_sale_details(dt_from, dt_to)

            # Loja aggregated data
            sales_by_vendor_loja = self.gestao_queries.get_loja_sales_by_vendor(
                dt_from, dt_to, store_id_filial
            )
            payments_by_method_loja = self.gestao_queries.get_loja_payments_by_method(
                dt_from, dt_to, store_id_filial
            )
        except Exception as e:
            logger.warning(f"[Gestão] Failed to fetch Loja data: {e}")
            self._gestao_warning = f"GESTAO_DB_FAILURE: {str(e)[:200]}"
            loja_ids = []
            vendas_loja = []
            sales_by_vendor_loja = []
            payments_by_method_loja = []

        # ══════════════════════════════════════
        # Merge both channels
        # ══════════════════════════════════════
        turnos = turnos_pdv + turnos_loja
        vendas = vendas_pdv + vendas_loja
        sales_by_vendor = sales_by_vendor_pdv + sales_by_vendor_loja
        payments_by_method = payments_by_method_pdv + payments_by_method_loja

        # ── Snapshots for verification — both channels ──
        snapshot_turnos = self._build_turno_snapshots_combined()
        snapshot_vendas = self._build_venda_snapshots_combined()

        # ── Warnings ──
        warnings = self._check_warnings(sales_by_vendor, payments_by_method)

        # ── Build payload ──
        payload = build_payload(
            store_id=store_id,
            store_name=store_name,
            store_alias=self.settings.store_alias,
            dt_from=dt_from,
            dt_to=dt_to,
            window_minutes=self.settings.sync_window_minutes,
            turnos=turnos,
            vendas=vendas,
            ops_ids=ops_ids,
            sales_by_vendor=sales_by_vendor,
            payments_by_method=payments_by_method,
            snapshot_turnos=snapshot_turnos,
            snapshot_vendas=snapshot_vendas,
            warnings=warnings,
            loja_ids=loja_ids,
            store_cnpj=store_cnpj,
            store_id_filial=store_id_filial,
        )

        # Log payload summary
        pdv_count = len(vendas_pdv)
        loja_count = len(vendas_loja)
        logger.info(f"Payload built: {payload.ops.count} PDV ops + {payload.ops.loja_count} Loja ops")
        logger.info(f"  - Turnos PDV: {len(turnos_pdv)} | Turnos Loja: {len(turnos_loja)} | Total: {len(turnos)}")
        logger.info(f"  - Vendas PDV: {pdv_count} | Vendas Loja: {loja_count} | Total: {len(payload.vendas)}")
        logger.info(f"  - Vendors (resumo): {len(payload.resumo.by_vendor)}")
        logger.info(f"  - Payment methods (resumo): {len(payload.resumo.by_payment)}")
        logger.info(f"  - Snapshot turnos: {len(payload.snapshot_turnos)}")
        logger.info(f"  - Snapshot vendas: {len(payload.snapshot_vendas)}")
        if warnings:
            for w in warnings:
                logger.warning(f"  ! {w}")

        return payload

    def _build_turnos(
        self, dt_from: datetime, dt_to: datetime
    ) -> list[TurnoDetail]:
        """Build turno details with sistema totals and closure data."""
        turnos_raw = self.queries.get_turnos_with_activity(
            dt_from, dt_to, self.settings.store_id_ponto_venda
        )

        if not turnos_raw:
            # Fallback: get current turno (may not have sales in window)
            current = self.queries.get_current_turno(self.settings.store_id_ponto_venda)
            if current:
                turnos_raw = [current]

        turno_details = []
        for turno in turnos_raw:
            id_turno = turno.get("id_turno")
            if not id_turno:
                continue

            id_turno_str = str(id_turno)

            # Get system totals (op=1) for this turno
            system_payments = self.queries.get_payments_by_method_for_turno(id_turno_str)

            # Get closure values (op=9) if turno is closed
            closure_values = None
            shortage_values = None
            if turno.get("fechado"):
                closure_values = self.queries.get_turno_closure_values(id_turno_str)
                shortage_values = self.queries.get_turno_shortage_values(id_turno_str)

                if closure_values:
                    logger.info(
                        f"  Turno {turno.get('sequencial')}: "
                        f"fechado=True, {len(closure_values)} closure entries"
                    )

            # Get responsavel (principal vendor) for this turno
            responsavel = self.queries.get_turno_responsavel(id_turno_str)

            detail = build_turno_detail(
                turno=turno,
                system_payments=system_payments,
                closure_values=closure_values,
                shortage_values=shortage_values,
                responsavel=responsavel,
            )
            turno_details.append(detail)

        return turno_details

    def _build_loja_turnos(
        self, dt_from: datetime, dt_to: datetime
    ) -> list[TurnoDetail]:
        """Build turno details from Gestão DB with canal=HIPER_LOJA."""
        store_id_filial = self.settings.resolved_store_id_filial

        turnos_raw = self.gestao_queries.get_loja_turnos_with_activity(
            dt_from, dt_to, store_id_filial
        )

        if not turnos_raw:
            return []

        turno_details = []
        for turno in turnos_raw:
            id_turno = turno.get("id_turno")
            if not id_turno:
                continue

            id_turno_str = str(id_turno)

            # Get system totals (op=1, origem=2) for this Gestão turno
            system_payments = self.gestao_queries.get_loja_payments_by_method_for_turno(id_turno_str)

            # Get closure values (op=9) if turno is closed
            closure_values = None
            shortage_values = None
            if turno.get("fechado"):
                closure_values = self.gestao_queries.get_loja_turno_closure_values(id_turno_str)
                shortage_values = self.gestao_queries.get_loja_turno_shortage_values(id_turno_str)

                if closure_values:
                    logger.info(
                        f"  [Gestão] Turno {turno.get('sequencial')}: "
                        f"fechado=True, {len(closure_values)} closure entries"
                    )

            # Get responsavel (principal vendor) for this Gestão turno
            responsavel = self.gestao_queries.get_loja_turno_responsavel(id_turno_str)

            detail = build_turno_detail(
                turno=turno,
                system_payments=system_payments,
                closure_values=closure_values,
                shortage_values=shortage_values,
                responsavel=responsavel,
                canal="HIPER_LOJA",
            )
            turno_details.append(detail)

        logger.info(f"Built {len(turno_details)} Loja (Gestão) turno details")
        return turno_details

    def _build_turno_snapshot_from_rows(
        self, raw: list[dict], canal: str
    ) -> list[TurnoSnapshot]:
        """Build TurnoSnapshot objects from raw query rows."""
        snapshots = []
        for row in raw:
            inicio = row.get("data_hora_inicio")
            periodo = None
            if inicio:
                hora = inicio.hour if hasattr(inicio, 'hour') else 0
                if hora < 12:
                    periodo = "MATUTINO"
                elif hora < 18:
                    periodo = "VESPERTINO"
                else:
                    periodo = "NOTURNO"
                inicio = _aware(inicio)

            termino = row.get("data_hora_termino")
            if termino:
                termino = _aware(termino)

            snapshots.append(
                TurnoSnapshot(
                    canal=canal,
                    id_turno=str(row["id_turno"]) if row.get("id_turno") else None,
                    sequencial=row.get("sequencial"),
                    fechado=bool(row.get("fechado", True)),
                    data_hora_inicio=inicio,
                    data_hora_termino=termino,
                    duracao_minutos=row.get("duracao_minutos"),
                    periodo=periodo,
                    operador=OperatorInfo(
                        id_usuario=row.get("id_operador"),
                        nome=row.get("nome_operador"),
                        login=row.get("login_operador"),
                    ),
                    responsavel=OperatorInfo(
                        id_usuario=row.get("id_responsavel"),
                        nome=row.get("nome_responsavel"),
                        login=row.get("login_responsavel"),
                    ),
                    qtd_vendas=row.get("qtd_vendas", 0),
                    total_vendas=row.get("total_vendas", 0),
                    qtd_vendedores=row.get("qtd_vendedores", 0),
                )
            )
        return snapshots

    def _build_turno_snapshots_combined(self) -> list[TurnoSnapshot]:
        """
        Build turno snapshots from BOTH channels (PDV + Gestão).
        Combines last 10 PDV + last 10 Gestão, sorts by date, takes top 10.
        """
        store_id = self.settings.store_id_ponto_venda
        store_id_filial = self.settings.resolved_store_id_filial

        # ── PDV turno snapshots ──
        pdv_raw = self.queries.get_turno_snapshot(store_id, limit=20)
        pdv_snapshots = self._build_turno_snapshot_from_rows(pdv_raw, "HIPER_CAIXA")

        # ── Gestão turno snapshots ──
        loja_snapshots = []
        try:
            loja_raw = self.gestao_queries.get_loja_turno_snapshot(store_id_filial, limit=20)
            loja_snapshots = self._build_turno_snapshot_from_rows(loja_raw, "HIPER_LOJA")
        except Exception as e:
            logger.warning(f"[Gestão] Failed to fetch Loja turno snapshots: {e}")

        # ── Combine and sort by data_hora_inicio DESC, take top 20 ──
        all_snapshots = pdv_snapshots + loja_snapshots
        all_snapshots.sort(
            key=lambda s: s.data_hora_inicio or datetime.min,
            reverse=True,
        )
        combined = all_snapshots[:20]

        pdv_count = sum(1 for s in combined if s.canal == "HIPER_CAIXA")
        loja_count = sum(1 for s in combined if s.canal == "HIPER_LOJA")
        logger.info(
            f"Built {len(combined)} turno snapshots "
            f"(PDV: {pdv_count}, Gestão: {loja_count})"
        )
        return combined

    def _build_venda_snapshots_combined(self) -> list[VendaSnapshot]:
        """
        Build venda snapshots from BOTH channels (últimas vendas gerais).
        Combines last 10 PDV + last 10 Loja, sorts by date, takes top 10.
        """
        store_id = self.settings.store_id_ponto_venda

        # ── PDV snapshots ──
        pdv_raw = self.queries.get_vendas_snapshot(store_id, limit=30)
        pdv_snapshots = []
        for row in pdv_raw:
            pdv_snapshots.append(
                VendaSnapshot(
                    id_operacao=row["id_operacao"],
                    canal="HIPER_CAIXA",
                    data_hora_inicio=_aware(row.get("data_hora_inicio")),
                    data_hora_termino=_aware(row.get("data_hora_termino")),
                    duracao_segundos=row.get("duracao_segundos"),
                    id_turno=str(row["id_turno"]) if row.get("id_turno") else None,
                    turno_seq=row.get("turno_seq"),
                    vendedor=OperatorInfo(
                        id_usuario=row.get("id_vendedor"),
                        nome=row.get("nome_vendedor"),
                        login=row.get("login_vendedor"),
                    ),
                    qtd_itens=row.get("qtd_itens", 0),
                    total_itens=row.get("total_itens", 0),
                )
            )

        # ── Loja snapshots ──
        loja_snapshots = []
        try:
            loja_raw = self.gestao_queries.get_loja_vendas_snapshot(
                self.settings.resolved_store_id_filial, limit=30
            )
            for row in loja_raw:
                loja_snapshots.append(
                    VendaSnapshot(
                        id_operacao=row["id_operacao"],
                        canal="HIPER_LOJA",
                        data_hora_inicio=_aware(row.get("data_hora_inicio")),
                        data_hora_termino=_aware(row.get("data_hora_termino")),
                        duracao_segundos=row.get("duracao_segundos"),
                        id_turno=str(row["id_turno"]) if row.get("id_turno") else None,
                        turno_seq=None,  # Loja doesn't have turno_seq
                        vendedor=OperatorInfo(
                            id_usuario=row.get("id_vendedor"),
                            nome=row.get("nome_vendedor"),
                            login=row.get("login_vendedor"),
                        ),
                        qtd_itens=row.get("qtd_itens", 0),
                        total_itens=row.get("total_itens", 0),
                    )
                )
        except Exception as e:
            logger.warning(f"[Gestão] Failed to fetch Loja snapshots: {e}")

        # ── Combine and sort by data_hora_termino DESC, take top 30 ──
        all_snapshots = pdv_snapshots + loja_snapshots
        all_snapshots.sort(
            key=lambda s: s.data_hora_termino or datetime.min,
            reverse=True,
        )
        combined = all_snapshots[:30]

        pdv_count = sum(1 for s in combined if s.canal == "HIPER_CAIXA")
        loja_count = sum(1 for s in combined if s.canal == "HIPER_LOJA")
        logger.info(
            f"Built {len(combined)} venda snapshots "
            f"(PDV: {pdv_count}, Loja: {loja_count})"
        )
        return combined

    def _build_sale_details(
        self, dt_from: datetime, dt_to: datetime,
        canal: str = "HIPER_CAIXA",
    ) -> list[SaleDetail]:
        """Build individual PDV sale details with items and payments."""
        sale_items = self.queries.get_sale_items(dt_from, dt_to)
        sale_payments = self.queries.get_sale_payments(dt_from, dt_to)

        if not sale_items:
            return []

        vendas = build_sale_details(sale_items, sale_payments, canal=canal)
        logger.info(f"Built {len(vendas)} individual {canal} sale details")
        return vendas

    def _build_loja_sale_details(
        self, dt_from: datetime, dt_to: datetime,
    ) -> list[SaleDetail]:
        """Build individual Loja sale details with items and payments."""
        store_id_filial = self.settings.resolved_store_id_filial

        sale_items = self.gestao_queries.get_loja_sale_items(
            dt_from, dt_to, store_id_filial
        )
        sale_payments = self.gestao_queries.get_loja_sale_payments(
            dt_from, dt_to, store_id_filial
        )

        if not sale_items:
            return []

        vendas = build_sale_details(sale_items, sale_payments, canal="HIPER_LOJA")
        logger.info(f"Built {len(vendas)} individual HIPER_LOJA sale details")
        return vendas

    def _check_warnings(
        self,
        sales_by_vendor: list[dict],
        payments_by_method: list[dict],
    ) -> list[str]:
        """Check for any data quality warnings."""
        warnings = []

        # Include Gestão DB failure warning if present
        if self._gestao_warning:
            warnings.append(self._gestao_warning)
            self._gestao_warning = None  # Reset for next cycle

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
        payload_dict = payload.model_dump(mode="json", by_alias=True)
        return self.sender.send(payload_dict)


def create_runner(settings: Settings) -> SyncRunner:
    """Factory function to create a fully configured SyncRunner."""
    # PDV (HiperPdv) connection
    db = create_db_connection(settings)
    queries = create_query_executor(db)

    # Gestão (Hiper) connection
    gestao_db = create_gestao_db_connection(settings)
    gestao_queries = create_gestao_query_executor(gestao_db)

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
        gestao_db=gestao_db,
        gestao_queries=gestao_queries,
        sender=sender,
        state_manager=state_manager,
        window_calculator=window_calculator,
    )
