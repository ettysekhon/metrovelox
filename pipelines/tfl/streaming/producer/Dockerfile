FROM python:3.12-slim

# librdkafka (runtime dep of confluent-kafka) is pulled in via pip
# wheels now, but gcc is needed only on architectures without prebuilt
# wheels. Keep the base image slim otherwise.
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY tfl_producer_strimzi.py ./

CMD ["python", "tfl_producer_strimzi.py"]
