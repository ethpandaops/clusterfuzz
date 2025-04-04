FROM ubuntu:20.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Add deadsnakes PPA for Python 3.11
RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update

# Install Python 3.11 and other dependencies
RUN apt-get install -y --no-install-recommends \
    libssl-dev \
    ca-certificates \
    python3.10 \
    python3.10-dev \
    python3.10-venv \
    python3.10-distutils \
    git \
    curl \
    wget \
    build-essential \
    lsb-release \
    sudo \
    && rm -rf /var/lib/apt/lists/* && \
    # Install pip and newer pipenv
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3.10 get-pip.py && \
    python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --upgrade pipenv

# Install Node.js and npm
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g bower polymer-bundler

# Install Go
RUN wget https://go.dev/dl/go1.21.6.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz && \
    rm go1.21.6.linux-amd64.tar.gz

# Add Go to PATH
ENV PATH=$PATH:/usr/local/go/bin

# Install Java 21
RUN apt-get update && \
    apt-get install -y wget apt-transport-https && \
    mkdir -p /etc/apt/keyrings && \
    wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | tee /etc/apt/keyrings/adoptium.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" | tee /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && \
    apt-get install -y temurin-21-jre && \
    rm -rf /var/lib/apt/lists/*

# Install Google Cloud SDK
RUN echo "deb http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - && \
    apt-get update && \
    apt-get install -y google-cloud-sdk \
    google-cloud-sdk-pubsub-emulator \
    google-cloud-sdk-datastore-emulator && \
    rm -rf /var/lib/apt/lists/*

# Clone ClusterFuzz
RUN git clone --depth=1 https://github.com/google/clusterfuzz.git /clusterfuzz

# Set working directory
WORKDIR /clusterfuzz

# Set Python environment variables
ENV PYTHON=python3.10
ENV PATH="/home/clusterfuzz/.local/bin:${PATH}"

# Run install script and bower install as root
RUN bash ./local/install_deps.bash && \
    bower install --allow-root && \
    # Patch run_server.py to bind to 0.0.0.0
    sed -i 's/127.0.0.1/0.0.0.0/g' src/local/butler/run_server.py

# Create a non-root user
RUN useradd -m clusterfuzz && \
    chown -R clusterfuzz:clusterfuzz /clusterfuzz

# Switch to non-root user
USER clusterfuzz

# Install dependencies
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    cd /clusterfuzz && \
    uv venv && \
    . .venv/bin/activate && \
    # Install pip in virtual environment
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3.10 get-pip.py && \
    # Install pipenv
    python3.10 -m pip install pipenv && \
    # Generate requirements from root Pipfile
    python3.10 -m pipenv requirements > root_requirements.txt && \
    # Generate requirements from src Pipfile
    cd src && \
    python3.10 -m pipenv requirements > src_requirements.txt && \
    # Install all requirements
    cd .. && \
    uv pip install -r root_requirements.txt && \
    uv pip install -r src/src_requirements.txt && \
    uv pip install gunicorn

#RUN cd /clusterfuzz && \
#    . .venv/bin/activate && \
#    python3.10 butler.py run_server --bootstrap 

# Create entrypoint script
RUN echo '#!/bin/bash\n\
    cd /clusterfuzz\n\
    export PATH="/home/clusterfuzz/.local/bin:/home/clusterfuzz/.npm-global/bin:$PATH"\n\
    source .venv/bin/activate\n\
    python3.10 butler.py run_server --bootstrap' > /home/clusterfuzz/entrypoint.sh && \
    chmod +x /home/clusterfuzz/entrypoint.sh

# Command to run the server
EXPOSE 9000
CMD ["/home/clusterfuzz/entrypoint.sh"] 