import time
import logging
import threading
import paho.mqtt.client as mqtt
from datetime import datetime, timezone
from database import SessionLocal
from models import Chicken, TemperatureReading
from config import settings
from utils import is_valid_chicken_id

logger = logging.getLogger(__name__)


def on_message(client, userdata, msg):
    try:
        payload = float(msg.payload.decode("utf-8").strip())
    except ValueError:
        return

    parts = msg.topic.split("/")
    if len(parts) != 3 or parts[0] != settings.MQTT_TOPIC_PREFIX:
        return

    _, chicken_id, data_type = parts

    if not is_valid_chicken_id(chicken_id):
        logger.warning("Invalid chicken_id from MQTT: %r", chicken_id)
        return

    db = SessionLocal()
    try:
        chicken = db.query(Chicken).filter(Chicken.chicken_id == chicken_id).first()

        if not chicken:
            try:
                chicken = Chicken(chicken_id=chicken_id)
                db.add(chicken)
                db.flush()
            except Exception:
                db.rollback()
                chicken = db.query(Chicken).filter(Chicken.chicken_id == chicken_id).first()
                if not chicken:
                    raise

        if data_type == "Temperature":
            chicken.last_temperature = payload
            chicken.last_seen = datetime.now(timezone.utc)

            reading = TemperatureReading(
                chicken_id=chicken_id,
                temperature=payload,
                voltage=chicken.voltage
            )
            db.add(reading)
            db.commit()

        elif data_type == "voltage":
            chicken.voltage = payload
            chicken.last_seen = datetime.now(timezone.utc)
            db.commit()

    except Exception as e:
        db.rollback()
        logger.exception("DB error processing MQTT message: %s", e)
    finally:
        db.close()


def _reconnect_loop(client):
    delay = 1
    while True:
        try:
            client.reconnect()
            logger.info("MQTT reconnected successfully")
            break
        except Exception as e:
            logger.warning("MQTT reconnect failed: %s, retrying in %ds...", e, delay)
            time.sleep(delay)
            delay = min(delay * 2, 60)


def on_disconnect(client, userdata, rc):
    if rc != 0:
        logger.warning("MQTT disconnected unexpectedly (rc=%d), reconnecting...", rc)
        threading.Thread(target=_reconnect_loop, args=(client,), daemon=True).start()


def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("Connected to MQTT broker %s", settings.MQTT_HOST)
        client.subscribe(f"{settings.MQTT_TOPIC_PREFIX}/+/Temperature")
        client.subscribe(f"{settings.MQTT_TOPIC_PREFIX}/+/voltage")
    else:
        logger.error("MQTT connection failed, rc=%d", rc)


def start_mqtt():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1)
    client.username_pw_set(settings.MQTT_USERNAME, settings.MQTT_PASSWORD)
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    try:
        client.connect(settings.MQTT_HOST, settings.MQTT_PORT, keepalive=60)
        client.loop_start()
    except Exception as e:
        logger.warning("MQTT broker not available (%s), will retry in background...", e)
        client.loop_start()
        threading.Thread(target=_reconnect_loop, args=(client,), daemon=True).start()
    return client
