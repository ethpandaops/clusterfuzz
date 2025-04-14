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
sudo apt-get install -y libyaml-dev build-essential libffi-dev libssl-dev python3-dev g++

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
# This will install all packages (including dev) from Pipfile
# and generate Pipfile.lock if it doesn't exist
if ! pipenv install --dev; then
    echo "Failed to install dependencies using pipenv"
    exit 1
fi

python -m pipenv requirements > requirements.txt

# Install packages with specific version for google-cloud-profiler

if ! uv pip install -r requirements.txt; then
    echo "Failed to install requirements"
    exit 1
fi

# Install latest google-cloud-profiler
if ! uv pip install google-cloud-profiler; then
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
 
# nodeenv (installed via pipenv) is used for bower/polymer

# Install other dependencies (e.g. bower).
# Run nodeenv from the activated venv
nodeenv -p --prebuilt
# Unsafe perm flag allows bower and polymer-bundler install for root users as well.
npm install --unsafe-perm -g bower polymer-bundler

# bower install should run from the project root
bower install --allow-root

# Run the full bootstrap script to prepare for ClusterFuzz development.
# Make sure PYTHONPATH points to the site-packages within the uv-managed venv
PYTHONPATH=$VIRTUAL_ENV/lib/python$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages $VIRTUAL_ENV/bin/python butler.py bootstrap

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
