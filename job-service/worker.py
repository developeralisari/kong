import os
import json
import logging
import asyncio
import signal
from aiokafka import AIOKafkaConsumer
import httpx
import psycopg2
from psycopg2.extras import Json
from psycopg2 import pool

# ═══════════════════════════════════════════════════════════════════════════
# Logging
# ═══════════════════════════════════════════════════════════════════════════
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════════
# Environment variables
# ═══════════════════════════════════════════════════════════════════════════
KAFKA_BROKERS = os.environ.get('KAFKA_BROKERS', 'kafka:9092')
KAFKA_TOPIC = os.environ.get('KAFKA_TOPIC', 'llm-jobs')
KAFKA_GROUP_ID = os.environ.get('KAFKA_GROUP_ID', 'kong-log-worker-group')

PG_HOST = os.environ.get('PG_HOST', 'kong-database')
PG_PORT = os.environ.get('PG_PORT', '5432')
PG_USER = os.environ.get('PG_USER', 'kong')
PG_PASSWORD = os.environ.get('PG_PASSWORD', 'kong')
PG_DATABASE = os.environ.get('PG_DATABASE', 'kong')

VLLM_URL = os.environ.get('VLLM_URL', 'http://213.173.107.138:20804/v1/chat/completions')
CONCURRENCY_LIMIT = int(os.environ.get('CONCURRENCY_LIMIT', '128'))
VLLM_TIMEOUT = int(os.environ.get('VLLM_TIMEOUT', '120'))

# ═══════════════════════════════════════════════════════════════════════════
# DB connection pool
# ═══════════════════════════════════════════════════════════════════════════
db_pool = None

def init_db_pool():
    global db_pool
    db_pool = pool.ThreadedConnectionPool(
        minconn=2,
        maxconn=20,
        host=PG_HOST,
        port=PG_PORT,
        user=PG_USER,
        password=PG_PASSWORD,
        database=PG_DATABASE
    )
    logger.info("DB connection pool initialized (min=2, max=20).")


def update_job_status(job_id, status, result=None, error=None):
    conn = None
    try:
        conn = db_pool.getconn()
        cur = conn.cursor()
        if result is not None:
            cur.execute(
                "UPDATE llm_jobs SET status = %s, result = %s, updated_at = NOW() WHERE job_id = %s",
                (status, Json(result), job_id)
            )
        elif error is not None:
            cur.execute(
                "UPDATE llm_jobs SET status = %s, error = %s, updated_at = NOW() WHERE job_id = %s",
                (status, error, job_id)
            )
        else:
            cur.execute(
                "UPDATE llm_jobs SET status = %s, updated_at = NOW() WHERE job_id = %s",
                (status, job_id)
            )
        conn.commit()
        cur.close()
    except Exception as e:
        logger.error(f"Failed to update job {job_id} in DB: {e}")
        if conn:
            conn.rollback()
    finally:
        if conn:
            db_pool.putconn(conn)


async def process_job(job_id, payload, client):
    logger.info(f"[job={job_id}] Processing...")
    await asyncio.to_thread(update_job_status, job_id, "PROCESSING")

    try:
        response = await client.post(VLLM_URL, json=payload, timeout=float(VLLM_TIMEOUT))

        if response.status_code == 200:
            result = response.json()
            logger.info(f"[job={job_id}] Completed successfully.")
            await asyncio.to_thread(update_job_status, job_id, "COMPLETED", result=result)
        else:
            error_msg = f"vLLM HTTP {response.status_code}: {response.text[:500]}"
            logger.error(f"[job={job_id}] {error_msg}")
            await asyncio.to_thread(update_job_status, job_id, "FAILED", error=error_msg)
    except httpx.TimeoutException:
        error_msg = f"vLLM timeout after {VLLM_TIMEOUT}s"
        logger.error(f"[job={job_id}] {error_msg}")
        await asyncio.to_thread(update_job_status, job_id, "FAILED", error=error_msg)
    except Exception as e:
        logger.error(f"[job={job_id}] Unexpected error: {e}")
        await asyncio.to_thread(update_job_status, job_id, "FAILED", error=str(e))


async def main():
    logger.info("═══════════════════════════════════════════════════")
    logger.info("  Async Kafka Job Worker Starting...")
    logger.info(f"  Kafka: {KAFKA_BROKERS} | Topic: {KAFKA_TOPIC}")
    logger.info(f"  vLLM:  {VLLM_URL}")
    logger.info(f"  Concurrency Limit: {CONCURRENCY_LIMIT}")
    logger.info("═══════════════════════════════════════════════════")

    semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)

    await asyncio.to_thread(init_db_pool)

    consumer = AIOKafkaConsumer(
        KAFKA_TOPIC,
        bootstrap_servers=KAFKA_BROKERS,
        group_id=KAFKA_GROUP_ID,
        auto_offset_reset='earliest',
        enable_auto_commit=False
    )
    await consumer.start()
    logger.info(f"Subscribed to topic: {KAFKA_TOPIC}")

    shutdown_event = asyncio.Event()

    def signal_handler():
        logger.info("Shutdown signal received, waiting for active tasks...")
        shutdown_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, signal_handler)
        except NotImplementedError:
            pass

    async with httpx.AsyncClient() as client:
        try:
            while not shutdown_event.is_set():
                # Poll a batch of messages
                msg_pack = await consumer.getmany(timeout_ms=1000, max_records=CONCURRENCY_LIMIT)
                
                if not msg_pack:
                    continue
                
                tasks = []
                for tp, msgs in msg_pack.items():
                    for msg in msgs:
                        try:
                            data = json.loads(msg.value.decode('utf-8'))
                            job_id = data.get('job_id')
                            payload = data.get('payload')

                            if not job_id or not payload:
                                logger.error(f"Invalid message format, skipping: {data}")
                                continue

                            # Create processing task
                            task = asyncio.create_task(process_job(job_id, payload, client))
                            tasks.append(task)
                        except Exception as e:
                            logger.error(f"Failed to parse Kafka message: {e}")
                
                if tasks:
                    logger.debug(f"Awaiting {len(tasks)} concurrent tasks...")
                    await asyncio.gather(*tasks, return_exceptions=True)
                    
                    # Safe commit only after the entire batch is completed
                    try:
                        await consumer.commit()
                    except Exception as e:
                        logger.warning(f"Batch offset commit failed (non-fatal): {e}")

        except asyncio.CancelledError:
            logger.info("Main loop cancelled.")
        finally:
            await consumer.stop()
            logger.info("Kafka consumer stopped.")

            if db_pool:
                db_pool.closeall()
                logger.info("DB connection pool closed.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Process stopped by KeyboardInterrupt.")
