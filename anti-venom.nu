#!/usr/bin/env nu

#
# Enhanced EVM transaction fetcher with translation support and local address book
# built using Dune-Sim and Noves
#
# @author: ℭ𝔦𝔭𝔥𝔢𝔯
# gh: cipher-rc5
# tg: cipher0091
#
#
#    ▄████████ ███▄▄▄▄       ███      ▄█        ▄█    █▄     ▄████████ ███▄▄▄▄    ▄██████▄    ▄▄▄▄███▄▄▄▄
#   ███    ███ ███▀▀▀██▄ ▀█████████▄ ███       ███    ███   ███    ███ ███▀▀▀██▄ ███    ███ ▄██▀▀▀███▀▀▀██▄
#   ███    ███ ███   ███    ▀███▀▀██ ███▌      ███    ███   ███    █▀  ███   ███ ███    ███ ███   ███   ███
#   ███    ███ ███   ███     ███   ▀ ███▌      ███    ███  ▄███▄▄▄     ███   ███ ███    ███ ███   ███   ███
# ▀███████████ ███   ███     ███     ███▌      ███    ███ ▀▀███▀▀▀     ███   ███ ███    ███ ███   ███   ███
#   ███    ███ ███   ███     ███     ███       ███    ███   ███    █▄  ███   ███ ███    ███ ███   ███   ███
#   ███    ███ ███   ███     ███     ███       ███    ███   ███    ███ ███   ███ ███    ███ ███   ███   ███
#   ███    █▀   ▀█   █▀     ▄████▀   █▀         ▀██████▀    ██████████  ▀█   █▀   ▀██████▀   ▀█   ███   █▀
#
#

# Load environment variables from .env file
def load-env [] {
    let env_file = ".env"
    if ($env_file | path exists) {
        open $env_file
        | lines
        | where ($it | str trim) != "" and not ($it | str starts-with "#")
        | each { |line|
            let parts = ($line | split column "=" | first)
            if ($parts | columns | length) >= 2 {
                let key = ($parts | get column1 | str trim)
                let value = ($parts | get column2 | str trim | str replace --all '"' '' | str replace --all "'" '')
                {key: $key, value: $value}
            }
        }
        | where ($it != null)
        | reduce -f {} { |it, acc| $acc | insert $it.key $it.value }
    } else {
        {}
    }
}

# Configuration file structure
def default-config [] {
    {
        evm_addr: null
        default_limit: 25
        cache_dir: "~/.cache/anti-venom"
        address_book_path: "address_book.csv"
        colors: {
            current_address: "green"
            success: "green"
            failure: "red"
            address_prefix: "blue"
            address_even: "yellow"
            address_odd: "cyan"
        }
        retry_attempts: 3
        retry_delay_ms: 1000
        parallel_workers: 10
        default_format: "table"
        timestamp_format: "relative"  # relative, unix, human
        sort_by: "block_time"
        sort_order: "desc"
    }
}

# Load configuration from file, .env, and environment
def load-config [] {
    # First load .env file
    let env_vars = load-env

    # Load config file
    let config_path = $"($env.HOME)/.config/anti-venom/config.toml"
    let base_config = if ($config_path | path exists) {
        try {
            open $config_path | merge (default-config)
        } catch {
            print $"Warning: Could not load config from ($config_path), using defaults"
            default-config
        }
    } else {
        default-config
    }

    # Apply .env variables
    mut config = $base_config
    if ($env_vars | get -i EVM_ADDR) != null {
        $config.evm_addr = ($env_vars | get EVM_ADDR)
    }

    # Override with environment variables if set (highest priority)
    if not ($env.EVM_ADDR? | is-empty) {
        $config.evm_addr = $env.EVM_ADDR
    }

    # Handle API keys separately (never stored in config file)
    let noves_key = if not ($env.NOVES_API_KEY? | is-empty) {
        $env.NOVES_API_KEY
    } else if ($env_vars | get -i NOVES_API_KEY) != null {
        $env_vars | get NOVES_API_KEY
    } else {
        null
    }

    let sim_key = if not ($env.SIM_API_KEY? | is-empty) {
        $env.SIM_API_KEY
    } else if ($env_vars | get -i SIM_API_KEY) != null {
        $env_vars | get SIM_API_KEY
    } else {
        null
    }

    # Add API keys to config for internal use only
    $config | insert noves_api_key $noves_key | insert sim_api_key $sim_key
}

# HTTP request with retry logic
def fetch-with-retry [url: string, headers: record, config: record, attempt: int = 1] {
    try {
        return (http get --headers $headers $url)
    } catch {
        let error_msg = ($in | into string)

        if $attempt >= $config.retry_attempts {
            error make {
                msg: $"Failed to fetch from ($url) after ($config.retry_attempts) attempts. Last error: ($error_msg)"
            }
        }

        print $"  ⚠️  Attempt ($attempt)/($config.retry_attempts) failed, retrying in ($config.retry_delay_ms)ms..."
        sleep ($"($config.retry_delay_ms)ms" | into duration)

        # Recursive call with incremented attempt
        fetch-with-retry $url $headers $config ($attempt + 1)
    }
}

# Convert hex string to integer
def hex-to-int [hex_str: string] {
    if ($hex_str | str starts-with "0x") {
        $hex_str | str substring 2.. | into int --radix 16
    } else {
        $hex_str | into int --radix 16
    }
}

# Format wei values to human-readable format
def format-wei [wei: int, decimals: int = 18] {
    let eth = $wei / (10 ** $decimals | into float)
    let gwei = $wei / (10 ** 9 | into float)

    if $wei == 0 {
        "0 ETH"
    } else if $eth >= 0.01 {
        # Display as ETH for values >= 0.01 ETH
        $"($eth | math round --precision 6) ETH"
    } else if $gwei >= 1 {
        # Display as Gwei for values >= 1 Gwei
        $"($gwei | math round --precision 2) Gwei"
    } else {
        # Display as wei for very small values
        $"($wei) wei"
    }
}

# Load and validate address book
def load-address-book [path: string] {
    if not ($path | path exists) {
        return []
    }

    try {
        let book = open $path
        let headers = $book | columns | each { |h| $h | str trim }
        let required_cols = ["address", "chain", "label"]
        let missing = $required_cols | where { |col| not ($col in $headers) }

        if not ($missing | is-empty) {
            print $"⚠️  Address book missing columns: ($missing | str join ', ')"
            return []
        }

        # Clean and validate addresses
        let clean_book = $book
            | rename ...($headers)
            | where { |row|
                ($row.address | str length) == 42;
                ($row.address | str starts-with "0x")
            }
            | update address { |row| $row.address | str downcase }
            | update chain { |row| $row.chain | str downcase }

        print $"✓ Loaded address book with ($clean_book | length) valid entries"
        $clean_book
    } catch {
        print $"❌ Error loading address book: ($in)"
        []
    }
}

# Apply address label with chain awareness
def apply-address-label [address: string, chain: string, address_book: list] {
    if ($address_book | is-empty) {
        return null
    }

    let normalized_address = ($address | str downcase)
    let normalized_chain = ($chain | str downcase)

    # First try exact match (address + chain)
    let exact_match = ($address_book | where { |row|
        $row.address == $normalized_address and $row.chain == $normalized_chain
    } | first)

    if $exact_match != null {
        return $exact_match.label
    }

    # Then try address-only match
    let address_match = ($address_book | where address == $normalized_address | first)
    if $address_match != null {
        return $address_match.label
    }

    null
}

# Format EVM address with colors and labels
def format-evm-address [address: string, current_addr: string, chain: string, address_book: list, use_labels: bool, colors: record] {
    let label = if $use_labels {
        apply-address-label $address $chain $address_book
    } else {
        null
    }

    # If we have a label, use it
    if $label != null {
        if $address == $current_addr {
            $"\e[1;32m($label)\e[0m"  # Green for current address
        } else {
            $label
        }
    } else {
        # Colorize the address
        if $address == $current_addr {
            $"\e[1;32m($address)\e[0m"
        } else {
            let addr_no_prefix = ($address | str substring 2..)
            let bytes = ($addr_no_prefix | split chars)
            let chunks = ($bytes | chunks 8)
            let colorized = (0..(($chunks | length) - 1) | each { |i|
                let color = if ($i mod 2) == 0 { 33 } else { 36 }  # Yellow/Cyan
                $"\e[1;($color)m(($chunks | get $i) | str join)\e[0m"
            })
            $"\e[1;34m0x\e[0m($colorized | str join)"
        }
    }
}

# Get transaction translation with caching
def get-translation-cached [hash: string, config: record] {
    let cache_dir = ($config.cache_dir | path expand)
    let cache_file = $"($cache_dir)/($hash).json"

    # Check cache first
    if ($cache_file | path exists) {
        try {
            let cached = open $cache_file
            if ($cached.timestamp? != null) {
                let age = (date now) - ($cached.timestamp | into datetime)
                if $age < 7day {
                    return $cached.translation
                }
            }
        } catch {
            # Cache corrupted, continue to fetch
        }
    }

    # Fetch from API
    try {
        let response = fetch-with-retry $"https://translate.noves.fi/evm/eth/describeTx/($hash)" {
            accept: "application/json"
            apiKey: $config.noves_api_key
    } $config

        let translation = if ($response | get -i description) != null {
            $response.description
        } else {
            "No translation available"
        }

        # Save to cache
        mkdir $cache_dir
        {
            translation: $translation
            timestamp: (date now | into string)
            hash: $hash
        } | to json | save -f $cache_file

        $translation
    } catch {
        "Translation unavailable"
    }
}

# Sequential translation fetcher with progress (more reliable than parallel in some environments)
def fetch-translations-sequential [transactions: list, config: record] {
    let total = ($transactions | length)

    if $total == 0 {
        return $transactions
    }

    print $"🔄 Fetching translations for ($total) transactions..."

    $transactions | enumerate | each { |item|
        let progress = (($item.index + 1) * 100 / $total)
        print -n $"\r  Progress: [($progress)%] (($item.index + 1))/($total) transactions"

        let translation = get-translation-cached $item.item.hash $config
        $item.item | insert translation $translation
    } | do {
        print "\r✓ Fetched all translations                                    "
        $in
    }
}

# Format transaction status
def format-status [success: bool] {
    if $success {
        $"\e[1;32m✓\e[0m"
    } else {
        $"\e[1;31m✗\e[0m"
    }
}

# Format timestamp based on preference
def format-timestamp [timestamp: string, format: string] {
    let dt = ($timestamp | into datetime)

    match $format {
        "unix" => { $dt | into int }
        "relative" => {
            let now = (date now)
            let diff = $now - $dt

            if $diff < 1min {
                "just now"
            } else if $diff < 1hr {
                let mins = (($diff | into int) / 60000000000 | math round)
                $"($mins)m ago"
            } else if $diff < 1day {
                let hours = (($diff | into int) / 3600000000000 | math round)
                $"($hours)h ago"
            } else {
                let days = (($diff | into int) / 86400000000000 | math round)
                $"($days)d ago"
            }
        }
        _ => { $dt | format date "%Y-%m-%d %H:%M" }
    }
}

# Main command
def main [
    --translate(-t)                 # Fetch transaction translations
    --show-config(-c)               # Show configuration status
    --labels(-l)                    # Use address labels from address book
    --format(-f): string = "table"  # Output format: table, json, csv, compact
    --limit: int                    # Number of transactions to fetch
    --chain: string                 # Filter by specific chain
    --export(-e): string            # Export to file
    --no-cache                      # Disable translation cache
    --timestamp-format: string      # Timestamp format: relative, unix, human
    --sort-by: string              # Sort field
    --sort-order: string           # Sort order: asc, desc
    --address: string              # Override EVM address
] {
    # Load configuration
    let config = load-config

    # Apply command line overrides
    let final_config = $config | merge {
        default_limit: ($limit | default $config.default_limit)
        timestamp_format: ($timestamp_format | default $config.timestamp_format)
        sort_by: ($sort_by | default $config.sort_by)
        sort_order: ($sort_order | default $config.sort_order)
    }

    # Configuration check mode - now using $show_config
    if $show_config {
        print "🔍 Configuration Status\n"

        print "Environment Sources:"
        print $"  .env file: (if ('.env' | path exists) { '✓ Found' } else { '- Not found' })"
        print $"  Shell environment: ✓ Checked"

        print "\nCredentials:"
        print $"  EVM_ADDR: (if $final_config.evm_addr != null { '✓ Set' } else { '✗ Not set' })"
        print $"  NOVES_API_KEY: (if $final_config.noves_api_key != null { '✓ Set (hidden)' } else { '✗ Not set' })"
        print $"  SIM_API_KEY: (if $final_config.sim_api_key != null { '✓ Set (hidden)' } else { '✗ Not set' })"

        print $"\nConfiguration File: ($env.HOME)/.config/anti-venom/config.toml"
        print $"  Status: (if ($"($env.HOME)/.config/anti-venom/config.toml" | path exists) { '✓ Found' } else { '- Not found (using defaults)' })"

        print $"\nCache Directory: ($final_config.cache_dir | path expand)"
        print $"  Status: (if ($final_config.cache_dir | path expand | path exists) { '✓ Exists' } else { '- Will be created' })"

        # Check address book
        load-address-book $final_config.address_book_path
        return
    }

    # Validate required configuration
    if $final_config.sim_api_key == null {
        error make {msg: "❌ SIM_API_KEY not set. Please set it in .env file or environment."}
    }

    # Get EVM address
    let evm_addr = if $address != null {
        $address
    } else if $final_config.evm_addr != null {
        $final_config.evm_addr
    } else {
        print "EVM address not configured."
        let user_addr = (input "Please enter an EVM address: " | str trim)
        if ($user_addr | is-empty) {
            error make {msg: "❌ EVM address cannot be empty"}
        }
        $user_addr
    }

    print $"🔍 Using EVM address: ($evm_addr)"

    # Load address book
    let address_book = load-address-book $final_config.address_book_path

    # Fetch transactions
    print $"📊 Fetching last ($final_config.default_limit) transactions..."

    let raw_transactions = try {
        fetch-with-retry $"https://api.sim.dune.com/v1/evm/transactions/($evm_addr)" {
        X-Sim-Api-Key: $final_config.sim_api_key
    } $final_config
    } catch {
        error make {msg: $"❌ Failed to fetch transactions: ($in)"}
    }

    if ($raw_transactions | get -i transactions) == null {
        error make {msg: "❌ No transactions found in response"}
    }

    # Process transactions
    let transactions = (
        $raw_transactions
        | get transactions
        | first $final_config.default_limit
        | each { |tx|
            {
                block_time: $tx.block_time
                chain: $tx.chain
                transaction_type: $tx.transaction_type
                hash: $tx.hash
                from: $tx.from
                to: $tx.to
                value: (hex-to-int $tx.value)
                success: $tx.success
                gas_used: (hex-to-int $tx.gas_used)
                gas_price: (hex-to-int $tx.gas_price)
                effective_gas_price: (hex-to-int $tx.effective_gas_price)
                nonce: (hex-to-int $tx.nonce)
            }
        }
    )

    print $"✓ Fetched ($transactions | length) transactions"

    # Filter by chain if specified
    let filtered = if $chain != null {
        $transactions | where chain == ($chain | str downcase)
    } else {
        $transactions
    }

    # Add translations if requested
    let with_translations = if $translate {
        if $final_config.noves_api_key == null {
            print "⚠️  NOVES_API_KEY not set, skipping translations"
            $filtered
        } else if $no_cache {
            print "📊 Cache disabled, fetching fresh translations..."
            fetch-translations-sequential $filtered $final_config
        } else {
            fetch-translations-sequential $filtered $final_config
        }
    } else {
        $filtered
    }

    # Format the output
    let formatted = (
        $with_translations
        | insert status { |row| format-status $row.success }
        | update block_time { |row| format-timestamp $row.block_time $final_config.timestamp_format }
        | update from { |row| format-evm-address $row.from $evm_addr $row.chain $address_book $labels $final_config.colors }
        | update to { |row| format-evm-address $row.to $evm_addr $row.chain $address_book $labels $final_config.colors }
        | update value { |row| format-wei $row.value }
        | move status --before block_time
    )

    # Sort the results
    let sorted = match $final_config.sort_by {
        "value" => {
            if $final_config.sort_order == "asc" {
                $formatted | sort-by value
            } else {
                $formatted | sort-by value --reverse
            }
        }
        "nonce" => {
            if $final_config.sort_order == "asc" {
                $formatted | sort-by nonce
            } else {
                $formatted | sort-by nonce --reverse
            }
        }
        _ => {
            if $final_config.sort_order == "asc" {
                $formatted | sort-by block_time
            } else {
                $formatted | sort-by block_time --reverse
            }
        }
    }

    # Select final columns based on format
    let final_data = match $format {
        "compact" => {
            $sorted | select status block_time chain hash from to value
        }
        _ => {
            if $translate {
                $sorted | select status block_time chain transaction_type hash from to value translation
            } else {
                $sorted | select status block_time chain transaction_type hash from to value success
            }
        }
    }

    # Export if requested
    if $export != null {
        let ext = ($export | path parse | get extension)
        match $ext {
            "json" => { $final_data | to json | save -f $export }
            "csv" => { $final_data | to csv | save -f $export }
            "txt" => { $final_data | to md | save -f $export }
            _ => { error make {msg: "❌ Unsupported export format. Use .json, .csv, or .txt"} }
        }
        print $"✓ Exported to ($export)"
    }

    # Format output
    match $format {
        "json" => { $final_data | to json }
        "csv" => { $final_data | to csv }
        "compact" => { $final_data }
        _ => { $final_data }  # default table
    }
}

# Initialize config directory if needed
def "main init" [] {
    let config_dir = $"($env.HOME)/.config/anti-venom"
    let config_file = $"($config_dir)/config.toml"

    mkdir $config_dir

    if not ($config_file | path exists) {
        default-config | to toml | save -f $config_file
        print $"✓ Created default config at ($config_file)"
    } else {
        print $"Config already exists at ($config_file)"
    }

    # Create example .env file
    let env_example = ".env.example"
    if not ($env_example | path exists) {
        "# EVM Transaction Fetcher Configuration
# Copy this file to .env and fill in your values

# Your EVM address (can also be set in config.toml)
EVM_ADDR=0x...

# API Keys (required, keep these secret!)
SIM_API_KEY=your-dune-api-key-here
NOVES_API_KEY=your-noves-api-key-here" | save -f $env_example
        print $"✓ Created example .env file at ($env_example)"
    }

    # Create example address book
    let address_book_example = "address_book_example.csv"
    if not ($address_book_example | path exists) {
        # Create a proper table structure
        let addresses = [
            {address: "0x742d35Cc6634C0532925a3b844Bc9e7595f5b9e1", chain: "eth", label: "Binance Hot Wallet"},
            {address: "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8", chain: "eth", label: "Binance Cold Wallet"},
            {address: "0xA090e606E30bD747d4E6245a1517EbE430F0057e", chain: "eth", label: "Coinbase"}
        ]

        $addresses | to csv | save -f $address_book_example
        print $"✓ Created example address book at ($address_book_example)"
    }
}

# Clear cache command
def "main clear-cache" [] {
    let config = load-config
    let cache_dir = ($config.cache_dir | path expand)

    if ($cache_dir | path exists) {
        let count = (ls $cache_dir | length)
        rm -rf $cache_dir
        print $"✓ Cleared ($count) cached translations"
    } else {
        print "No cache to clear"
    }
}
