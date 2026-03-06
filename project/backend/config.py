from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    MQTT_HOST: str = ""
    MQTT_PORT: int = 1883
    MQTT_USERNAME: str = ""
    MQTT_PASSWORD: str = ""
    MQTT_TOPIC_PREFIX: str = "ThermoChicken"

    DATABASE_URL: str = "postgresql+psycopg://chicken:chicken@localhost/chicken_monitor"

    TEMP_GREEN_MIN: float = 38.0
    TEMP_GREEN_MAX: float = 41.5
    TEMP_YELLOW_MAX: float = 42.5

    class Config:
        env_file = "../.env"

settings = Settings()
