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

# Install system dependencies (no Python packages)
sudo apt-get update
sudo apt-get install -y libyaml-dev build-essential libffi-dev libssl-dev python3-dev g++ cmake nodejs npm

# Install uv globally
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Create and activate virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
  rm -rf "$VENV_DIR"
fi

# Create virtual environment with uv and let it handle Python installation
uv venv "$VENV_DIR" --python 3.10
source "$VENV_DIR/bin/activate"

# Verify installation
echo "Python path: $(which python)"
echo "Python version: $(python --version)"
echo "Virtual env: $VIRTUAL_ENV"

if [ -z "$VIRTUAL_ENV" ]; then
    echo "Not in virtual environment"
    exit 1
fi

# Install pipenv for dependency management
if ! uv pip install pipenv; then
    echo "Failed to install pipenv"
    exit 1
fi

# Generate requirements from Pipfiles
cd src

# Install dependencies using pipenv from project root
if ! pipenv install --dev; then
    echo "Failed to install dependencies using pipenv"
    exit 1
fi

# Generate requirements.txt with updated versions
python -m pipenv requirements > requirements.txt

# Install packages with specific version for google-cloud-profiler
if ! uv pip install -r requirements.txt; then
    echo "Failed to install requirements"
    exit 1
fi

# Install older version of google-cloud-profiler that's compatible with Python 3.10
if ! uv pip install --no-cache-dir --force-reinstall google-cloud-profiler==3.0.0; then
    echo "Failed to install google-cloud-profiler"
    exit 1
fi

if ! uv pip install gunicorn; then
    echo "Failed to install gunicorn"
    exit 1
fi

# Install nodeenv and other dependencies
if ! uv pip install nodeenv; then
    echo "Failed to install nodeenv"
    exit 1
fi

# Install node and npm
nodeenv -p --prebuilt
# Ensure npm is in PATH
export PATH="$VIRTUAL_ENV/bin:$PATH"

# Install bower and polymer-bundler locally
npm install bower polymer-bundler

# Add node_modules/.bin to PATH
export PATH="$PWD/node_modules/.bin:$PATH"

# bower install should run from the project root
cd ..
bower install --allow-root

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
