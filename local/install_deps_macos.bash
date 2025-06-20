#!/bin/bash -ex
#
# Copyright 2019 Google LLC
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

if ! which gcloud > /dev/null 2>&1; then
  echo 'Please install the google cloud SDK (https://cloud.google.com/sdk/install)'
  exit 1
fi

if ! which brew > /dev/null 2>&1; then
  echo 'Please install homebrew (https://brew.sh).'
  exit 1
fi

brew bundle --file=$(dirname "$0")/Brewfile

# Setup virtual environment and install python dependencies.
echo "Setting up Python environment with uv"

# Install uv globally
if ! command -v uv &> /dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    if [ $? -ne 0 ]; then
        echo "Failed to install uv"
        exit 1
    fi
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv &> /dev/null; then
        echo "uv not found in PATH after installation"
        exit 1
    fi
fi

# Create and activate virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
  rm -rf "$VENV_DIR"
fi

# Create virtual environment with uv and let it handle Python installation
uv venv "$VENV_DIR" --python 3.11
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

# Install bower and polymer-bundler globally
npm install -g bower polymer-bundler

# Add node_modules/.bin to PATH
export PATH="$PWD/node_modules/.bin:$PATH"

# bower install should run from the project root
cd ..
bower install --allow-root

gcloud components install --quiet \
    app-engine-go \
    app-engine-python \
    app-engine-python-extras \
    beta \
    cloud-datastore-emulator \
    pubsub-emulator

# Bootstrap code structure.
python butler.py bootstrap

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
