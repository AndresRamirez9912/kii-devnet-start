#!/bin/bash

PRIV_VALIDATOR_KEY_FILE="$HOME/priv_validator_key.json"
NODE_KEY_FILE="$HOME/node_key.json"
NODE_HOME=~/.kiichain3
NODE_MONIKER="devnet-validator-0"
VALIDATOR_KEY_NAME="devnet_validator"
SERVICE_NAME=kiichain3
SERVICE_VERSION="v2.0.0"
CHAIN_BINARY='kiichaind'
CHAIN_ID=kiichain3
APP_TOML_PATH="$HOME/.kiichain3/config/app.toml"
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
rm go1.22.10.linux-amd64.tar.gz

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

# Init chain and replace genesis
echo "Downloading official genesis.json..."
$CHAIN_BINARY init $NODE_MONIKER --chain-id $CHAIN_ID --home $NODE_HOME
# curl -s $GENESIS_URL -o $NODE_HOME/config/genesis.json

# Set genesis with desired values
echo "Modifying genesis.json with required configurations..."

# Delete validators from the genesis file
jq '.validators = []' $NODE_HOME/config/genesis.json > temp.json && mv temp.json $NODE_HOME/config/genesis.json 

# Modify desired parameters in the genesis file using jq
sed -i 's/"voting_period": *"[^"]*"/"voting_period": "240s"/' $NODE_HOME/config/genesis.json
sed -i 's/"expedited_voting_period": *"[^"]*"/"expedited_voting_period": "120s"/' $NODE_HOME/config/genesis.json
sed -i 's/mode = "full"/mode = "validator"/g' $NODE_HOME/config/config.toml

# Modify testnet-specific configuration
cat $NODE_HOME/config/genesis.json | jq '.app_state["gov"]["deposit_params"]["max_deposit_period"]="60s"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.app_state["gov"]["voting_params"]["voting_period"]="30s"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.app_state["gov"]["voting_params"]["expedited_voting_period"]="10s"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.app_state["distribution"]["params"]["community_tax"]="0.000000000000000000"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.consensus_params["block"]["max_gas"]="35000000"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.app_state["staking"]["params"]["max_voting_power_ratio"]="1.000000000000000000"' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json
cat $NODE_HOME/config/genesis.json | jq '.app_state["bank"]["denom_metadata"]=[{"denom_units":[{"denom":"ukii","exponent":0,"aliases":["ukii"]}],"base":"ukii","display":"ukii","name":"ukii","symbol":"ukii"}]' > $NODE_HOME/config/tmp_genesis.json && mv $NODE_HOME/config/tmp_genesis.json $NODE_HOME/config/genesis.json

# Modify app.toml configurations
sed -i.bak -e 's/# concurrency-workers = .*/concurrency-workers = 500/' $APP_TOML_PATH
sed -i.bak -e 's/occ-enabled = .*/occ-enabled = true/' $APP_TOML_PATH
sed -i.bak -e 's/sc-enable = .*/sc-enable = true/' $APP_TOML_PATH
sed -i.bak -e 's/ss-enable = .*/ss-enable = true/' $APP_TOML_PATH

# Create validator account
echo "Creating validator account..."
$CHAIN_BINARY keys add $VALIDATOR_KEY_NAME 
VALIDATOR_ADDRESS=$($CHAIN_BINARY keys show $VALIDATOR_KEY_NAME -a )

# Add validator into the genesis file
$CHAIN_BINARY add-genesis-account $VALIDATOR_ADDRESS 1000000000ukii
$CHAIN_BINARY gentx $VALIDATOR_KEY_NAME 1000000ukii --chain-id $CHAIN_ID
$CHAIN_BINARY collect-gentxs

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
ExecStart=$HOME/go/bin/cosmovisor run start
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

