#!/usr/bin/env python3
"""
PDV Sync Agent - Entry Point

This agent syncs sales data from the local SQL Server (HiperPdv) to a central API.
Designed to run via Windows Task Scheduler every 10 minutes.

Usage:
    pdv-sync-agent.exe                                   # Run once
    pdv-sync-agent.exe --loop                            # Run continuously
    pdv-sync-agent.exe --config "C:\\\\path\\\\.env"         # Custom config
    pdv-sync-agent.exe --doctor                          # Diagnostic check
    pdv-sync-agent.exe --version                         # Show version
"""

import argparse
import os
import sys
from pathlib import Path

from loguru import logger

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from src.settings import load_settings, detect_odbc_driver
from src.runner import create_runner

__version__ = "1.1.0"


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        prog="pdv-sync-agent",
        description="PDV Sync Agent - Sincronização de vendas PDV para API central",
    )
    parser.add_argument(
        "--loop",
        action="store_true",
        help="Rodar continuamente com scheduler interno (APScheduler)",
    )
    parser.add_argument(
        "--config",
        type=str,
        default=None,
        help="Caminho absoluto para o arquivo .env de configuração",
    )
    parser.add_argument(
        "--doctor",
        action="store_true",
        help="Executar diagnóstico completo do ambiente (config, DB, API, drivers)",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    return parser.parse_args()


def setup_logging(log_file: Path, level: str, rotation: str, retention: str) -> None:
    """Configure loguru logging."""
    # Remove default handler
    logger.remove()

    # Add console handler with colors
    logger.add(
        sys.stderr,
        level=level,
        format=(
            "<green>{time:YYYY-MM-DD HH:mm:ss}</green> | "
            "<level>{level: <8}</level> | "
            "<cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> | "
            "<level>{message}</level>"
        ),
        colorize=True,
    )

    # Ensure log directory exists
    log_file.parent.mkdir(parents=True, exist_ok=True)

    # Add file handler with rotation
    logger.add(
        log_file,
        level=level,
        format="{time:YYYY-MM-DD HH:mm:ss} | {level: <8} | {name}:{function}:{line} | {message}",
        rotation=rotation,
        retention=retention,
        compression="zip",
        encoding="utf-8",
    )


def run_doctor(config_path: str = None) -> int:
    """
    Run complete environment diagnostic.
    Checks: config, filesystem, ODBC driver, DB connection, API reachability.
    """
    print()
    print("=" * 60)
    print("  PDV Sync Agent — Diagnóstico (--doctor)")
    print("=" * 60)
    print()

    results = []
    all_ok = True

    def check(name: str, fn):
        nonlocal all_ok
        try:
            ok, msg = fn()
            status = "✅ OK" if ok else "❌ FAIL"
            if not ok:
                all_ok = False
            results.append((name, status, msg))
            print(f"  [{status}] {name}")
            if msg:
                for line in msg.split("\n"):
                    print(f"         {line}")
            print()
        except Exception as e:
            all_ok = False
            results.append((name, "❌ FAIL", str(e)))
            print(f"  [❌ FAIL] {name}")
            print(f"         {e}")
            print()

    # 1. Config file
    def check_config():
        try:
            settings = load_settings(config_path=config_path)
            cfg_path = config_path or ".env"
            return True, f"Config: {Path(cfg_path).resolve()}"
        except Exception as e:
            return False, f"Erro ao carregar config: {e}"

    check("1. Arquivo de Configuração", check_config)

    # If config failed, we can't continue
    settings = None
    try:
        settings = load_settings(config_path=config_path)
    except Exception:
        print("  ⛔ Config inválido. Corrija antes de continuar.")
        return 1

    # 2. Filesystem (ProgramData writable)
    def check_filesystem():
        errors = []
        for path_name, path in [
            ("State Dir", settings.state_file.parent),
            ("Outbox Dir", settings.outbox_dir),
            ("Log Dir", settings.log_file.parent),
        ]:
            path = Path(path)
            path.mkdir(parents=True, exist_ok=True)
            test_file = path / ".doctor_test"
            try:
                test_file.write_text("test")
                test_file.unlink()
            except PermissionError:
                errors.append(f"Sem permissão de escrita: {path}")
            except Exception as e:
                errors.append(f"Erro em {path}: {e}")

        if errors:
            return False, "\n".join(errors)
        return True, f"State: {settings.state_file.parent}\nOutbox: {settings.outbox_dir}\nLogs: {settings.log_file.parent}"

    check("2. Permissões de Escrita (Filesystem)", check_filesystem)

    # 3. ODBC Driver
    def check_odbc():
        try:
            driver = detect_odbc_driver()
            return True, f"Driver: {driver}"
        except RuntimeError as e:
            return False, str(e)

    check("3. Driver ODBC", check_odbc)

    # 4. Database connection
    def check_database():
        from src.db import create_db_connection
        db = create_db_connection(settings)
        return db.test_connection()

    check("4. Conexão SQL Server", check_database)

    # 5. Minimal query
    def check_query():
        from src.db import create_db_connection
        db = create_db_connection(settings)
        try:
            count = db.execute_scalar(
                "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'operacao_pdv'"
            )
            if count and count > 0:
                return True, "Tabela 'operacao_pdv' encontrada"
            else:
                return False, "Tabela 'operacao_pdv' NÃO encontrada no banco"
        except Exception as e:
            return False, str(e)

    check("5. Query de Teste (operacao_pdv)", check_query)

    # 6. API reachability
    def check_api():
        import requests
        try:
            # Try a HEAD/GET to check if the endpoint is reachable
            resp = requests.post(
                settings.api_endpoint,
                json={"doctor": True},
                headers={
                    "Authorization": f"Bearer {settings.api_token}",
                    "Content-Type": "application/json",
                },
                timeout=10,
            )
            return True, f"API respondeu: HTTP {resp.status_code} ({settings.api_endpoint[:50]}...)"
        except requests.ConnectionError:
            return False, f"Não foi possível conectar em: {settings.api_endpoint}"
        except requests.Timeout:
            return False, "API não respondeu em 10 segundos (timeout)"
        except Exception as e:
            return False, f"Erro: {e}"

    check("6. API Endpoint", check_api)

    # Summary
    print("=" * 60)
    if all_ok:
        print("  ✅ TUDO OK — Ambiente pronto para produção!")
    else:
        print("  ❌ PROBLEMAS ENCONTRADOS — Corrija os itens acima!")
        failed = [r for r in results if "FAIL" in r[1]]
        print(f"  ({len(failed)} falha(s) de {len(results)} verificações)")
    print("=" * 60)
    print()

    # Save to log
    try:
        log_path = settings.log_file.parent / "doctor.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as f:
            from datetime import datetime
            f.write(f"PDV Sync Agent Doctor — {datetime.now().isoformat()}\n")
            f.write("=" * 60 + "\n")
            for name, status, msg in results:
                f.write(f"[{status}] {name}\n")
                if msg:
                    for line in msg.split("\n"):
                        f.write(f"    {line}\n")
                f.write("\n")
        print(f"  Relatório salvo em: {log_path}")
    except Exception:
        pass

    return 0 if all_ok else 1


def run_once(config_path: str = None) -> int:
    """Run the sync once and exit."""
    try:
        # Load settings
        settings = load_settings(config_path=config_path)

        # Setup logging
        setup_logging(
            log_file=settings.log_file,
            level=settings.log_level,
            rotation=settings.log_rotation,
            retention=settings.log_retention,
        )

        # Log configuration
        settings.log_config()

        # Create and run the sync
        runner = create_runner(settings)
        success = runner.run()

        return 0 if success else 1

    except Exception as e:
        logger.exception(f"Fatal error: {e}")
        return 1


def run_loop(config_path: str = None) -> None:
    """Run continuously with APScheduler."""
    try:
        from apscheduler.schedulers.blocking import BlockingScheduler
        from apscheduler.triggers.interval import IntervalTrigger

        # Load settings first
        settings = load_settings(config_path=config_path)

        # Setup logging
        setup_logging(
            log_file=settings.log_file,
            level=settings.log_level,
            rotation=settings.log_rotation,
            retention=settings.log_retention,
        )

        # Log configuration
        settings.log_config()

        logger.info(f"Starting continuous mode with {settings.sync_window_minutes} minute interval")

        # Create runner
        runner = create_runner(settings)

        # Create scheduler
        scheduler = BlockingScheduler()

        # Add job
        scheduler.add_job(
            runner.run,
            trigger=IntervalTrigger(minutes=settings.sync_window_minutes),
            id="pdv_sync",
            name="PDV Sync Job",
            replace_existing=True,
        )

        # Run immediately on start
        runner.run()

        # Start scheduler
        logger.info("Scheduler started. Press Ctrl+C to exit.")
        scheduler.start()

    except ImportError:
        logger.error("APScheduler not installed. Install with: pip install apscheduler")
        sys.exit(1)
    except KeyboardInterrupt:
        logger.info("Scheduler stopped by user")
    except Exception as e:
        logger.exception(f"Fatal error in loop mode: {e}")
        sys.exit(1)


def main() -> int:
    """Main entry point."""
    args = parse_args()

    if args.doctor:
        return run_doctor(config_path=args.config)
    elif args.loop:
        run_loop(config_path=args.config)
        return 0
    else:
        return run_once(config_path=args.config)


if __name__ == "__main__":
    sys.exit(main())
