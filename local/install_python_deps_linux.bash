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
    sudo apt-get install -y python3.11 python3.11-dev python3.11-venv
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

# Create virtual environment with Python 3.11
python3.11 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

# Install dependencies using uv
cd src
# Convert Pipfile to requirements.txt
uv pip install pipenv
python -m pipenv requirements > requirements.txt

# Install packages with specific version for google-cloud-profiler
uv pip install -r requirements.txt
uv pip install "google-cloud-profiler<4.0.0"  # Use older version compatible with Python 3.11
uv pip install gunicorn

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
