FROM ubuntu:26.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends netplan.io python3-yaml \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["python3", "/review/tests/test_setup.py"]
