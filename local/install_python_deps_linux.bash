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

# Install system dependencies
sudo apt-get update
sudo apt-get install -y python3-dev libyaml-dev build-essential libffi-dev libssl-dev python3-setuptools python3-wheel

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

# Install pipenv for requirements generation
if ! uv pip install pipenv; then
    echo "Failed to install pipenv"
    exit 1
fi

# Generate requirements from Pipfiles
cd src
python -m pipenv requirements > requirements.txt

# Create constraint file for Cython
echo 'Cython < 3.0' > /tmp/constraint.txt

# Download and build PyYAML
mkdir -p /tmp/pyyaml
cd /tmp/pyyaml
curl -L https://files.pythonhosted.org/packages/54/ed/79a089b6be93607fa5cdaedf301d7dfb23af5f25c398d5ead2525b063e17/pyyaml-6.0.2.tar.gz | tar xz
cd pyyaml-6.0.2

# Build wheel with Cython constraint
PIP_CONSTRAINT=/tmp/constraint.txt uv build --wheel .

# Install PyYAML from cached wheel using uv
uv pip install 'PyYAML==6.0.2'

# Go back to src directory
cd /home/devops/parithosh/clusterfuzz/src

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

# Install other dependencies (e.g. bower).
nodeenv -p --prebuilt
# Unsafe perm flag allows bower and polymer-bundler install for root users as well.
npm install --unsafe-perm -g bower polymer-bundler

# Go back to root directory for bower install
cd ..

# Run bower install from root directory
bower install --allow-root

# Run the full bootstrap script to prepare for ClusterFuzz development.
python butler.py bootstrap

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
