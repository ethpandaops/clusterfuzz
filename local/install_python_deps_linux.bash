#!/bin/bash -ex
#
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Setup virtual environment and install python dependencies.
echo "Setting up Python environment with uv"

# Install Python 3.11 if not present
if ! command -v python3.11 &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y python3.11 python3.11-dev
fi

# Install uv if not present
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Create and activate virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
  rm -rf "$VENV_DIR"
fi

# Create virtual environment with uv
if ! uv venv "$VENV_DIR" --python python3.11; then
    echo "Failed to create virtual environment"
    exit 1
fi
source "$VENV_DIR/bin/activate"

# Verify we're using the virtual environment
if [ -z "$VIRTUAL_ENV" ]; then
    echo "Not in virtual environment"
    exit 1
fi

# Install dependencies using uv
cd src

# Install packages with specific version for google-cloud-profiler
if ! uv pip install -r requirements.txt; then
    echo "Failed to install requirements"
    exit 1
fi

if ! uv pip install "google-cloud-profiler<4.0.0"; then
    echo "Failed to install google-cloud-profiler"
    exit 1
fi

if ! uv pip install gunicorn; then
    echo "Failed to install gunicorn"
    exit 1
fi

# Install other dependencies (e.g. bower).
nodeenv -p --prebuilt
# Unsafe perm flag allows bower and polymer-bundler install for root users as well.
npm install --unsafe-perm -g bower polymer-bundler
bower --allow-root install

# Run the full bootstrap script to prepare for ClusterFuzz development.
python butler.py bootstrap

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
