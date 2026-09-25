# Setup Podman

This guide allows you to use Podman on machines behind a TLS-inspecting corporate proxy for local development while maintaining full compatibility with AWS ECS deployment.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Proxy Configuration](#proxy-configuration)
3. [Certificate Setup](#certificate-setup)
4. [DNS Configuration for Azure/External Services](#dns-configuration-for-azureexternal-services)
5. [Project Network Setup](#project-network-setup)
6. [Running the Application](#running-the-application)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Podman Desktop installed
- PowerShell 7+ (recommended)
- Access to corporate proxy and certificates

---

## Proxy Configuration

Install Podman and open **Podman Desktop**.

Click on the setting menu (the gear symbol in the bottom-left corner), then select the *Proxy* menu.

In *Proxy configuration* select the *manual* option and compile the field in the following way:

- Web Proxy (HTTP): `http://proxy.example.com:8080`
- Secure Web Proxy (HTTPS): `http://proxy.example.com:8080`
- Bypass proxy settings for these hosts and domains: `*localhost*,10.*.*.*,172.*.*.*,*.amazonaws.com`

---

## Certificate Setup

In the folder `C:\Users\<user-name>` save these two files: `corporate-root-ca.pem` and `corporate-root-ca.crt`.

On the PowerShell execute this command (or open Edit the system environment variables through graphical interface):

```pwsh
rundll32 sysdm.cpl,EditEnvironmentVariables
```

In *User variables for \<account name\>* click on *New*.

You have to add the following variable:  
Variable name: `SSL_CERT_FILE`  
Variable value: `C:\Users\<user-name>\corporate-root-ca.pem`

## Add certificate to the Podman machine

The certificate added in your computer now has to be added to the Podman machine.
This description comes from the official [Podman documentation](<https://podman-desktop.io/docs/podman/adding-certificates-to-a-podman-machine>)

1. First of all check your Podman machine is running: in **Podman Desktop** open the menu and in *Resources* check the *Podman Machine* is running.  
2. In the PowerShell you start an interactive session with the default Podman machine:

    ```pwsh
    podman machine ssh
    ```

3. If you are not inside as root execute also this:

    ```bash
    sudo su -
    ```

4. Then move into anchors

    ```bash
    cd /etc/pki/ca-trust/source/anchors
    ```

5. Now you have to create a file with the certificate.
    Here I provide a guide using Vi editor:

    1. Create and open the file:

        ```bash
        vi corporate-root-ca.pem
        ```

        Now you shall see the Vim interface.
    2. You press the key `i`. Now you see on the bottom of the window the inscription `-- INSERT --`.
    3. Open as text your `corporate-root-ca.pem` certificate, copy the text and paste on the Vim.
    4. Then, press the key `Esc` and after the sequence of keys `:wq` and the `Enter`.

6. Add the certificate to the list of trusted certificates:

    ```bash
    update-ca-trust
    ```

7. and at the end close the connection with the machine:

    ```bash
    exit
    ```

## Additional required configuration

Podman Desktop writes proxy settings to `/etc/profile.d/default-env.sh` inside the VM, which only affects interactive shell sessions. The `podman push` operation runs through system services that don't inherit shell environment variables - they read from `/etc/environment` instead.

### Solution

Configure the proxy bypass in `/etc/environment` inside the Podman machine:

1. SSH into the Podman machine:

    ```pwsh
    podman machine ssh
    ```

    ```bash
    sudo su -
    ```

2. Edit `/etc/environment` (create if it doesn't exist):

    ```bash
    sudo vi /etc/environment
    ```

3. Add the following content (adjust proxy URL if different) PRESS i to Enter and copy:

```
http_proxy=http://proxy.example.com:8080
https_proxy=http://proxy.example.com:8080
no_proxy=*localhost*,10.*.*.*,172.*.*.*,*.amazonaws.com
HTTP_PROXY=http://proxy.example.com:8080
HTTPS_PROXY=http://proxy.example.com:8080
NO_PROXY=*localhost*,10.*.*.*,172.*.*.*,*.amazonaws.com
```

4. Exit and restart the Podman machine:

    ```bash
    exit
    ```

    ```pwsh
    podman machine stop && podman machine start
    ```

### Better enable podman pull commands

```pwsh
podman machine ssh -- 'sudo mkdir -p /etc/systemd/system/podman.service.d'
podman machine ssh -- 'echo "[Service]
Environment=\"HTTP_PROXY=http://proxy.example.com:8080\"
Environment=\"HTTPS_PROXY=http://proxy.example.com:8080\"
Environment=\"NO_PROXY=*localhost*,10.*.*.*,172.*.*.*,*.amazonaws.com\"" | sudo tee /etc/systemd/system/podman.service.d/proxy.conf'
podman machine ssh -- 'sudo systemctl daemon-reload && sudo systemctl restart podman'
```

---

## DNS Configuration for Azure/External Services

**IMPORTANT**: By default, Podman's internal DNS cannot resolve external hostnames like Azure OpenAI endpoints (`*.openai.azure.com`). This causes "Connection error" or "Could not resolve host" errors when the application tries to call external APIs.

### The Problem

When using a custom bridge network with `dns_enabled: true`, Podman uses its internal DNS server (typically `10.89.1.1`) which:
- ✅ Resolves container names (e.g., `db` → container IP)
- ❌ Cannot forward external DNS queries to corporate DNS servers

### The Solution

Create the network **before** running `podman compose up` with explicit DNS server configuration:

```pwsh
# Get your corporate DNS server
nslookup google.com
# Note the "Server" address (e.g., 192.0.2.53)

# Create the network with corporate DNS forwarding
podman network create --dns=<your-corporate-dns> --dns=8.8.8.8 projectName-network
```

Example with a corporate DNS at 192.0.2.53:

```pwsh
podman network create --dns=192.0.2.53 --dns=8.8.8.8 projectName-network
```

This configures the network to:
1. Use Podman's internal DNS for container-to-container resolution
2. Forward external queries to corporate DNS (`192.0.2.53`)
3. Use Google DNS (`8.8.8.8`) as fallback

### Automatic DNS Setup

The `CCM/local-build.ps1` script automatically detects your DNS servers and creates the network with proper configuration. Simply run:

```pwsh
./CCM/local-build.ps1
```

---

## Project Network Setup

### compose.yaml Configuration

For projects using external services (Azure OpenAI, AWS, etc.), configure your `compose.yaml` to use an external network:

```yaml
services:
  app:
    # ... service configuration ...
    dns:
      - 192.0.2.53  # Corporate DNS
      - 8.8.8.8      # Fallback
    networks:
      - projectName-network

networks:
  projectName-network:
    external: true
    name: projectName-network
```

### Why This Works with AWS ECS

This configuration is **fully compatible** with AWS ECS deployment:

| Setting | Local (Podman) | AWS ECS |
|---------|----------------|---------|
| `dns:` directive | Used for external DNS | Ignored (ECS uses VPC DNS) |
| `external: true` network | Uses pre-created network | Ignored (ECS uses `awsvpc` network mode) |
| `env_file: - .env` | Loads local secrets | Ignored (ECS uses Secrets Manager) |

The ECS task definition uses separate configuration that doesn't depend on compose.yaml network settings.

---

## Running the Application

### Using local-build.ps1 (Recommended)

```pwsh
# Start the application (creates network automatically)
./CCM/local-build.ps1

# Rebuild containers
./CCM/local-build.ps1 -Build

# View logs
./CCM/local-build.ps1 -Logs

# Stop all services
./CCM/local-build.ps1 -Down

# Development mode with hot-reload
./CCM/local-build.ps1 -Dev
```

### Manual Setup

If you prefer manual control:

```pwsh
# 1. Create network with DNS (one-time setup)
podman network create --dns=192.0.2.53 --dns=8.8.8.8 projectName-network

# 2. Start services
podman compose up -d

# 3. Check logs
podman compose logs -f app

# 4. Stop services
podman compose down
```

---

## Troubleshooting

### "Could not resolve host" or "Connection error"

**Symptom**: Application hangs or fails when calling Azure OpenAI or other external APIs.

**Cause**: Container DNS cannot resolve external hostnames.

**Solution**:
```pwsh
# Check current DNS in container
podman exec <container-name> cat /etc/resolv.conf

# If it shows only 10.89.1.1 (Podman internal), recreate network:
podman compose down
podman network rm projectName-network
podman network create --dns=192.0.2.53 --dns=8.8.8.8 projectName-network
podman compose up -d

# Verify DNS now works
podman exec <container-name> curl -s https://my-resource.openai.azure.com/
```

### "network was found but has incorrect label"

**Symptom**: Compose refuses to start because network labels don't match.

**Solution**:
```pwsh
podman compose down
podman network rm projectName-network
./CCM/local-build.ps1
```

### Container cannot connect to database

**Symptom**: `could not translate host name "db" to address`

**Cause**: Network was created with `--disable-dns` which disables container name resolution.

**Solution**: Recreate network WITHOUT `--disable-dns`:
```pwsh
podman network rm projectName-network
podman network create --dns=192.0.2.53 --dns=8.8.8.8 projectName-network
podman compose up -d
```

### Verifying Network Configuration

```pwsh
# Check network DNS settings
podman network inspect projectName-network

# Look for:
# "dns_enabled": true
# "network_dns_servers": ["192.0.2.53", "8.8.8.8"]
```

### Environment Variables Not Loading

**Symptom**: Container uses wrong Azure endpoint or credentials.

**Cause**: compose.yaml not configured to load `.env` file.

**Solution**: Ensure your compose.yaml includes:
```yaml
services:
  app:
    env_file:
      - .env
```

---
