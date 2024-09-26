#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
    export $(cat .env | sed 's/#.*//g' | xargs)
fi

# Default values (use environment variables if set, otherwise use these defaults)
CHAIN=${CHAIN:-sepolia}
SCRIPT=${SCRIPT:-script/DeployBondingCurve.s.sol}
RPC_URL=${RPC_URL:-$BASE_SEPOLIA_RPC_URL}
VERIFIER=${VERIFIER:-blockscout}
VERIFIER_URL=${VERIFIER_URL:-https://base-sepolia.blockscout.com/api/}
VERBOSITY=${VERBOSITY:-vvvv}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --chain) CHAIN="$2"; shift 2 ;;
        --script) SCRIPT="$2"; shift 2 ;;
        --rpc-url) RPC_URL="$2"; shift 2 ;;
        --verifier) VERIFIER="$2"; shift 2 ;;
        --verifier-url) VERIFIER_URL="$2"; shift 2 ;;
        --verbosity) VERBOSITY="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

# Construct the base command
CMD="forge script --chain $CHAIN $SCRIPT --rpc-url $RPC_URL --broadcast --verify --verifier $VERIFIER --verifier-url $VERIFIER_URL"


# Add verbosity
CMD="$CMD -$VERBOSITY"

# Print the command
echo "Executing: $CMD"

# Execute the command
eval $CMD