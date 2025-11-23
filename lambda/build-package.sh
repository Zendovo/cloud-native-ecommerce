#!/bin/bash

set -e

echo "Building Lambda deployment package..."

rm -f lambda_function.zip
rm -rf package/

mkdir -p package

echo "Installing dependencies..."
pip install requests -t package/ --quiet

cp index.py package/

echo "Creating deployment package..."
cd package
zip -r ../lambda_function.zip . -q
cd ..

rm -rf package/

echo "✓ Lambda deployment package created: lambda_function.zip"
echo "Size: $(du -h lambda_function.zip | cut -f1)"

echo ""
echo "Package contents:"
unzip -l lambda_function.zip | head -20
