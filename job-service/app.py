import os
import uuid
import json
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from aiokafka import AIOKafkaProducer
import psycopg2
from psycopg2 import pool
from psycopg2.extras import Json

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# DB connection pool (global, lifespan'da init edilir)
db_pool = None

# Environment variables
KAFKA_BROKERS = os.environ.get('KAFKA_BROKERS', 'kafka:9092')
KAFKA_TOPIC = os.environ.get('KAFKA_TOPIC', 'llm-jobs')

PG_HOST = os.environ.get('PG_HOST', 'kong-database')
PG_PORT = os.environ.get('PG_PORT', '5432')
PG_USER = os.environ.get('PG_USER', 'kong')
PG_PASSWORD = os.environ.get('PG_PASSWORD', 'kong')
PG_DATABASE = os.environ.get('PG_DATABASE', 'kong')

# Initialize Kafka Producer
producer = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup ve shutdown lifecycle yönetimi."""
    global db_pool
    # ── Startup ──
    db_pool = pool.ThreadedConnectionPool(
        minconn=2,
        maxconn=10,
        host=PG_HOST,
        port=PG_PORT,
        user=PG_USER,
        password=PG_PASSWORD,
        database=PG_DATABASE
    )
    logger.info("DB connection pool initialized.")

    # Initialize Kafka Producer
    global producer
    producer = AIOKafkaProducer(
        bootstrap_servers=KAFKA_BROKERS,
        client_id='job-api-producer'
    )
    await producer.start()
    logger.info("Kafka producer started.")

    # Tablo oluştur
    conn = db_pool.getconn()
    try:
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS llm_jobs (
                job_id VARCHAR(255) PRIMARY KEY,
                status VARCHAR(50) NOT NULL,
                payload JSONB NOT NULL,
                result JSONB,
                error TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
        cur.close()
        logger.info("Database initialized (llm_jobs table created/verified).")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
    finally:
        db_pool.putconn(conn)

    yield  # ── Uygulama çalışıyor ──

    # ── Shutdown ──
    if producer:
        await producer.stop()
        logger.info("Kafka producer stopped.")
    if db_pool:
        db_pool.closeall()
    logger.info("Cleanup complete.")


app = FastAPI(title="LLM Job API", lifespan=lifespan)

@app.post("/v1/chat/completions")
async def create_chat_completion(request: Request):
    try:
        body = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    job_id = str(uuid.uuid4())
    
    # Save PENDING job to DB
    conn = None
    try:
        conn = db_pool.getconn()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO llm_jobs (job_id, status, payload) VALUES (%s, %s, %s)",
            (job_id, "PENDING", Json(body))
        )
        conn.commit()
        cur.close()
    except Exception as e:
        logger.error(f"Failed to insert job into database: {e}")
        if conn:
            conn.rollback()
        raise HTTPException(status_code=500, detail="Database error")
    finally:
        if conn:
            db_pool.putconn(conn)

    # Send Job to Kafka
    kafka_payload = {
        "job_id": job_id,
        "payload": body
    }
    
    try:
        await producer.send_and_wait(
            KAFKA_TOPIC,
            key=job_id.encode('utf-8'),
            value=json.dumps(kafka_payload).encode('utf-8')
        )
        logger.info(f"Message delivered to {KAFKA_TOPIC} [job_id={job_id}]")
    except Exception as e:
        logger.error(f"Failed to send job to Kafka: {e}")
        # Update job to FAILED in DB
        conn = None
        try:
            conn = db_pool.getconn()
            cur = conn.cursor()
            cur.execute(
                "UPDATE llm_jobs SET status = 'FAILED', error = %s, updated_at = NOW() WHERE job_id = %s",
                (f"Kafka error: {str(e)}", job_id)
            )
            conn.commit()
            cur.close()
        except Exception as db_err:
            logger.error(f"Failed to update status to FAILED: {db_err}")
            if conn:
                conn.rollback()
        finally:
            if conn:
                db_pool.putconn(conn)

        raise HTTPException(status_code=500, detail="Queue error")

    return JSONResponse(
        status_code=202,
        content={"job_id": job_id, "status": "PENDING", "message": "Job queued successfully"}
    )

@app.get("/v1/jobs/{job_id}")
async def get_job_status(job_id: str):
    conn = None
    try:
        conn = db_pool.getconn()
        cur = conn.cursor()
        cur.execute(
            "SELECT status, result, error, created_at, updated_at FROM llm_jobs WHERE job_id = %s",
            (job_id,)
        )
        row = cur.fetchone()
        cur.close()
    except Exception as e:
        logger.error(f"Database query failed: {e}")
        raise HTTPException(status_code=500, detail="Database query failed")
    finally:
        if conn:
            db_pool.putconn(conn)

    if not row:
        raise HTTPException(status_code=404, detail="Job not found")

    status, result, error, created_at, updated_at = row
    response_content = {
        "job_id": job_id,
        "status": status,
        "created_at": created_at.isoformat(),
        "updated_at": updated_at.isoformat()
    }
    
    if result is not None:
        response_content["result"] = result
    if error is not None:
        response_content["error"] = error

    return JSONResponse(status_code=200, content=response_content)
