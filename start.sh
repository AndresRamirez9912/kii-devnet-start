#!/bin/bash

PRIV_VALIDATOR_KEY_FILE=${"$HOME/priv_validator_key.json"}
NODE_KEY_FILE=${"$HOME/node_key.json"}
NODE_HOME=~/.kiichain3
NODE_MONIKER="devnet_oro-validator-$VALIDATOR_INDEX"
SERVICE_NAME=kiichain3
SERVICE_VERSION="v2.0.0"
CHAIN_BINARY='kiichaind'
CHAIN_ID=kiichain3
GENESIS_URL=https://raw.githubusercontent.com/KiiChain/testnets/refs/heads/main/testnet_oro/genesis.json

# Stop and clean previous installations
sudo systemctl stop $SERVICE_NAME.service 2>/dev/null || true
systemctl --user stop $SERVICE_NAME.service 2>/dev/null || true
sudo rm /etc/systemd/system/$SERVICE_NAME.service
sudo systemctl daemon-reload
rm -rf $NODE_HOME

# Install dependencies
echo "Installing dependencies..."
sudo apt update
sudo apt-get install git jq curl wget build-essential -y

# Install go 1.22
echo "Installing go..."
rm go*linux-amd64.tar.gz
wget https://go.dev/dl/go1.22.10.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.22.10.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile

# Install Kiichain binary
echo "Installing Kiichain..."
cd $HOME
mkdir -p $HOME/go/bin
rm -rf kiichain
git clone https://github.com/KiiChain/kiichain.git
cd kiichain
git checkout $SERVICE_VERSION
make install
export PATH=$PATH:$HOME/go/bin
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.profile

# Download the official genesis file
echo "Downloading official genesis.json..."
mkdir -p $NODE_HOME/config
curl -s $GENESIS_URL -o $NODE_HOME/config/genesis.json

# Set genesis with desired values
sed -i 's/"voting_period": *"[^"]*"/"voting_period": "240s"/' $NODE_HOME/config/genesis.json
sed -i 's/"expedited_voting_period": *"[^"]*"/"expedited_voting_period": "120s"/' $NODE_HOME/config/genesis.json

# Install and configure Cosmovisor
echo "Setting up Cosmovisor..."
mkdir -p $NODE_HOME/cosmovisor/genesis/bin
mkdir -p $NODE_HOME/cosmovisor/upgrades
mkdir -p $NODE_HOME/cosmovisor/backup
cp $(which $CHAIN_BINARY) $NODE_HOME/cosmovisor/genesis/bin

go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.5.0

# Apply env vars
export DAEMON_NAME=$CHAIN_BINARY
export DAEMON_HOME=$NODE_HOME
export DAEMON_DATA_BACKUP_DIR=$NODE_HOME/cosmovisor/backup
export DAEMON_RESTART_AFTER_UPGRADE="true"
echo "export DAEMON_NAME=$CHAIN_BINARY" >> ~/.profile
echo "export DAEMON_HOME=$NODE_HOME" >> ~/.profile
echo "export DAEMON_DATA_BACKUP_DIR=$NODE_HOME/cosmovisor/backup" >> ~/.profile
echo 'export DAEMON_RESTART_AFTER_UPGRADE="true"' >> ~/.profile

# Create systemd service
echo "Creating $SERVICE_NAME.service..."
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=Cosmovisor and Kiichaind service
After=network-online.target

[Service]
User=$USER
ExecStart=$HOME/go/bin/cosmovisor run start --x-crisis-skip-assert-invariants --rpc.laddr tcp://0.0.0.0:26657 
Restart=always
RestartSec=3
LimitNOFILE=50000
Environment="DAEMON_NAME=$CHAIN_BINARY"
Environment="DAEMON_HOME=$NODE_HOME"
Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=true"
Environment="DAEMON_RESTART_AFTER_UPGRADE=true"
Environment="DAEMON_LOG_BUFFER_SIZE=512"

[Install]
WantedBy=multi-user.target
EOF

# Start the service
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME.service
sudo systemctl start $SERVICE_NAME.service

echo "***********************"
echo "DevNet setup complete!"
echo "Validator address: $VALIDATOR_ADDRESS"
echo "To see the service logs:"
echo "journalctl -fu $SERVICE_NAME.service"
echo "***********************"

# Load environment variables
echo 'export PATH=$HOME/go/bin:$PATH' >> ~/.profile
source ~/.profile

# Give the blockchain some time to start
echo "Wait time meanwhile the chain starts..."
sleep 20

# Create validator account
echo "Creating validator account..."
VALIDATOR_KEY_NAME="devnet_validator"
$CHAIN_BINARY keys add $VALIDATOR_KEY_NAME --keyring-backend test 
VALIDATOR_ADDRESS=$($CHAIN_BINARY keys show $VALIDATOR_KEY_NAME -a --keyring-backend test )

echo "add funds to validator's account..."
BASE_ACCOUNT_KEY_NAME="private_sale"
$CHAIN_BINARY tx bank send $BASE_ACCOUNT_KEY_NAME $VALIDATOR_ADDRESS 100000000000ukii -y -b block --fees 21000ukii

# Set node as validator
sed -i 's/mode = "full"/mode = "validator"/g' $NODE_HOME/config/config.toml

