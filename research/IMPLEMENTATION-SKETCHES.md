# Implementation Sketches: Adding srt/OpenShell Features to Sandy

**Document:** Technical reference for implementing P0/P1 features
**Audience:** Sandy developers ready to code

---

## Feature 1: Domain-Based Network Filtering

### Architecture

```
┌─────────────────────────────────────────────┐
│         Sandy Container                      │
├─────────────────────────────────────────────┤
│                                              │
│  ┌─────────────────────────────────────┐   │
│  │  Claude Code Process                │   │
│  │  (any outbound connection attempt)  │   │
│  └──────────┬──────────────────────────┘   │
│             │                               │
│        HTTP_PROXY=127.0.0.1:3128            │
│      HTTPS_PROXY=127.0.0.1:3128             │
│      ALL_PROXY=127.0.0.1:1080 (SOCKS5)     │
│             │                               │
│  ┌──────────▼──────────────────────────┐   │
│  │  HTTP Proxy (localhost:3128)         │   │
│  │  - Intercepts HTTP/HTTPS (CONNECT)  │   │
│  │  - Validates domain vs allowlist    │   │
│  │  - Logs violations                  │   │
│  └─────────────────────────────────────┘   │
│                                              │
│  ┌─────────────────────────────────────┐   │
│  │  SOCKS5 Proxy (localhost:1080)       │   │
│  │  - Handles SSH, databases, etc.     │   │
│  │  - Validates domain vs allowlist    │   │
│  │  - Logs violations                  │   │
│  └─────────────────────────────────────┘   │
│                                              │
│  ┌─────────────────────────────────────┐   │
│  │  Config File (.sandy/network.conf)   │   │
│  │  {                                   │   │
│  │    "allowedDomains": [               │   │
│  │      "github.com", "*.github.com",   │   │
│  │      "npmjs.org", "api.*.com"        │   │
│  │    ],                                │   │
│  │    "deniedDomains": ["attacker.com"] │   │
│  │  }                                   │   │
│  └─────────────────────────────────────┘   │
│                                              │
└─────────────────────────────────────────────┘
```

### Implementation Plan

#### 1. HTTP Proxy (Node.js)

**File:** `sandy/http-proxy.js` (or integrate into container entrypoint)

```javascript
const http = require('http');
const net = require('net');
const tls = require('tls');

class HttpProxyServer {
  constructor(config) {
    this.config = config;
    this.server = http.createServer();
    this.server.on('connect', this.handleConnect.bind(this));
  }

  handleConnect(req, socket) {
    // req.url = "hostname:port"
    const [hostname, portStr] = req.url.split(':');
    const port = parseInt(portStr) || 443;

    // Check allowlist/denylist
    if (!this.isAllowed(hostname)) {
      socket.end(`HTTP/1.1 403 Forbidden\r\n`
        + `X-Proxy-Error: not-in-allowlist\r\n\r\n`
        + `Domain ${hostname} not in allowlist`);
      this.logViolation('blocked', hostname, port);
      return;
    }

    // Establish tunnel to real server
    const server = tls.connect(port, hostname, () => {
      socket.write(`HTTP/1.1 200 Connection Established\r\n\r\n`);
      server.pipe(socket);
      socket.pipe(server);
      this.logViolation('allowed', hostname, port);
    });

    server.on('error', (err) => {
      socket.end(`HTTP/1.1 502 Bad Gateway\r\n\r\n${err.message}`);
    });
  }

  isAllowed(hostname) {
    const { allowedDomains, deniedDomains } = this.config;

    // Denied list takes precedence
    if (deniedDomains && this.matchesDomain(hostname, deniedDomains)) {
      return false;
    }

    // Check allowed list
    if (allowedDomains && this.matchesDomain(hostname, allowedDomains)) {
      return true;
    }

    return false;
  }

  matchesDomain(hostname, domains) {
    return domains.some(pattern => {
      if (pattern === '*') return true;
      if (pattern === hostname) return true;
      if (pattern.startsWith('*.')) {
        const suffix = pattern.slice(2);
        return hostname === suffix || hostname.endsWith('.' + suffix);
      }
      return false;
    });
  }

  logViolation(action, hostname, port) {
    const timestamp = new Date().toISOString();
    const entry = `${timestamp} [${action.toUpperCase()}] ${hostname}:${port}\n`;
    // Write to violation log file
    require('fs').appendFileSync('/sandbox/violations.log', entry);
  }

  listen(port) {
    this.server.listen(port);
  }
}

module.exports = HttpProxyServer;
```

#### 2. SOCKS5 Proxy (Node.js)

**File:** `sandy/socks5-proxy.js`

```javascript
const net = require('net');

class Socks5ProxyServer {
  constructor(config) {
    this.config = config;
    this.server = net.createServer(this.handleConnection.bind(this));
  }

  handleConnection(socket) {
    let stage = 'greeting';

    socket.on('data', (data) => {
      if (stage === 'greeting') {
        this.handleGreeting(socket, data);
        stage = 'auth';
      } else if (stage === 'auth') {
        this.handleAuth(socket, data);
        stage = 'request';
      } else if (stage === 'request') {
        this.handleRequest(socket, data);
      }
    });
  }

  handleGreeting(socket, data) {
    // SOCKS5: [VER, NMETHODS, METHODS...]
    if (data[0] !== 5) {
      socket.end();
      return;
    }
    // No auth required
    socket.write(Buffer.from([5, 0])); // [VER, METHOD]
  }

  handleAuth(socket, data) {
    // Auth negotiation; for simplicity, assume no auth
    socket.write(Buffer.from([5, 0])); // Success
  }

  handleRequest(socket, data) {
    // SOCKS5 request: [VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT]
    const ver = data[0];
    const cmd = data[1]; // 1=CONNECT, 2=BIND, 3=UDP
    const atyp = data[3]; // 1=IPv4, 3=DOMAINNAME, 4=IPv6

    if (cmd !== 1) { // Only CONNECT
      socket.end();
      return;
    }

    let hostname, port;

    if (atyp === 3) { // Domain name
      const addrLen = data[4];
      const addr = data.slice(5, 5 + addrLen).toString();
      const portOffset = 5 + addrLen;
      port = (data[portOffset] << 8) | data[portOffset + 1];
      hostname = addr;
    } else if (atyp === 1) { // IPv4
      hostname = data.slice(4, 8).join('.');
      port = (data[8] << 8) | data[9];
    } else {
      socket.end();
      return;
    }

    // Check allowlist
    if (!this.isAllowed(hostname)) {
      this.logViolation('blocked', hostname, port);
      socket.write(Buffer.from([5, 2, 0, 1, 0, 0, 0, 0, 0, 0])); // Connection refused
      socket.end();
      return;
    }

    // Establish tunnel
    const server = net.connect(port, hostname, () => {
      socket.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])); // Success
      server.pipe(socket);
      socket.pipe(server);
      this.logViolation('allowed', hostname, port);
    });

    server.on('error', () => {
      socket.write(Buffer.from([5, 1, 0, 1, 0, 0, 0, 0, 0, 0])); // General failure
      socket.end();
    });
  }

  isAllowed(hostname) {
    const { allowedDomains, deniedDomains } = this.config;
    if (deniedDomains && this.matchesDomain(hostname, deniedDomains)) {
      return false;
    }
    if (allowedDomains && this.matchesDomain(hostname, allowedDomains)) {
      return true;
    }
    return false;
  }

  matchesDomain(hostname, domains) {
    return domains.some(pattern => {
      if (pattern === '*') return true;
      if (pattern === hostname) return true;
      if (pattern.startsWith('*.')) {
        const suffix = pattern.slice(2);
        return hostname === suffix || hostname.endsWith('.' + suffix);
      }
      return false;
    });
  }

  logViolation(action, hostname, port) {
    const timestamp = new Date().toISOString();
    const entry = `${timestamp} [${action.toUpperCase()}] ${hostname}:${port} (SOCKS5)\n`;
    require('fs').appendFileSync('/sandbox/violations.log', entry);
  }

  listen(port) {
    this.server.listen(port);
  }
}

module.exports = Socks5ProxyServer;
```

#### 3. Container Entrypoint Integration

**File:** `sandy/entrypoint.sh` (additions)

```bash
#!/bin/bash
set -euo pipefail

# Load network config
if [[ -f /.sandbox/network.conf ]]; then
  NETWORK_CONFIG=$(cat /.sandbox/network.conf)
else
  # Default allowlist
  NETWORK_CONFIG='{
    "allowedDomains": [
      "github.com", "*.github.com", "api.github.com", "lfs.github.com",
      "npmjs.org", "*.npmjs.org",
      "pypi.org", "*.pypi.org",
      "api.anthropic.com", "*.anthropic.com"
    ]
  }'
fi

# Start HTTP proxy
node <<'EOF' &
const HttpProxy = require('/.sandbox/http-proxy.js');
const config = JSON.parse(process.env.NETWORK_CONFIG);
const proxy = new HttpProxy(config);
proxy.listen(3128);
console.log('[proxy] HTTP proxy listening on :3128');
EOF

# Start SOCKS5 proxy
node <<'EOF' &
const Socks5Proxy = require('/.sandbox/socks5-proxy.js');
const config = JSON.parse(process.env.NETWORK_CONFIG);
const proxy = new Socks5Proxy(config);
proxy.listen(1080);
console.log('[proxy] SOCKS5 proxy listening on :1080');
EOF

# Set proxy environment for all subprocess
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
export ALL_PROXY=socks5://127.0.0.1:1080
export NO_PROXY=localhost,127.0.0.1

# Initialize violation log
mkdir -p /sandbox
touch /sandbox/violations.log

# Continue with Claude Code launch
exec claude-code "$@"
```

#### 4. Sandy Launcher Integration

**File:** `sandy` (additions to launcher script)

```bash
# In docker run invocation:
if [[ -f "$WORKSPACE/.sandy/network.conf" ]]; then
  NETWORK_CONF="$WORKSPACE/.sandy/network.conf"
  # Mount into container
  RUN_FLAGS+=(-v "$NETWORK_CONF:/.sandbox/network.conf:ro")
else
  # Create temporary default config
  NETWORK_CONF=$(mktemp)
  cat > "$NETWORK_CONF" <<'EOF'
{
  "allowedDomains": [
    "github.com", "*.github.com", "api.github.com",
    "npmjs.org", "*.npmjs.org",
    "pypi.org", "*.pypi.org",
    "api.anthropic.com"
  ]
}
EOF
  RUN_FLAGS+=(-v "$NETWORK_CONF:/.sandbox/network.conf:ro")
fi

# After container exits, cleanup temp file
trap "[[ -f '$NETWORK_CONF' ]] && [[ '$NETWORK_CONF' == /tmp/* ]] && rm -f '$NETWORK_CONF'" EXIT
```

---

## Feature 2: Violation Logging

### Architecture

```
Every blocked action → violation store → log file + CLI output

Blocked Actions:
  1. Network: proxy returns 403
  2. Filesystem: write to protected file (if filesystem hooks available)
  3. Syscall: (if seccomp tracing available)

Violation Store:
  - Ring buffer: last 10,000 violations in memory
  - Log file: ~/.sandy/sandboxes/<project>/violations.log
  - Format: JSON lines (one JSON object per line)

CLI Access:
  sandy logs <project>              # Show last 100
  sandy logs <project> --tail        # Stream new violations
  sandy logs <project> --json        # Output JSON for parsing
```

### Implementation

#### 1. Violation Log Format

**File:** `.sandy/sandboxes/<project>/violations.log`

```json
{"timestamp":"2026-03-20T14:32:15Z","type":"network","action":"blocked","hostname":"attacker.com","port":443,"reason":"not-in-allowlist"}
{"timestamp":"2026-03-20T14:32:22Z","type":"filesystem","action":"attempted-write","path":".bashrc","reason":"protected-file"}
{"timestamp":"2026-03-20T14:33:01Z","type":"network","action":"allowed","hostname":"github.com","port":443,"protocol":"https"}
```

#### 2. Violation Logger (Node.js)

**File:** `sandy/violation-logger.js`

```javascript
const fs = require('fs');
const path = require('path');

class ViolationLogger {
  constructor(logFile) {
    this.logFile = logFile;
    this.violations = []; // Ring buffer
    this.maxSize = 10000;

    // Create parent directory
    const dir = path.dirname(logFile);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
  }

  log(violation) {
    // Add timestamp if not present
    if (!violation.timestamp) {
      violation.timestamp = new Date().toISOString();
    }

    // Add to in-memory store
    this.violations.push(violation);
    if (this.violations.length > this.maxSize) {
      this.violations = this.violations.slice(-this.maxSize);
    }

    // Append to log file (JSON lines)
    const line = JSON.stringify(violation) + '\n';
    fs.appendFileSync(this.logFile, line);
  }

  getViolations(limit) {
    if (limit === undefined) {
      return this.violations;
    }
    return this.violations.slice(-limit);
  }

  getViolationsSince(timestamp) {
    return this.violations.filter(v => v.timestamp >= timestamp);
  }

  getTail(count = 100) {
    return this.violations.slice(-count);
  }

  clear() {
    this.violations = [];
  }

  toJSON() {
    return this.violations;
  }
}

module.exports = ViolationLogger;
```

#### 3. Proxy Integration

**File:** `sandy/http-proxy.js` (modified)

```javascript
class HttpProxyServer {
  constructor(config, violationLogger) {
    this.config = config;
    this.violationLogger = violationLogger; // Add this parameter
    // ... rest of constructor
  }

  logViolation(action, hostname, port) {
    const violation = {
      type: 'network',
      action: action === 'allowed' ? 'allowed' : 'blocked',
      hostname,
      port,
      protocol: 'https',
      reason: action === 'blocked' ? 'not-in-allowlist' : null
    };
    this.violationLogger.log(violation);
  }
}
```

#### 4. Sandy CLI Command

**File:** `sandy` (add new subcommand)

```bash
sandy_logs() {
  local project="$1"
  local sandbox_dir="$HOME/.sandy/sandboxes/$project"
  local log_file="$sandbox_dir/violations.log"

  if [[ ! -f "$log_file" ]]; then
    echo "No violations logged for $project"
    return 0
  fi

  case "${2:-}" in
    --tail)
      tail -f "$log_file"
      ;;
    --json)
      cat "$log_file"
      ;;
    --count)
      wc -l < "$log_file"
      ;;
    *)
      # Default: show last 100 violations, pretty-printed
      tail -n 100 "$log_file" | while read -r line; do
        echo "$line" | jq '.'
      done
      ;;
  esac
}

# In main script, handle subcommand:
case "${1:-}" in
  logs)
    sandy_logs "${2:-}" "${3:-}"
    exit $?
    ;;
esac
```

---

## Feature 3: Declarative YAML Policies

### Configuration Format

**File:** `.sandy/policy.yaml` (optional, fallback to env vars)

```yaml
version: 1

# Network configuration (optional, defaults to built-in allowlist)
network:
  allowedDomains:
    - github.com
    - "*.github.com"
    - api.github.com
    - npmjs.org
    - "*.npmjs.org"
    - pypi.org
    - "*.pypi.org"
    - api.anthropic.com
    - "*.anthropic.com"

  deniedDomains:
    - attacker.com
    - "*.badsite.com"

  logLevel: info  # or debug, warn, error

# SSH configuration (optional)
ssh:
  mode: token  # "token" (default) or "agent"
  agentSocketPath: /tmp/ssh-agent.sock  # if mode=agent

# Workspace configuration (optional)
workspace:
  readOnly: false

# Claude Code settings (optional)
claude:
  model: claude-opus-4-5-20250929
  maxOutputTokens: 4096
```

### Implementation

#### 1. YAML Parser

**File:** `sandy/config.js`

```javascript
const fs = require('fs');
const path = require('path');
const yaml = require('yaml'); // npm install yaml

class ConfigLoader {
  static loadPolicy(workspacePath) {
    const policyFile = path.join(workspacePath, '.sandy', 'policy.yaml');

    if (!fs.existsSync(policyFile)) {
      return this.defaultPolicy();
    }

    const content = fs.readFileSync(policyFile, 'utf8');
    const policy = yaml.parse(content);

    // Validate schema
    this.validatePolicy(policy);

    return policy;
  }

  static defaultPolicy() {
    return {
      version: 1,
      network: {
        allowedDomains: [
          'github.com', '*.github.com', 'api.github.com',
          'npmjs.org', '*.npmjs.org',
          'pypi.org', '*.pypi.org',
          'api.anthropic.com', '*.anthropic.com'
        ],
        deniedDomains: [],
        logLevel: 'info'
      },
      ssh: {
        mode: 'token'
      },
      workspace: {
        readOnly: false
      }
    };
  }

  static validatePolicy(policy) {
    if (!policy.version || policy.version !== 1) {
      throw new Error('Policy version must be 1');
    }

    if (policy.network) {
      if (!Array.isArray(policy.network.allowedDomains)) {
        throw new Error('network.allowedDomains must be an array');
      }
      if (!Array.isArray(policy.network.deniedDomains)) {
        throw new Error('network.deniedDomains must be an array');
      }
      const validLogLevels = ['debug', 'info', 'warn', 'error'];
      if (!validLogLevels.includes(policy.network.logLevel)) {
        throw new Error(`network.logLevel must be one of ${validLogLevels.join(', ')}`);
      }
    }

    if (policy.ssh) {
      const validModes = ['token', 'agent'];
      if (!validModes.includes(policy.ssh.mode)) {
        throw new Error(`ssh.mode must be one of ${validModes.join(', ')}`);
      }
    }
  }

  static mergeWithEnv(policy, env) {
    // Environment variables override YAML config
    const override = {};

    if (env.SANDY_SSH === 'agent') {
      override.ssh = { mode: 'agent' };
    }

    if (env.SANDY_ALLOWED_DOMAINS) {
      override.network = {
        ...(policy.network || {}),
        allowedDomains: env.SANDY_ALLOWED_DOMAINS.split(',')
      };
    }

    return { ...policy, ...override };
  }
}

module.exports = ConfigLoader;
```

#### 2. Schema Validation

**File:** `sandy/schema.js`

```javascript
const schema = {
  version: {
    type: 'number',
    required: true,
    enum: [1]
  },
  network: {
    type: 'object',
    properties: {
      allowedDomains: {
        type: 'array',
        items: { type: 'string' },
        description: 'Domains allowed for outbound connections'
      },
      deniedDomains: {
        type: 'array',
        items: { type: 'string' },
        description: 'Domains explicitly denied'
      },
      logLevel: {
        type: 'string',
        enum: ['debug', 'info', 'warn', 'error'],
        default: 'info'
      }
    }
  },
  ssh: {
    type: 'object',
    properties: {
      mode: {
        type: 'string',
        enum: ['token', 'agent'],
        default: 'token'
      },
      agentSocketPath: {
        type: 'string'
      }
    }
  },
  workspace: {
    type: 'object',
    properties: {
      readOnly: {
        type: 'boolean',
        default: false
      }
    }
  }
};

module.exports = schema;
```

#### 3. Integration into Sandy Launcher

**File:** `sandy` (additions)

```bash
# At startup, before docker run:
CONFIG_VALIDATION=$(node <<'EOF'
const ConfigLoader = require('/.sandbox/config.js');

try {
  const policy = ConfigLoader.loadPolicy(process.env.WORKSPACE);
  const merged = ConfigLoader.mergeWithEnv(policy, process.env);
  console.log(JSON.stringify(merged));
} catch (err) {
  console.error("Configuration error: " + err.message);
  process.exit(1);
}
EOF
)

if [[ $? -ne 0 ]]; then
  echo "Failed to load configuration"
  exit 1
fi

# Convert JSON back to env vars for container
NETWORK_CONFIG=$(echo "$CONFIG_VALIDATION" | jq '.network')
export NETWORK_CONFIG
```

---

## Feature 4: Configuration Validation (Schema)

### Schema-Based Validation

**File:** `sandy/validator.js`

```javascript
class Validator {
  static validate(value, schema) {
    if (schema.required && value === undefined) {
      throw new Error(`Required field missing`);
    }

    if (value === undefined) {
      return schema.default;
    }

    if (schema.enum && !schema.enum.includes(value)) {
      throw new Error(
        `Must be one of: ${schema.enum.join(', ')}. Got: ${value}`
      );
    }

    if (schema.type === 'array') {
      if (!Array.isArray(value)) {
        throw new Error(`Expected array, got ${typeof value}`);
      }
      return value.map((item, idx) => {
        try {
          return this.validate(item, schema.items);
        } catch (err) {
          throw new Error(`[${idx}]: ${err.message}`);
        }
      });
    }

    if (schema.type === 'object') {
      if (typeof value !== 'object') {
        throw new Error(`Expected object, got ${typeof value}`);
      }
      const result = {};
      for (const [key, keySchema] of Object.entries(schema.properties || {})) {
        result[key] = this.validate(value[key], keySchema);
      }
      return result;
    }

    if (schema.type === 'string' && typeof value !== 'string') {
      throw new Error(`Expected string, got ${typeof value}`);
    }

    if (schema.type === 'number' && typeof value !== 'number') {
      throw new Error(`Expected number, got ${typeof value}`);
    }

    if (schema.type === 'boolean' && typeof value !== 'boolean') {
      throw new Error(`Expected boolean, got ${typeof value}`);
    }

    return value;
  }

  static validatePolicy(policy, schema) {
    const errors = [];

    for (const [key, keySchema] of Object.entries(schema)) {
      try {
        this.validate(policy[key], keySchema);
      } catch (err) {
        errors.push(`${key}: ${err.message}`);
      }
    }

    if (errors.length > 0) {
      throw new Error(
        'Configuration validation failed:\n' +
        errors.map(e => `  ✗ ${e}`).join('\n')
      );
    }

    return policy;
  }
}

module.exports = Validator;
```

---

## Testing Strategy

### Test Cases for Domain Filtering

```bash
#!/bin/bash
# test-domain-filtering.sh

setup() {
  export TEST_PROJECT="test-$(date +%s)"
  mkdir -p "/tmp/$TEST_PROJECT/.sandy"
}

teardown() {
  rm -rf "/tmp/$TEST_PROJECT"
}

test_allowed_domain() {
  echo "Test: Allowed domain should succeed"
  result=$(sandy -p "curl -s https://api.github.com/zen" 2>&1)
  if echo "$result" | grep -q "Anything added"; then
    echo "✓ PASS: github.com connection allowed"
  else
    echo "✗ FAIL: github.com connection blocked unexpectedly"
    return 1
  fi
}

test_blocked_domain() {
  echo "Test: Blocked domain should fail"
  result=$(sandy -p "curl https://attacker.com" 2>&1)
  if echo "$result" | grep -q "blocked"; then
    echo "✓ PASS: attacker.com connection blocked"
  else
    echo "✗ FAIL: attacker.com connection not blocked"
    return 1
  fi
}

test_custom_allowlist() {
  echo "Test: Custom allowlist should work"
  cat > "/tmp/$TEST_PROJECT/.sandy/network.conf" <<'EOF'
{"allowedDomains":["example.com"]}
EOF

  result=$(sandy -p "curl https://example.com" 2>&1)
  if echo "$result" | grep -q "example.com"; then
    echo "✓ PASS: custom allowlist works"
  else
    echo "✗ FAIL: custom allowlist not applied"
    return 1
  fi
}

# Run tests
setup
test_allowed_domain
test_blocked_domain
test_custom_allowlist
teardown
```

---

## Migration Guide for Users

### For Existing Sandy Users

**No breaking changes.** All features are backward compatible:

1. **Domain filtering** — Opt-in. Set `SANDY_ALLOWED_DOMAINS` or create `.sandy/network.conf`
2. **Violation logging** — Automatic. Check `~/.sandy/sandboxes/<project>/violations.log`
3. **YAML policies** — Optional. Create `.sandy/policy.yaml` if desired; env vars still work
4. **Config validation** — Automatic. Errors show on startup with clear messages

### Migration Path

```bash
# Old way (still works)
export SANDY_SSH=token
sandy

# New way (optional)
cat > .sandy/policy.yaml <<'EOF'
version: 1
ssh:
  mode: token
network:
  allowedDomains:
    - github.com
    - npmjs.org
    - api.anthropic.com
EOF

sandy  # Automatically uses policy.yaml
```

---

**End of Implementation Sketches**
